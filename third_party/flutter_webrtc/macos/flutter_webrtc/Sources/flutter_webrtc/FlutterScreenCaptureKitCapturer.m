#import "FlutterScreenCaptureKitCapturer.h"

#import <CoreImage/CoreImage.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <Metal/Metal.h>
#import <math.h>
#import <string.h>

#import "VideoProcessingAdapter.h"

#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#endif

@interface FlutterScreenCaptureKitCapturer ()
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
<SCStreamOutput>
#endif
@property(nonatomic, strong) RTCVideoCapturer *capturer;
@property(nonatomic, weak) id<RTCVideoCapturerDelegate> delegate;
@property(nonatomic, strong) dispatch_queue_t captureQueue;
@property(nonatomic, copy) NSString *sourceId;
@property(nonatomic, assign) BOOL emittedColorDiagnostics;
@property(nonatomic, assign) BOOL emittedFirstFrame;
@property(nonatomic, strong) CIContext *colorContext;
@property(nonatomic, assign) CVPixelBufferPoolRef normalizationPool;
@property(nonatomic, assign) size_t normalizationPoolWidth;
@property(nonatomic, assign) size_t normalizationPoolHeight;
@property(nonatomic, assign) BOOL suppressingFramesForSwitch;
@property(nonatomic, assign) BOOL awaitingStableSwitchFrames;
@property(nonatomic, assign) NSUInteger stableSwitchFrameCount;
@property(nonatomic, assign) NSUInteger freshCanvasFrameCount;
@property(nonatomic, assign) NSUInteger captureGeneration;
@property(nonatomic, assign) size_t expectedFrameWidth;
@property(nonatomic, assign) size_t expectedFrameHeight;
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
@property(nonatomic, strong) SCStream *stream API_AVAILABLE(macos(12.3));
#endif
@end

static NSString *CDRFourCCName(OSType pixelFormat) {
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

static NSString *CDRPixelRangeName(OSType pixelFormat) {
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

static NSInteger CDREvenPixelDimension(CGFloat value) {
  NSInteger rounded = MAX((NSInteger)2, (NSInteger)llround(value));
  return rounded - (rounded % 2);
}

static CGColorRef CDRBlackBackgroundColor(void) {
  static CGColorRef color = NULL;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    color = CGColorCreateGenericRGB(0, 0, 0, 1);
  });
  return color;
}

static void CDRFillVideoRangeBlack(CVPixelBufferRef pixelBuffer) {
  if (pixelBuffer == NULL ||
      CVPixelBufferGetPixelFormatType(pixelBuffer) !=
          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
      CVPixelBufferLockBaseAddress(pixelBuffer, 0) != kCVReturnSuccess) {
    return;
  }
  const size_t planeCount = CVPixelBufferGetPlaneCount(pixelBuffer);
  if (planeCount >= 2) {
    uint8_t *luma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
    const size_t lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
    const size_t lumaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0);
    for (size_t row = 0; row < lumaHeight; row += 1) {
      memset(luma + row * lumaStride, 16, lumaStride);
    }
    uint8_t *chroma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
    const size_t chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
    const size_t chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1);
    for (size_t row = 0; row < chromaHeight; row += 1) {
      memset(chroma + row * chromaStride, 128, chromaStride);
    }
  }
  CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
}

#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
static NSDictionary<SCStreamFrameInfo, id> *CDRFrameAttachments(
    CMSampleBufferRef sampleBuffer) API_AVAILABLE(macos(12.3)) {
  CFArrayRef attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
      sampleBuffer, false);
  if (attachmentsArray == NULL || CFArrayGetCount(attachmentsArray) == 0) {
    return nil;
  }
  return (__bridge NSDictionary<SCStreamFrameInfo, id> *)
      CFArrayGetValueAtIndex(attachmentsArray, 0);
}

