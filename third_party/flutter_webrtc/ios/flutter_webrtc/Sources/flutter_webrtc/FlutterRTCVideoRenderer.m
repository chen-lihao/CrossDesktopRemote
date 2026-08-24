#import "FlutterRTCVideoRenderer.h"

#import <Accelerate/Accelerate.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreGraphics/CGImage.h>
#import <WebRTC/RTCCVPixelBuffer.h>
#import <WebRTC/RTCYUVHelper.h>
#import <WebRTC/RTCYUVPlanarBuffer.h>
#import <WebRTC/WebRTC.h>

#import <objc/runtime.h>

#import "FlutterWebRTCPlugin.h"
#import <os/lock.h>

static NSString *CDRRendererFourCCName(OSType pixelFormat) {
  if (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
    return @"420v/NV12";
  }
  if (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
    return @"420f/NV12";
  }
  if (pixelFormat == kCVPixelFormatType_32BGRA) {
    return @"BGRA";
  }
  char value[5] = {
      (char)((pixelFormat >> 24) & 0xff),
      (char)((pixelFormat >> 16) & 0xff),
      (char)((pixelFormat >> 8) & 0xff),
      (char)(pixelFormat & 0xff),
      0,
  };
  NSString *fourCC = [NSString stringWithCString:value encoding:NSMacOSRomanStringEncoding];
  return fourCC ?: [NSString stringWithFormat:@"0x%08x", (unsigned int)pixelFormat];
}

static NSString *CDRRendererPixelRangeName(OSType pixelFormat) {
  if (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
    return @"Video Range";
  }
  if (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
    return @"Full Range";
  }
  if (pixelFormat == kCVPixelFormatType_32BGRA) {
    return @"Full Range RGB";
  }
  return @"Unknown";
}

static NSString *CDRRendererAttachmentString(CVPixelBufferRef pixelBuffer, CFStringRef key) {
  CFTypeRef value = CVBufferGetAttachment(pixelBuffer, key, NULL);
  if (value == NULL) {
    return @"Unknown";
  }
  if (CFGetTypeID(value) == CFStringGetTypeID()) {
    return (__bridge NSString *)value;
  }
  return [(__bridge id)value description] ?: @"Unknown";
}

static NSDictionary<NSString *, id> *CDRRendererLumaStatisticsForPlane(
    const uint8_t *base,
    size_t width,
    size_t height,
    size_t stride,
    uint8_t nominalBlack,
    uint8_t nominalWhite) {
  if (base == NULL || width == 0 || height == 0) {
    return @{ @"sampleCount": @0 };
  }
  const size_t stepX = MAX((size_t)1, width / 128);
  const size_t stepY = MAX((size_t)1, height / 128);
  uint64_t buckets[16] = {0};
  uint64_t sampleCount = 0;
  uint64_t belowBlack = 0;
  uint64_t aboveWhite = 0;
  uint8_t minimum = UINT8_MAX;
  uint8_t maximum = 0;
  for (size_t y = 0; y < height; y += stepY) {
    const uint8_t *row = base + y * stride;
    for (size_t x = 0; x < width; x += stepX) {
      const uint8_t luma = row[x];
      minimum = MIN(minimum, luma);
      maximum = MAX(maximum, luma);
      buckets[MIN((NSUInteger)15, (NSUInteger)(luma / 16))] += 1;
      belowBlack += luma < nominalBlack;
      aboveWhite += luma > nominalWhite;
      sampleCount += 1;
    }
  }
  NSMutableArray<NSNumber *> *histogram = [NSMutableArray arrayWithCapacity:16];
  for (NSUInteger index = 0; index < 16; index += 1) {
    [histogram addObject:@(buckets[index])];
  }
  const double divisor = sampleCount == 0 ? 1.0 : (double)sampleCount;
  return @{
    @"sampleCount": @(sampleCount),
    @"lumaMin": @(sampleCount == 0 ? 0 : minimum),
    @"lumaMax": @(maximum),
    @"nominalBlack": @(nominalBlack),
    @"nominalWhite": @(nominalWhite),
    @"belowNominalBlackPercent": @((double)belowBlack * 100.0 / divisor),
    @"aboveNominalWhitePercent": @((double)aboveWhite * 100.0 / divisor),
    @"lumaHistogram16": histogram,
  };
}

static NSDictionary<NSString *, id> *CDRRendererPixelBufferDiagnostics(
    CVPixelBufferRef pixelBuffer,
    NSString *stage) {
  OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
  NSMutableDictionary<NSString *, id> *result = [@{
    @"stage": stage,
    @"width": @(CVPixelBufferGetWidth(pixelBuffer)),
    @"height": @(CVPixelBufferGetHeight(pixelBuffer)),
    @"pixelFormat": CDRRendererFourCCName(pixelFormat),
    @"range": CDRRendererPixelRangeName(pixelFormat),
    @"colorPrimaries": CDRRendererAttachmentString(pixelBuffer, kCVImageBufferColorPrimariesKey),
    @"transferFunction": CDRRendererAttachmentString(pixelBuffer, kCVImageBufferTransferFunctionKey),
    @"yCbCrMatrix": CDRRendererAttachmentString(pixelBuffer, kCVImageBufferYCbCrMatrixKey),
  } mutableCopy];

  if (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
      pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
    if (CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess) {
      const BOOL videoRange = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
      [result addEntriesFromDictionary:CDRRendererLumaStatisticsForPlane(
          CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
          CVPixelBufferGetWidth(pixelBuffer),
          CVPixelBufferGetHeight(pixelBuffer),
          CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0),
          videoRange ? 16 : 0,
          videoRange ? 235 : 255)];
      CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    }
  } else if (pixelFormat == kCVPixelFormatType_32BGRA &&
             CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess) {
    const size_t width = CVPixelBufferGetWidth(pixelBuffer);
    const size_t height = CVPixelBufferGetHeight(pixelBuffer);
    const size_t stride = CVPixelBufferGetBytesPerRow(pixelBuffer);
    const uint8_t *base = CVPixelBufferGetBaseAddress(pixelBuffer);
    const size_t stepX = MAX((size_t)1, width / 128);
    const size_t stepY = MAX((size_t)1, height / 128);
    uint64_t buckets[16] = {0};
    uint64_t sampleCount = 0;
    uint8_t minimum = UINT8_MAX;
    uint8_t maximum = 0;
    for (size_t y = 0; y < height; y += stepY) {
      const uint8_t *row = base + y * stride;
      for (size_t x = 0; x < width; x += stepX) {
        const uint8_t *pixel = row + x * 4;
        const uint8_t luma =
            (uint8_t)((19 * pixel[0] + 183 * pixel[1] + 54 * pixel[2]) >> 8);
        minimum = MIN(minimum, luma);
        maximum = MAX(maximum, luma);
        buckets[MIN((NSUInteger)15, (NSUInteger)(luma / 16))] += 1;
        sampleCount += 1;
      }
    }
    NSMutableArray<NSNumber *> *histogram = [NSMutableArray arrayWithCapacity:16];
    for (NSUInteger index = 0; index < 16; index += 1) {
      [histogram addObject:@(buckets[index])];
    }
    [result addEntriesFromDictionary:@{
      @"sampleCount": @(sampleCount),
      @"lumaMin": @(sampleCount == 0 ? 0 : minimum),
      @"lumaMax": @(maximum),
      @"nominalBlack": @0,
      @"nominalWhite": @255,
      @"belowNominalBlackPercent": @0,
      @"aboveNominalWhitePercent": @0,
      @"lumaHistogram16": histogram,
    }];
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
  }
  return result;
}

@implementation FlutterRTCVideoRenderer {
  CGSize _frameSize;
  CGSize _renderSize;
  CVPixelBufferRef _pixelBufferRef;
  RTCVideoRotation _rotation;
  FlutterEventChannel* _eventChannel;
  bool _isFirstFrameRendered;
  bool _frameAvailable;
  bool _emittedColorDiagnostics;
  bool _hasBT709VideoRangeConversion;
  CIContext* _colorContext;
  CGColorSpaceRef _outputColorSpace;
  vImage_YpCbCrToARGB _bt709VideoRangeConversion;
  NSDictionary<NSString*, id>* _lastColorDiagnostics;
  os_unfair_lock _lock;
}

@synthesize textureId = _textureId;
@synthesize registry = _registry;
@synthesize eventSink = _eventSink;
@synthesize videoTrack = _videoTrack;