static BOOL CDRFrameIsComplete(
    CMSampleBufferRef sampleBuffer,
    NSDictionary<SCStreamFrameInfo, id> **frameAttachments)
    API_AVAILABLE(macos(12.3)) {
  if (!CMSampleBufferIsValid(sampleBuffer)) {
    return NO;
  }
  NSDictionary<SCStreamFrameInfo, id> *attachments =
      CDRFrameAttachments(sampleBuffer);
  NSNumber *status = attachments[SCStreamFrameInfoStatus];
  if (status == nil || status.integerValue != SCFrameStatusComplete) {
    return NO;
  }
  id contentRectValue = attachments[SCStreamFrameInfoContentRect];
  if (contentRectValue != nil) {
    CGRect contentRect = CGRectZero;
    if (![contentRectValue isKindOfClass:[NSDictionary class]] ||
        !CGRectMakeWithDictionaryRepresentation(
            (__bridge CFDictionaryRef)contentRectValue, &contentRect) ||
        CGRectIsEmpty(contentRect)) {
      return NO;
    }
  }
  if (frameAttachments != NULL) {
    *frameAttachments = attachments;
  }
  return YES;
}

static NSDictionary<NSString *, id> *CDRFrameGeometryDiagnostics(
    NSDictionary<SCStreamFrameInfo, id> *attachments,
    CVPixelBufferRef pixelBuffer) API_AVAILABLE(macos(12.3)) {
  CGRect contentRect = CGRectZero;
  id contentRectValue = attachments[SCStreamFrameInfoContentRect];
  if ([contentRectValue isKindOfClass:[NSDictionary class]]) {
    CGRectMakeWithDictionaryRepresentation(
        (__bridge CFDictionaryRef)contentRectValue, &contentRect);
  }
  NSNumber *contentScale = attachments[SCStreamFrameInfoContentScale];
  NSNumber *scaleFactor = attachments[SCStreamFrameInfoScaleFactor];
  return @{
    @"bufferWidth": @(CVPixelBufferGetWidth(pixelBuffer)),
    @"bufferHeight": @(CVPixelBufferGetHeight(pixelBuffer)),
    @"contentRectX": @(contentRect.origin.x),
    @"contentRectY": @(contentRect.origin.y),
    @"contentRectWidth": @(contentRect.size.width),
    @"contentRectHeight": @(contentRect.size.height),
    @"contentScale": contentScale ?: @0,
    @"scaleFactor": scaleFactor ?: @0,
    @"captureGeneration": @0,
  };
}
#endif

static NSString *CDRAttachmentString(CVPixelBufferRef pixelBuffer, CFStringRef key) {
  CFTypeRef value = CVBufferGetAttachment(pixelBuffer, key, NULL);
  if (value == NULL) {
    return @"Unknown";
  }
  if (CFGetTypeID(value) == CFStringGetTypeID()) {
    return (__bridge NSString *)value;
  }
  return [(__bridge id)value description] ?: @"Unknown";
}

static BOOL CDRAttachmentEquals(CVPixelBufferRef pixelBuffer,
                                CFStringRef key,
                                CFStringRef expected) {
  CFTypeRef value = CVBufferGetAttachment(pixelBuffer, key, NULL);
  return value != NULL && CFEqual(value, expected);
}

static BOOL CDRNeedsSDRNormalization(CVPixelBufferRef pixelBuffer) {
  if (CVPixelBufferGetPixelFormatType(pixelBuffer) !=
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
    return YES;
  }
  return !CDRAttachmentEquals(pixelBuffer,
                              kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2) ||
         !CDRAttachmentEquals(pixelBuffer,
                              kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2) ||
         !CDRAttachmentEquals(pixelBuffer,
                              kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2);
}