- (instancetype)initWithTextureRegistry:(id<FlutterTextureRegistry>)registry
                              messenger:(NSObject<FlutterBinaryMessenger>*)messenger {
  self = [super init];
  if (self) {
    _lock = OS_UNFAIR_LOCK_INIT;
    _isFirstFrameRendered = false;
    _frameAvailable = false;
    _emittedColorDiagnostics = false;
    _frameSize = CGSizeZero;
    _renderSize = CGSizeZero;
    _rotation = -1;
    _registry = registry;
    _pixelBufferRef = nil;
    _eventSink = nil;
    _rotation = -1;
    _textureId = [registry registerTexture:self];
    _colorContext = [CIContext contextWithOptions:nil];
    _outputColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    vImage_YpCbCrPixelRange pixelRange = {
        .Yp_bias = 16,
        .CbCr_bias = 128,
        .YpRangeMax = 235,
        .CbCrRangeMax = 240,
        .YpMax = 255,
        .YpMin = 0,
        .CbCrMax = 255,
        .CbCrMin = 0,
    };
    _hasBT709VideoRangeConversion =
        vImageConvert_YpCbCrToARGB_GenerateConversion(
            kvImage_YpCbCrToARGBMatrix_ITU_R_709_2,
            &pixelRange,
            &_bt709VideoRangeConversion,
            kvImage420Yp8_Cb8_Cr8,
            kvImageARGB8888,
            kvImageNoFlags) == kvImageNoError;
    /*Create Event Channel.*/
    _eventChannel = [FlutterEventChannel
        eventChannelWithName:[NSString stringWithFormat:@"FlutterWebRTC/Texture%lld", _textureId]
             binaryMessenger:messenger];
    [_eventChannel setStreamHandler:self];
  }
  return self;
}

- (void)dealloc {
  if (_outputColorSpace != NULL) {
    CGColorSpaceRelease(_outputColorSpace);
    _outputColorSpace = NULL;
  }
}

- (CVPixelBufferRef)copyPixelBuffer {
  CVPixelBufferRef buffer = nil;
  os_unfair_lock_lock(&_lock);
  if (_pixelBufferRef != nil && _frameAvailable) {
    buffer = CVBufferRetain(_pixelBufferRef);
    _frameAvailable = false;
  }
  os_unfair_lock_unlock(&_lock);
  return buffer;
}

- (void)dispose {
  os_unfair_lock_lock(&_lock);
  [_registry unregisterTexture:_textureId];
  _textureId = -1;
  if (_pixelBufferRef) {
    CVBufferRelease(_pixelBufferRef);
    _pixelBufferRef = nil;
  }
  _lastColorDiagnostics = nil;
  _frameAvailable = false;
  os_unfair_lock_unlock(&_lock);
}

- (void)setVideoTrack:(RTCVideoTrack*)videoTrack {
  RTCVideoTrack* oldValue = self.videoTrack;
  if (oldValue != videoTrack) {
    os_unfair_lock_lock(&_lock);
    _videoTrack = videoTrack;
    os_unfair_lock_unlock(&_lock);
    _isFirstFrameRendered = false;
    _emittedColorDiagnostics = false;
    _lastColorDiagnostics = nil;
    if (oldValue) {
      [oldValue removeRenderer:self];
    }
    _frameSize = CGSizeZero;
    _renderSize = CGSizeZero;
    _rotation = -1;
    if (videoTrack) {
      [videoTrack addRenderer:self];
    }
  }
}

- (id<RTCI420Buffer>)correctRotation:(const id<RTCI420Buffer>)src
                        withRotation:(RTCVideoRotation)rotation {
  int rotated_width = src.width;
  int rotated_height = src.height;

  if (rotation == RTCVideoRotation_90 || rotation == RTCVideoRotation_270) {
    int temp = rotated_width;
    rotated_width = rotated_height;
    rotated_height = temp;
  }

  id<RTCI420Buffer> buffer = [[RTCI420Buffer alloc] initWithWidth:rotated_width
                                                           height:rotated_height];

  [RTCYUVHelper I420Rotate:src.dataY
                srcStrideY:src.strideY
                      srcU:src.dataU
                srcStrideU:src.strideU
                      srcV:src.dataV
                srcStrideV:src.strideV
                      dstY:(uint8_t*)buffer.dataY
                dstStrideY:buffer.strideY
                      dstU:(uint8_t*)buffer.dataU
                dstStrideU:buffer.strideU
                      dstV:(uint8_t*)buffer.dataV
                dstStrideV:buffer.strideV
                     width:src.width
                    height:src.height
                      mode:rotation];

  return buffer;
}

- (void)applyOutputColorAttachments:(CVPixelBufferRef)outputPixelBuffer {
  CVBufferSetAttachment(outputPixelBuffer,
                        kCVImageBufferColorPrimariesKey,
                        kCVImageBufferColorPrimaries_ITU_R_709_2,
                        kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(outputPixelBuffer,
                        kCVImageBufferTransferFunctionKey,
                        kCVImageBufferTransferFunction_sRGB,
                        kCVAttachmentMode_ShouldPropagate);
  if (_outputColorSpace != NULL) {
    CVBufferSetAttachment(outputPixelBuffer,
                          kCVImageBufferCGColorSpaceKey,
                          _outputColorSpace,
                          kCVAttachmentMode_ShouldPropagate);
  }
}

- (BOOL)copyNativePixelBuffer:(RTCCVPixelBuffer*)buffer
               toPixelBuffer:(CVPixelBufferRef)outputPixelBuffer
                    rotation:(RTCVideoRotation)rotation {
  if (rotation != RTCVideoRotation_0) {
    return NO;
  }

  CVPixelBufferRef source = buffer.pixelBuffer;
  CFDictionaryRef attachments = CVBufferCopyAttachments(
      source, kCVAttachmentMode_ShouldPropagate);
  CGColorSpaceRef inputColorSpace = attachments != NULL
      ? CVImageBufferCreateColorSpaceFromAttachments(attachments)
      : NULL;
  if (attachments != NULL) {
    CFRelease(attachments);
  }
  if (inputColorSpace == NULL) {
    inputColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
  }

  NSMutableDictionary<CIImageOption, id>* options = [NSMutableDictionary dictionary];
  if (inputColorSpace != NULL) {
    options[kCIImageColorSpace] = (__bridge id)inputColorSpace;
  }
  if (@available(iOS 14.1, *)) {
    options[kCIImageToneMapHDRtoSDR] = @YES;
  }
  CIImage* image = [CIImage imageWithCVPixelBuffer:source options:options];
  if (inputColorSpace != NULL) {
    CGColorSpaceRelease(inputColorSpace);
  }

  const size_t sourceHeight = CVPixelBufferGetHeight(source);
  if ([buffer requiresCropping]) {
    CGRect cropRect = CGRectMake(buffer.cropX,
                                 sourceHeight - buffer.cropY - buffer.cropHeight,
                                 buffer.cropWidth,
                                 buffer.cropHeight);
    image = [image imageByCroppingToRect:cropRect];
  }
  CGRect extent = image.extent;
  if (extent.origin.x != 0 || extent.origin.y != 0) {
    image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(
        -extent.origin.x, -extent.origin.y)];
    extent = image.extent;
  }
  const CGFloat targetWidth = CVPixelBufferGetWidth(outputPixelBuffer);
  const CGFloat targetHeight = CVPixelBufferGetHeight(outputPixelBuffer);
  if (extent.size.width <= 0 || extent.size.height <= 0) {
    return NO;
  }
  if (extent.size.width != targetWidth || extent.size.height != targetHeight) {
    image = [image imageByApplyingTransform:CGAffineTransformMakeScale(
        targetWidth / extent.size.width, targetHeight / extent.size.height)];
  }

  @try {
    [_colorContext render:image
           toCVPixelBuffer:outputPixelBuffer
                    bounds:CGRectMake(0, 0, targetWidth, targetHeight)
                colorSpace:_outputColorSpace];
  } @catch (NSException* exception) {
    NSLog(@"CrossDesktopRemote receiver Core Image conversion failed: %@", exception);
    return NO;
  }
  [self applyOutputColorAttachments:outputPixelBuffer];
  return YES;
}