static NSDictionary<NSString *, id> *CDRLumaStatistics(CVPixelBufferRef pixelBuffer) {
  OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
  const BOOL isYUV = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                     pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
  const BOOL isBGRA = pixelFormat == kCVPixelFormatType_32BGRA;
  if (!isYUV && !isBGRA) {
    return @{
      @"sampleCount": @0,
      @"lumaMin": @0,
      @"lumaMax": @0,
      @"belowNominalBlackPercent": @0,
      @"aboveNominalWhitePercent": @0,
      @"lumaHistogram16": @[],
      @"note": @"当前像素格式不支持低开销直方图"
    };
  }

  if (CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
    return @{ @"sampleCount": @0, @"note": @"无法锁定 PixelBuffer" };
  }

  const size_t width = CVPixelBufferGetWidth(pixelBuffer);
  const size_t height = CVPixelBufferGetHeight(pixelBuffer);
  const size_t stepX = MAX((size_t)1, width / 128);
  const size_t stepY = MAX((size_t)1, height / 128);
  uint64_t buckets[16] = {0};
  uint64_t sampleCount = 0;
  uint64_t belowBlack = 0;
  uint64_t aboveWhite = 0;
  uint8_t minimum = UINT8_MAX;
  uint8_t maximum = 0;
  const uint8_t nominalBlack = isYUV &&
          pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
      ? 16
      : 0;
  const uint8_t nominalWhite = isYUV &&
          pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
      ? 235
      : 255;

  if (isYUV) {
    const uint8_t *base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
    const size_t stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
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
  } else {
    const uint8_t *base = CVPixelBufferGetBaseAddress(pixelBuffer);
    const size_t stride = CVPixelBufferGetBytesPerRow(pixelBuffer);
    for (size_t y = 0; y < height; y += stepY) {
      const uint8_t *row = base + y * stride;
      for (size_t x = 0; x < width; x += stepX) {
        const uint8_t *pixel = row + x * 4;
        const uint8_t luma = (uint8_t)((19 * pixel[0] + 183 * pixel[1] + 54 * pixel[2]) >> 8);
        minimum = MIN(minimum, luma);
        maximum = MAX(maximum, luma);
        buckets[MIN((NSUInteger)15, (NSUInteger)(luma / 16))] += 1;
        sampleCount += 1;
      }
    }
  }

  CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
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

static NSDictionary<NSString *, id> *CDRPixelBufferDiagnostics(
    CVPixelBufferRef pixelBuffer,
    NSString *stage) {
  OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
  NSString *transfer = CDRAttachmentString(
      pixelBuffer, kCVImageBufferTransferFunctionKey);
  NSString *dynamicRange = @"SDR";
  if ([transfer isEqualToString:(__bridge NSString *)kCVImageBufferTransferFunction_ITU_R_2100_HLG] ||
      [transfer isEqualToString:(__bridge NSString *)kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ]) {
    dynamicRange = @"HDR";
  }
  NSMutableDictionary<NSString *, id> *result = [@{
    @"stage": stage,
    @"width": @(CVPixelBufferGetWidth(pixelBuffer)),
    @"height": @(CVPixelBufferGetHeight(pixelBuffer)),
    @"pixelFormat": CDRFourCCName(pixelFormat),
    @"range": CDRPixelRangeName(pixelFormat),
    @"colorPrimaries": CDRAttachmentString(pixelBuffer, kCVImageBufferColorPrimariesKey),
    @"transferFunction": transfer,
    @"yCbCrMatrix": CDRAttachmentString(pixelBuffer, kCVImageBufferYCbCrMatrixKey),
    @"dynamicRange": dynamicRange,
  } mutableCopy];
  [result addEntriesFromDictionary:CDRLumaStatistics(pixelBuffer)];
  return result;
}

@implementation FlutterScreenCaptureKitCapturer

- (instancetype)initWithDelegate:(id<RTCVideoCapturerDelegate>)delegate {
  self = [super init];
  if (self) {
    _delegate = delegate;
    _capturer = [[RTCVideoCapturer alloc] initWithDelegate:delegate];
    _captureQueue = dispatch_queue_create("com.iperius.sck.capture", DISPATCH_QUEUE_SERIAL);
    id<MTLDevice> metalDevice = MTLCreateSystemDefaultDevice();
    _colorContext = metalDevice != nil
        ? [CIContext contextWithMTLDevice:metalDevice options:nil]
        : [CIContext contextWithOptions:nil];
  }
  return self;
}

- (void)dealloc {
  if (_normalizationPool != NULL) {
    CVPixelBufferPoolRelease(_normalizationPool);
    _normalizationPool = NULL;
  }
}

#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
- (SCStreamConfiguration *)streamConfigurationForDisplay:(SCDisplay *)display
                                                   filter:(SCContentFilter *)filter
                                                      fps:(NSInteger)fps
                                           targetLongEdge:(NSInteger)targetLongEdge
    API_AVAILABLE(macos(12.3)) {
  SCStreamConfiguration *config = [SCStreamConfiguration new];
  CGFloat outputWidth = display.width;
  CGFloat outputHeight = display.height;
  if (@available(macOS 14.0, *)) {
    // SCDisplay dimensions are points. Capture the filter's physical pixels so
    // Retina and Sidecar sources are not upscaled by the controller.
    outputWidth = filter.contentRect.size.width * filter.pointPixelScale;
    outputHeight = filter.contentRect.size.height * filter.pointPixelScale;
    config.captureResolution = SCCaptureResolutionBest;
  } else {
    const size_t pixelWidth = CGDisplayPixelsWide(display.displayID);
    const size_t pixelHeight = CGDisplayPixelsHigh(display.displayID);
    if (pixelWidth > 0 && pixelHeight > 0) {
      outputWidth = pixelWidth;
      outputHeight = pixelHeight;
    }
  }
  const CGFloat sourceLongEdge = MAX(outputWidth, outputHeight);
  if (targetLongEdge > 0 && sourceLongEdge > targetLongEdge) {
    const CGFloat scale = (CGFloat)targetLongEdge / sourceLongEdge;
    outputWidth *= scale;
    outputHeight *= scale;
  }
  config.width = CDREvenPixelDimension(outputWidth);
  config.height = CDREvenPixelDimension(outputHeight);
  config.minimumFrameInterval = CMTimeMake(1, (int32_t)MAX(1, fps));
  config.queueDepth = 3;
  config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
  config.colorSpaceName = kCGColorSpaceITUR_709;
  config.colorMatrix = kCGDisplayStreamYCbCrMatrix_ITU_R_709_2;
  config.scalesToFit = YES;
  config.destinationRect = CGRectMake(0, 0, config.width, config.height);
  config.backgroundColor = CDRBlackBackgroundColor();
  if (@available(macOS 15.0, *)) {
    config.captureDynamicRange = SCCaptureDynamicRangeSDR;
  }
  if (@available(macOS 14.0, *)) {
    config.preservesAspectRatio = YES;
    config.shouldBeOpaque = YES;
  }
  if (@available(macOS 13.0, *)) {
    config.showsCursor = YES;
  }
  return config;
}
#endif

- (void)startCaptureWithFPS:(NSInteger)fps
                   sourceId:(NSString* _Nullable)sourceId
             targetLongEdge:(NSInteger)targetLongEdge
                  onStarted:(void (^)(NSError * _Nullable error))onStarted {
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
  if (@available(macOS 12.3, *)) {
    self.sourceId = sourceId ?: @"";
    self.emittedColorDiagnostics = NO;
    self.emittedFirstFrame = NO;
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
      if (error != nil) {
        onStarted(error);
        return;
      }

      SCDisplay *display = [self selectDisplayFromContent:content sourceId:sourceId];
      if (display == nil) {
        NSError *noDisplay = [NSError errorWithDomain:@"FlutterScreenCaptureKit"
                                                 code:-1
                                             userInfo:@{NSLocalizedDescriptionKey: @"No matching display"}];
        onStarted(noDisplay);
        return;
      }

      SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
      SCStreamConfiguration *config =
          [self streamConfigurationForDisplay:display
                                       filter:filter
                                          fps:fps
                               targetLongEdge:targetLongEdge];

      dispatch_async(self.captureQueue, ^{
        self.expectedFrameWidth = config.width;
        self.expectedFrameHeight = config.height;
      });

      self.stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:nil];
      NSError *addOutputError = nil;
      [self.stream addStreamOutput:self
                              type:SCStreamOutputTypeScreen
               sampleHandlerQueue:self.captureQueue
                            error:&addOutputError];
      if (addOutputError != nil) {
        onStarted(addOutputError);
        return;
      }

      [self.stream startCaptureWithCompletionHandler:^(NSError * _Nullable startError) {
        onStarted(startError);
      }];
    }];
    return;
  }