- (NSString*)copyFrameToCVPixelBuffer:(CVPixelBufferRef)outputPixelBuffer
                            withFrame:(RTCVideoFrame*)frame {
  if ([frame.buffer isKindOfClass:[RTCCVPixelBuffer class]] &&
      [self copyNativePixelBuffer:(RTCCVPixelBuffer*)frame.buffer
                    toPixelBuffer:outputPixelBuffer
                         rotation:frame.rotation]) {
    return @"Core Image native PixelBuffer → sRGB BGRA";
  }

  id<RTCI420Buffer> i420Buffer = [self correctRotation:[frame.buffer toI420]
                                          withRotation:frame.rotation];
  CVPixelBufferLockBaseAddress(outputPixelBuffer, 0);
  uint8_t* destination = CVPixelBufferGetBaseAddress(outputPixelBuffer);
  const size_t destinationStride = CVPixelBufferGetBytesPerRow(outputPixelBuffer);
  BOOL converted = NO;
  if (_hasBT709VideoRangeConversion) {
    vImage_Buffer sourceY = {
        .data = (void*)i420Buffer.dataY,
        .height = (vImagePixelCount)i420Buffer.height,
        .width = (vImagePixelCount)i420Buffer.width,
        .rowBytes = (size_t)i420Buffer.strideY,
    };
    vImage_Buffer sourceCb = {
        .data = (void*)i420Buffer.dataU,
        .height = (vImagePixelCount)((i420Buffer.height + 1) / 2),
        .width = (vImagePixelCount)((i420Buffer.width + 1) / 2),
        .rowBytes = (size_t)i420Buffer.strideU,
    };
    vImage_Buffer sourceCr = {
        .data = (void*)i420Buffer.dataV,
        .height = (vImagePixelCount)((i420Buffer.height + 1) / 2),
        .width = (vImagePixelCount)((i420Buffer.width + 1) / 2),
        .rowBytes = (size_t)i420Buffer.strideV,
    };
    vImage_Buffer destinationBuffer = {
        .data = destination,
        .height = (vImagePixelCount)i420Buffer.height,
        .width = (vImagePixelCount)i420Buffer.width,
        .rowBytes = destinationStride,
    };
    const uint8_t bgraPermuteMap[4] = {3, 2, 1, 0};
    converted = vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(
                    &sourceY,
                    &sourceCb,
                    &sourceCr,
                    &destinationBuffer,
                    &_bt709VideoRangeConversion,
                    bgraPermuteMap,
                    255,
                    kvImageNoFlags) == kvImageNoError;
  }
  if (!converted) {
    // Compatibility fallback for an unexpected Accelerate failure. Normal
    // Apple builds use the BT.709 vImage path above.
    [RTCYUVHelper I420ToARGB:i420Buffer.dataY
                  srcStrideY:i420Buffer.strideY
                        srcU:i420Buffer.dataU
                  srcStrideU:i420Buffer.strideU
                        srcV:i420Buffer.dataV
                  srcStrideV:i420Buffer.strideV
                     dstARGB:destination
               dstStrideARGB:(int)destinationStride
                       width:i420Buffer.width
                      height:i420Buffer.height];
  }
  CVPixelBufferUnlockBaseAddress(outputPixelBuffer, 0);
  [self applyOutputColorAttachments:outputPixelBuffer];
  return converted
      ? @"vImage BT.709 Video Range I420 → sRGB BGRA"
      : @"Compatibility I420 → BGRA fallback";
}