#endif

  NSError *unavailable = [NSError errorWithDomain:@"FlutterScreenCaptureKit"
                                             code:-2
                                         userInfo:@{NSLocalizedDescriptionKey: @"ScreenCaptureKit not available"}];
  onStarted(unavailable);
}

- (void)switchCaptureToSourceId:(NSString *)sourceId
                            fps:(NSInteger)fps
                 targetLongEdge:(NSInteger)targetLongEdge
                   onCompletion:(void (^)(NSError * _Nullable error))onCompletion {
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
  if (@available(macOS 13.0, *)) {
    SCStream *stream = self.stream;
    if (stream == nil) {
      NSError *notRunning = [NSError errorWithDomain:@"FlutterScreenCaptureKit"
                                                 code:-3
                                             userInfo:@{
                                               NSLocalizedDescriptionKey:
                                                   @"ScreenCaptureKit stream is not running"
                                             }];
      onCompletion(notRunning);
      return;
    }
    dispatch_async(self.captureQueue, ^{
      self.captureGeneration += 1;
      const NSUInteger generation = self.captureGeneration;
      self.suppressingFramesForSwitch = YES;
      self.awaitingStableSwitchFrames = NO;
      self.stableSwitchFrameCount = 0;
      self.freshCanvasFrameCount = 0;
      [SCShareableContent
          getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
          void (^finishWithError)(NSError *) = ^(NSError *switchError) {
            dispatch_async(self.captureQueue, ^{
              if (generation == self.captureGeneration) {
                self.suppressingFramesForSwitch = NO;
                self.awaitingStableSwitchFrames = NO;
                self.stableSwitchFrameCount = 0;
              }
              onCompletion(switchError);
            });
          };
          if (error != nil) {
            finishWithError(error);
            return;
          }
          SCDisplay *display = [self selectDisplayFromContent:content sourceId:sourceId];
          if (display == nil) {
            NSError *noDisplay = [NSError errorWithDomain:@"FlutterScreenCaptureKit"
                                                      code:-1
                                                  userInfo:@{
                                                    NSLocalizedDescriptionKey:
                                                        @"No matching display"
                                                  }];
            finishWithError(noDisplay);
            return;
          }
          SCContentFilter *filter =
              [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
          SCStreamConfiguration *configuration =
              [self streamConfigurationForDisplay:display
                                           filter:filter
                                              fps:fps
                                   targetLongEdge:targetLongEdge];
          [stream updateConfiguration:configuration
                   completionHandler:^(NSError *configurationError) {
                     if (configurationError != nil) {
                       finishWithError(configurationError);
                       return;
                     }
                     [stream updateContentFilter:filter
                               completionHandler:^(NSError *filterError) {
                                 if (filterError != nil) {
                                   finishWithError(filterError);
                                   return;
                                 }
                                 dispatch_async(self.captureQueue, ^{
                                   if (generation != self.captureGeneration) {
                                     return;
                                   }
                                   self.sourceId = sourceId;
                                   self.emittedFirstFrame = NO;
                                   self.emittedColorDiagnostics = NO;
                                   self.expectedFrameWidth = configuration.width;
                                   self.expectedFrameHeight = configuration.height;
                                   self.stableSwitchFrameCount = 0;
                                   self.freshCanvasFrameCount = 2;
                                   self.awaitingStableSwitchFrames = YES;
                                   self.suppressingFramesForSwitch = NO;
                                   [(VideoProcessingAdapter *)self.delegate
                                       setPreferredFramesPerSecond:fps];
                                   onCompletion(nil);
                                 });
                               }];
                   }];
          }];
    });
    return;
  }
#endif
  NSError *unavailable = [NSError errorWithDomain:@"FlutterScreenCaptureKit"
                                              code:-2
                                          userInfo:@{
                                            NSLocalizedDescriptionKey:
                                                @"In-place screen switching is unavailable"
                                          }];
  onCompletion(unavailable);
}