- (NSDictionary<NSString*, id>*)decodedInputDiagnosticsForFrame:(RTCVideoFrame*)frame {
  if ([frame.buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
    return CDRRendererPixelBufferDiagnostics(
        ((RTCCVPixelBuffer*)frame.buffer).pixelBuffer, @"ipad-decoder-output");
  }
  id<RTCI420Buffer> buffer = [frame.buffer toI420];
  NSMutableDictionary<NSString*, id>* diagnostics = [@{
    @"stage": @"ipad-decoder-output",
    @"width": @(buffer.width),
    @"height": @(buffer.height),
    @"pixelFormat": @"I420",
    @"range": @"Video Range (session contract)",
    @"colorPrimaries": @"ITU-R BT.709 (session contract)",
    @"transferFunction": @"ITU-R BT.709 (session contract)",
    @"yCbCrMatrix": @"ITU-R BT.709 (session contract)",
  } mutableCopy];
  [diagnostics addEntriesFromDictionary:CDRRendererLumaStatisticsForPlane(
      buffer.dataY,
      (size_t)buffer.width,
      (size_t)buffer.height,
      (size_t)buffer.strideY,
      16,
      235)];
  return diagnostics;
}

#pragma mark - RTCVideoRenderer methods
- (void)renderFrame:(RTCVideoFrame*)frame {

  __block NSDictionary<NSString*, id>* colorDiagnostics = nil;
  os_unfair_lock_lock(&_lock);
  if(_videoTrack == nil) {
    os_unfair_lock_unlock(&_lock);
    return;
  }
  if(!_frameAvailable && _pixelBufferRef) {
    NSString* conversion = [self copyFrameToCVPixelBuffer:_pixelBufferRef withFrame:frame];
    if (!_emittedColorDiagnostics) {
      _emittedColorDiagnostics = true;
      colorDiagnostics = @{
        @"decoderOutput": [self decodedInputDiagnosticsForFrame:frame],
        @"renderOutput": CDRRendererPixelBufferDiagnostics(
            _pixelBufferRef, @"ipad-texture-input"),
        @"conversion": conversion,
      };
      _lastColorDiagnostics = colorDiagnostics;
    }
    if(_textureId != -1) {
      [_registry textureFrameAvailable:_textureId];
    }
    _frameAvailable = true;
  }
  os_unfair_lock_unlock(&_lock);

  __weak FlutterRTCVideoRenderer* weakSelf = self;
  if (colorDiagnostics != nil) {
    dispatch_async(dispatch_get_main_queue(), ^{
      FlutterRTCVideoRenderer* strongSelf = weakSelf;
      if (strongSelf.eventSink) {
        strongSelf.eventSink(@{
          @"event": @"didReceiveColorDiagnostics",
          @"diagnostics": colorDiagnostics,
        });
      }
    });
  }
  if (_renderSize.width != frame.width || _renderSize.height != frame.height) {
    dispatch_async(dispatch_get_main_queue(), ^{
      FlutterRTCVideoRenderer* strongSelf = weakSelf;
      if (strongSelf.eventSink) {
        strongSelf.eventSink(@{
          @"event" : @"didTextureChangeVideoSize",
          @"id" : @(strongSelf.textureId),
          @"width" : @(frame.width),
          @"height" : @(frame.height),
        });
      }
    });
    _renderSize = CGSizeMake(frame.width, frame.height);
  }

  if (frame.rotation != _rotation) {
    dispatch_async(dispatch_get_main_queue(), ^{
      FlutterRTCVideoRenderer* strongSelf = weakSelf;
      if (strongSelf.eventSink) {
        strongSelf.eventSink(@{
          @"event" : @"didTextureChangeRotation",
          @"id" : @(strongSelf.textureId),
          @"rotation" : @(frame.rotation),
        });
      }
    });

    _rotation = frame.rotation;
  }

  // Notify the Flutter new pixelBufferRef to be ready.
  dispatch_async(dispatch_get_main_queue(), ^{
    FlutterRTCVideoRenderer* strongSelf = weakSelf;
    if (!strongSelf->_isFirstFrameRendered) {
      if (strongSelf.eventSink) {
        strongSelf.eventSink(@{@"event" : @"didFirstFrameRendered"});
        strongSelf->_isFirstFrameRendered = true;
      }
    }
  });
}

/**
 * Sets the size of the video frame to render.
 *
 * @param size The size of the video frame to render.
 */
- (void)setSize:(CGSize)size {
  os_unfair_lock_lock(&_lock);
  if (size.width != _frameSize.width || size.height != _frameSize.height) {
    if (_pixelBufferRef) {
      CVBufferRelease(_pixelBufferRef);
    }
    NSDictionary* pixelAttributes = @{
      (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
      (id)kCVPixelBufferMetalCompatibilityKey : @YES,
    };
    CVPixelBufferCreate(kCFAllocatorDefault, size.width, size.height, kCVPixelFormatType_32BGRA,
                        (__bridge CFDictionaryRef)(pixelAttributes), &_pixelBufferRef);
    _frameAvailable = false;
    _frameSize = size;
  }
  os_unfair_lock_unlock(&_lock);
}

#pragma mark - FlutterStreamHandler methods

- (FlutterError* _Nullable)onCancelWithArguments:(id _Nullable)arguments {
  _eventSink = nil;
  return nil;
}

- (FlutterError* _Nullable)onListenWithArguments:(id _Nullable)arguments
                                       eventSink:(nonnull FlutterEventSink)sink {
  _eventSink = sink;
  os_unfair_lock_lock(&_lock);
  NSDictionary<NSString*, id>* diagnostics = _lastColorDiagnostics;
  os_unfair_lock_unlock(&_lock);
  if (diagnostics != nil) {
    sink(@{
      @"event": @"didReceiveColorDiagnostics",
      @"diagnostics": diagnostics,
    });
  }
  return nil;
}
@end

@implementation FlutterWebRTCPlugin (FlutterVideoRendererManager)

- (FlutterRTCVideoRenderer*)createWithTextureRegistry:(id<FlutterTextureRegistry>)registry
                                            messenger:(NSObject<FlutterBinaryMessenger>*)messenger {
  return [[FlutterRTCVideoRenderer alloc] initWithTextureRegistry:registry messenger:messenger];
}

- (void)rendererSetSrcObject:(FlutterRTCVideoRenderer*)renderer stream:(RTCVideoTrack*)videoTrack {
  renderer.videoTrack = videoTrack;
}
@end