- (void)updateCaptureWithFPS:(NSInteger)fps
              targetLongEdge:(NSInteger)targetLongEdge
                onCompletion:(void (^)(NSError * _Nullable error))onCompletion {
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
  if (@available(macOS 13.0, *)) {
    SCStream *stream = self.stream;
    if (stream == nil) {
      NSError *notRunning = [NSError errorWithDomain:@"FlutterScreenCaptureKit"
                                                 code:-3
                                             userInfo:@{
                                               NSLocalizedDescriptionKey:
                                                   @"ScreenCaptureKit stream is not running"
                                             }];
      onCompletion(notRunning);
      return;
    }
    dispatch_async(self.captureQueue, ^{
      self.suppressingFramesForSwitch = YES;
      [SCShareableContent
          getShareableContentWithCompletionHandler:^(SCShareableContent *content,
                                                      NSError *error) {
            if (error != nil) {
              dispatch_async(self.captureQueue, ^{
                self.suppressingFramesForSwitch = NO;
                onCompletion(error);
              });
              return;
            }
            SCDisplay *display = [self selectDisplayFromContent:content
                                                       sourceId:self.sourceId];
            if (display == nil) {
              NSError *noDisplay = [NSError errorWithDomain:@"FlutterScreenCaptureKit"
                                                        code:-1
                                                    userInfo:@{
                                                      NSLocalizedDescriptionKey:
                                                          @"No matching display"
                                                    }];
              dispatch_async(self.captureQueue, ^{
                self.suppressingFramesForSwitch = NO;
                onCompletion(noDisplay);
              });
              return;
            }
            SCContentFilter *filter =
                [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
            SCStreamConfiguration *configuration =
                [self streamConfigurationForDisplay:display
                                             filter:filter
                                                fps:fps
                                     targetLongEdge:targetLongEdge];
            [stream updateConfiguration:configuration
                     completionHandler:^(NSError *configurationError) {
                       dispatch_async(self.captureQueue, ^{
                         if (configurationError == nil) {
                           self.expectedFrameWidth = configuration.width;
                           self.expectedFrameHeight = configuration.height;
                           self.stableSwitchFrameCount = 0;
                           self.freshCanvasFrameCount = 1;
                           self.awaitingStableSwitchFrames = YES;
                           [(VideoProcessingAdapter *)self.delegate
                               setPreferredFramesPerSecond:fps];
                         }
                         self.suppressingFramesForSwitch = NO;
                         onCompletion(configurationError);
                       });
                     }];
          }];
    });
    return;
  }
#endif
  NSError *unavailable = [NSError errorWithDomain:@"FlutterScreenCaptureKit"
                                              code:-2
                                          userInfo:@{
                                            NSLocalizedDescriptionKey:
                                                @"Capture reconfiguration is unavailable"
                                          }];
  onCompletion(unavailable);
}

- (void)stopCaptureWithCompletion:(void (^)(void))completion {
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
  if (@available(macOS 12.3, *)) {
    if (self.stream == nil) {
      completion();
      return;
    }
    SCStream *stream = self.stream;
    self.stream = nil;
    [stream stopCaptureWithCompletionHandler:^(__unused NSError * _Nullable error) {
      completion();
    }];
    return;
  }
#endif
  completion();
}

- (BOOL)ensureNormalizationPoolWithWidth:(size_t)width height:(size_t)height {
  if (self.normalizationPool != NULL &&
      self.normalizationPoolWidth == width &&
      self.normalizationPoolHeight == height) {
    return YES;
  }
  if (self.normalizationPool != NULL) {
    CVPixelBufferPoolRelease(self.normalizationPool);
    self.normalizationPool = NULL;
  }

  NSDictionary *attributes = @{
    (id)kCVPixelBufferWidthKey: @(width),
    (id)kCVPixelBufferHeightKey: @(height),
    (id)kCVPixelBufferPixelFormatTypeKey:
        @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
    (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    (id)kCVPixelBufferMetalCompatibilityKey: @YES,
  };
  CVPixelBufferPoolRef pool = NULL;
  CVReturn result = CVPixelBufferPoolCreate(
      kCFAllocatorDefault,
      NULL,
      (__bridge CFDictionaryRef)attributes,
      &pool);
  if (result != kCVReturnSuccess || pool == NULL) {
    return NO;
  }
  self.normalizationPool = pool;
  self.normalizationPoolWidth = width;
  self.normalizationPoolHeight = height;
  return YES;
}

- (CVPixelBufferRef)newNormalizedSDRPixelBufferFromPixelBuffer:(CVPixelBufferRef)source {
  const size_t width = CVPixelBufferGetWidth(source);
  const size_t height = CVPixelBufferGetHeight(source);
  if (![self ensureNormalizationPoolWithWidth:width height:height]) {
    return NULL;
  }

  CVPixelBufferRef output = NULL;
  if (CVPixelBufferPoolCreatePixelBuffer(
          kCFAllocatorDefault, self.normalizationPool, &output) != kCVReturnSuccess ||
      output == NULL) {
    return NULL;
  }
  CDRFillVideoRangeBlack(output);

  NSMutableDictionary<CIImageOption, id> *options = [NSMutableDictionary dictionary];
  if (@available(macOS 11.0, *)) {
    options[kCIImageToneMapHDRtoSDR] = @YES;
  }
  CIImage *image = [CIImage imageWithCVPixelBuffer:source options:options];
  CGColorSpaceRef outputColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
  @try {
    [self.colorContext render:image
              toCVPixelBuffer:output
                       bounds:CGRectMake(0, 0, width, height)
                   colorSpace:outputColorSpace];
  } @catch (NSException *exception) {
    NSLog(@"CrossDesktopRemote Core Image SDR normalization failed: %@", exception);
    if (outputColorSpace != NULL) {
      CGColorSpaceRelease(outputColorSpace);
    }
    CVPixelBufferRelease(output);
    return NULL;
  }
  if (outputColorSpace != NULL) {
    CGColorSpaceRelease(outputColorSpace);
  }

  CVBufferSetAttachment(output,
                        kCVImageBufferColorPrimariesKey,
                        kCVImageBufferColorPrimaries_ITU_R_709_2,
                        kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(output,
                        kCVImageBufferTransferFunctionKey,
                        kCVImageBufferTransferFunction_ITU_R_709_2,
                        kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(output,
                        kCVImageBufferYCbCrMatrixKey,
                        kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                        kCVAttachmentMode_ShouldPropagate);
  return output;
}

#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
- (SCDisplay *)selectDisplayFromContent:(SCShareableContent *)content
                               sourceId:(NSString *)sourceId API_AVAILABLE(macos(12.3)) {
  if (content.displays.count == 0) {
    return nil;
  }

  if (sourceId != nil && sourceId.length > 0) {
    for (SCDisplay *display in content.displays) {
      if ([[NSString stringWithFormat:@"%u", display.displayID] isEqualToString:sourceId]) {
        return display;
      }
    }
  }

  CGDirectDisplayID mainDisplay = CGMainDisplayID();
  for (SCDisplay *display in content.displays) {
    if (display.displayID == mainDisplay) {
      return display;
    }
  }

  return content.displays.firstObject;
}

- (void)stream:(SCStream *)stream
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
        ofType:(SCStreamOutputType)type API_AVAILABLE(macos(12.3)) {
  if (type != SCStreamOutputTypeScreen) {
    return;
  }

  NSDictionary<SCStreamFrameInfo, id> *frameAttachments = nil;
  if (!CDRFrameIsComplete(sampleBuffer, &frameAttachments) ||
      self.suppressingFramesForSwitch) {
    return;
  }

  CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  if (pixelBuffer == nil) {
    return;
  }

  if (self.awaitingStableSwitchFrames) {
    const size_t width = CVPixelBufferGetWidth(pixelBuffer);
    const size_t height = CVPixelBufferGetHeight(pixelBuffer);
    if ((self.expectedFrameWidth > 0 && width != self.expectedFrameWidth) ||
        (self.expectedFrameHeight > 0 && height != self.expectedFrameHeight)) {
      self.stableSwitchFrameCount = 0;
      return;
    }
    self.stableSwitchFrameCount += 1;
    if (self.stableSwitchFrameCount < 2) {
      return;
    }
    self.awaitingStableSwitchFrames = NO;
    NSLog(@"CrossDesktopRemote accepted display generation %lu after %lu complete frames (%zux%zu), metadata=%@",
          (unsigned long)self.captureGeneration,
          (unsigned long)self.stableSwitchFrameCount,
          width,
          height,
          frameAttachments);
  }

  const BOOL needsFreshCanvas = self.freshCanvasFrameCount > 0;
  if (needsFreshCanvas) {
    self.freshCanvasFrameCount -= 1;
  }

  if (!self.emittedFirstFrame) {
    self.emittedFirstFrame = YES;
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"CrossDesktopRemoteCaptureFirstFrame"
                      object:nil
                    userInfo:@{
                      @"sourceId": self.sourceId ?: @"",
                      @"width": @(CVPixelBufferGetWidth(pixelBuffer)),
                      @"height": @(CVPixelBufferGetHeight(pixelBuffer)),
                    }];
  }

  // Do not relabel the ScreenCaptureKit buffer. Relabelling HDR/full-range
  // pixels as SDR/video-range changes metadata without changing the samples
  // and is a direct cause of clipped or washed-out highlights. Core Image
  // performs an actual GPU color conversion and automatic HDR-to-SDR tone map
  // into a fresh Rec.709 video-range NV12 buffer.
  NSDictionary<NSString *, id> *rawDiagnostics = nil;
  if (!self.emittedColorDiagnostics) {
    rawDiagnostics = CDRPixelBufferDiagnostics(pixelBuffer, @"screen-capture-kit-raw");
  }
  const BOOL needsNormalization = CDRNeedsSDRNormalization(pixelBuffer);
  const CFAbsoluteTime normalizationStartedAt = CFAbsoluteTimeGetCurrent();
  CVPixelBufferRef normalizedPixelBuffer = (needsNormalization || needsFreshCanvas)
      ? [self newNormalizedSDRPixelBufferFromPixelBuffer:pixelBuffer]
      : NULL;
  const double normalizationDurationMs =
      (CFAbsoluteTimeGetCurrent() - normalizationStartedAt) * 1000.0;
  CVPixelBufferRef encoderPixelBuffer = normalizedPixelBuffer ?: pixelBuffer;

  if (!self.emittedColorDiagnostics) {
    self.emittedColorDiagnostics = YES;
    NSDictionary<NSString *, id> *encoderDiagnostics =
        CDRPixelBufferDiagnostics(encoderPixelBuffer, @"webrtc-encoder-input");
    NSMutableDictionary<NSString *, id> *diagnostics = [encoderDiagnostics mutableCopy];
    diagnostics[@"sourceId"] = self.sourceId ?: @"";
    diagnostics[@"colorSpace"] = @"ITU-R BT.709";
    diagnostics[@"captureDynamicRange"] = normalizedPixelBuffer != NULL
        ? @"SDR (Core Image normalized)"
        : encoderDiagnostics[@"dynamicRange"] ?: @"Unknown";
    diagnostics[@"normalization"] = !needsNormalization && !needsFreshCanvas
        ? @"Native SDR Rec.709 420v · zero-copy bypass"
        : !needsNormalization && normalizedPixelBuffer != NULL
            ? @"Fresh switch canvas · Rec.709 · Video Range NV12"
        : normalizedPixelBuffer != NULL
            ? @"Core Image GPU HDR→SDR · Rec.709 · Video Range NV12"
            : @"Normalization failed; original frame forwarded";
    diagnostics[@"normalizationBypassed"] = @(!needsNormalization && !needsFreshCanvas);
    diagnostics[@"normalizationDurationMs"] = @(normalizationDurationMs);
    diagnostics[@"rawFrame"] = rawDiagnostics ?: @{};
    diagnostics[@"encoderInput"] = encoderDiagnostics;
    NSMutableDictionary<NSString *, id> *frameGeometry =
        [CDRFrameGeometryDiagnostics(frameAttachments, pixelBuffer) mutableCopy];
    frameGeometry[@"captureGeneration"] = @(self.captureGeneration);
    diagnostics[@"frameGeometry"] = frameGeometry;
    NSLog(@"CrossDesktopRemote capture color diagnostics: %@", diagnostics);
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"CrossDesktopRemoteCaptureColorDiagnostics"
                      object:nil
                    userInfo:diagnostics];
  }

  CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
  int64_t timeStampNs = (int64_t)(CMTimeGetSeconds(timestamp) * 1000000000.0);

  id<RTCVideoFrameBuffer> rtcBuffer =
      [[RTCCVPixelBuffer alloc] initWithPixelBuffer:encoderPixelBuffer];
  RTCVideoFrame *frame = [[RTCVideoFrame alloc] initWithBuffer:rtcBuffer
                                                      rotation:RTCVideoRotation_0
                                                   timeStampNs:timeStampNs];
  [self.delegate capturer:self.capturer didCaptureVideoFrame:frame];
  if (normalizedPixelBuffer != NULL) {
    CVPixelBufferRelease(normalizedPixelBuffer);
  }
}
#endif

@end
