#import "FlutterScreenCaptureKitCapturer.h"

#import <CoreImage/CoreImage.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <Metal/Metal.h>
#import <mach/mach_time.h>
#import <math.h>
#import <stdlib.h>
#import <string.h>

#import "VideoProcessingAdapter.h"

#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
#import <ScreenCaptureKit/ScreenCaptureKit.h>

typedef void (^CDRCaptureSwitchCompletion)(
    NSDictionary<NSString *, id> * _Nullable configuration,
    NSError * _Nullable error);
#endif

@interface FlutterScreenCaptureKitCapturer ()
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
<SCStreamOutput, SCStreamDelegate>
#endif
@property(nonatomic, strong) RTCVideoCapturer *capturer;
@property(nonatomic, weak) id<RTCVideoCapturerDelegate> delegate;
@property(nonatomic, strong) dispatch_queue_t captureQueue;
@property(nonatomic, copy) NSString *sourceId;
@property(nonatomic, assign) BOOL emittedColorDiagnostics;
@property(nonatomic, assign) BOOL emittedFirstFrame;
@property(nonatomic, assign) BOOL preserveVisibleContentGeometry;
@property(nonatomic, strong) CIContext *colorContext;
@property(nonatomic, assign) CVPixelBufferPoolRef normalizationPool;
@property(nonatomic, assign) size_t normalizationPoolWidth;
@property(nonatomic, assign) size_t normalizationPoolHeight;
@property(nonatomic, assign) BOOL awaitingStableSwitchFrames;
@property(nonatomic, assign) NSUInteger stableSwitchFrameCount;
@property(nonatomic, assign) NSUInteger freshCanvasFrameCount;
@property(nonatomic, assign) NSUInteger captureGeneration;
@property(nonatomic, assign) size_t expectedFrameWidth;
@property(nonatomic, assign) size_t expectedFrameHeight;
@property(nonatomic, assign) NSInteger expectedFrameRate;
@property(nonatomic, assign) uint64_t switchFrameDisplayTimeBarrier;
@property(nonatomic, assign) CFAbsoluteTime switchFrameGateStartedAt;
@property(nonatomic, assign) NSUInteger rejectedStaleFrameCount;
@property(nonatomic, assign) NSUInteger rejectedWrongSizeCount;
@property(nonatomic, assign) NSUInteger missingContentMetadataCount;
@property(nonatomic, assign) NSUInteger contentAspectMismatchCount;
@property(nonatomic, assign) NSUInteger normalizationFailureCount;
@property(nonatomic, assign) BOOL captureFormatUpdateInProgress;
@property(nonatomic, assign) NSUInteger captureFormatEpoch;
@property(nonatomic, copy) NSString *lastFrameGateRejection;
@property(nonatomic, assign) CFAbsoluteTime lastFrameGateNotificationAt;
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
@property(nonatomic, strong) SCStream *stream API_AVAILABLE(macos(12.3));
@property(nonatomic, strong) SCStream *pendingStream API_AVAILABLE(macos(12.3));
@property(nonatomic, strong) SCStream *retiredStream API_AVAILABLE(macos(12.3));
@property(nonatomic, copy) NSString *pendingSourceId;
@property(nonatomic, assign) NSUInteger pendingGeneration;
@property(nonatomic, assign) size_t pendingExpectedFrameWidth;
@property(nonatomic, assign) size_t pendingExpectedFrameHeight;
@property(nonatomic, assign) NSInteger pendingFrameRate;
@property(nonatomic, assign) NSUInteger pendingStableFrameCount;
@property(nonatomic, assign) NSUInteger pendingCompleteFrameCount;
@property(nonatomic, assign) NSUInteger pendingRejectedStaleFrameCount;
@property(nonatomic, assign) NSUInteger pendingRejectedGeometryFrameCount;
@property(nonatomic, assign) NSUInteger pendingMissingMetadataFrameCount;
@property(nonatomic, assign) NSUInteger pendingContentAspectMismatchCount;
@property(nonatomic, assign) NSUInteger pendingMetadataFallbackCount;
@property(nonatomic, assign) size_t pendingLastFrameWidth;
@property(nonatomic, assign) size_t pendingLastFrameHeight;
@property(nonatomic, assign) CFAbsoluteTime pendingStartedAt;
@property(nonatomic, assign) uint64_t pendingDisplayTimeBarrier;
@property(nonatomic, copy) CDRCaptureSwitchCompletion pendingSwitchCompletion;
@property(nonatomic, copy) NSString *retiredSourceId;
@property(nonatomic, assign) size_t retiredExpectedFrameWidth;
@property(nonatomic, assign) size_t retiredExpectedFrameHeight;
@property(nonatomic, assign) NSInteger retiredFrameRate;
@property(nonatomic, assign) CVPixelBufferRef lastActiveEncoderPixelBuffer;
@property(nonatomic, assign) CVPixelBufferRef retiredEncoderPixelBuffer;
@property(nonatomic, assign) CGRect lastActiveContentRect;
@property(nonatomic, assign) CGRect retiredActiveContentRect;
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

static BOOL CDRFrameIsUsable(
    CMSampleBufferRef sampleBuffer,
    NSDictionary<SCStreamFrameInfo, id> **frameAttachments)
    API_AVAILABLE(macos(12.3)) {
  if (!CMSampleBufferIsValid(sampleBuffer)) {
    return NO;
  }
  NSDictionary<SCStreamFrameInfo, id> *attachments =
      CDRFrameAttachments(sampleBuffer);
  NSNumber *status = attachments[SCStreamFrameInfoStatus];
  if (status != nil) {
    switch (status.integerValue) {
      case SCFrameStatusComplete:
      case SCFrameStatusStarted:
      case SCFrameStatusIdle:
        break;
      default:
        return NO;
    }
  }
  if (frameAttachments != NULL) {
    *frameAttachments = attachments ?: @{};
  }
  return YES;
}

static CGRect CDRVisibleContentPixelRect(
    NSDictionary<SCStreamFrameInfo, id> *attachments,
    CVPixelBufferRef pixelBuffer,
    BOOL *hasMetadata) API_AVAILABLE(macos(12.3)) {
  const CGRect bufferBounds = CGRectMake(
      0,
      0,
      CVPixelBufferGetWidth(pixelBuffer),
      CVPixelBufferGetHeight(pixelBuffer));
  if (hasMetadata != NULL) {
    *hasMetadata = NO;
  }
  id contentRectValue = attachments[SCStreamFrameInfoContentRect];
  NSNumber *scaleFactorValue = attachments[SCStreamFrameInfoScaleFactor];
  if (![contentRectValue isKindOfClass:[NSDictionary class]] ||
      ![scaleFactorValue isKindOfClass:[NSNumber class]]) {
    return bufferBounds;
  }
  CGRect contentRect = CGRectZero;
  const CGFloat scaleFactor = scaleFactorValue.doubleValue;
  if (!CGRectMakeWithDictionaryRepresentation(
          (__bridge CFDictionaryRef)contentRectValue, &contentRect) ||
      CGRectIsEmpty(contentRect) ||
      !isfinite(scaleFactor) ||
      scaleFactor <= 0) {
    return bufferBounds;
  }

  // ScreenCaptureKit reports contentRect in surface points. Chromium and
  // Apple's sample both use scaleFactor to convert it to the IOSurface pixel
  // coordinate space before cropping or encoding the frame.
  CGRect visibleRect = CGRectMake(
      contentRect.origin.x * scaleFactor,
      contentRect.origin.y * scaleFactor,
      contentRect.size.width * scaleFactor,
      contentRect.size.height * scaleFactor);
  visibleRect = CGRectIntersection(CGRectStandardize(visibleRect), bufferBounds);
  if (CGRectIsNull(visibleRect) || CGRectIsEmpty(visibleRect)) {
    return bufferBounds;
  }
  visibleRect = CGRectIntegral(visibleRect);
  visibleRect = CGRectIntersection(visibleRect, bufferBounds);
  if (CGRectIsNull(visibleRect) || CGRectIsEmpty(visibleRect)) {
    return bufferBounds;
  }
  if (hasMetadata != NULL) {
    *hasMetadata = YES;
  }
  return visibleRect;
}

static BOOL CDRVisibleContentFillsBuffer(
    CGRect visibleRect,
    CVPixelBufferRef pixelBuffer) {
  const CGFloat width = CVPixelBufferGetWidth(pixelBuffer);
  const CGFloat height = CVPixelBufferGetHeight(pixelBuffer);
  const CGFloat tolerance = 2.0;
  return fabs(CGRectGetMinX(visibleRect)) <= tolerance &&
      fabs(CGRectGetMinY(visibleRect)) <= tolerance &&
      fabs(CGRectGetMaxX(visibleRect) - width) <= tolerance &&
      fabs(CGRectGetMaxY(visibleRect) - height) <= tolerance;
}

static BOOL CDRBufferDimensionsMatch(
    size_t width,
    size_t height,
    size_t targetWidth,
    size_t targetHeight) {
  if (width == 0 || height == 0 || targetWidth == 0 || targetHeight == 0) {
    return NO;
  }
  const long long widthDelta = llabs((long long)width - (long long)targetWidth);
  const long long heightDelta = llabs((long long)height - (long long)targetHeight);
  return widthDelta <= 2 && heightDelta <= 2;
}

static BOOL CDRVisibleContentMatchesTargetAspect(
    NSDictionary<SCStreamFrameInfo, id> *attachments,
    size_t targetWidth,
    size_t targetHeight) API_AVAILABLE(macos(12.3)) {
  if (targetWidth == 0 || targetHeight == 0) {
    return NO;
  }
  id contentRectValue = attachments[SCStreamFrameInfoContentRect];
  if (![contentRectValue isKindOfClass:[NSDictionary class]]) {
    return NO;
  }
  CGRect contentRect = CGRectZero;
  if (!CGRectMakeWithDictionaryRepresentation(
          (__bridge CFDictionaryRef)contentRectValue, &contentRect) ||
      CGRectIsEmpty(contentRect)) {
    return NO;
  }
  // Compare the un-clipped metadata rectangle. Intersecting it with the
  // IOSurface first can change the aspect ratio when ScreenCaptureKit reports
  // a transient non-zero origin during a display-filter update.
  const CGFloat visibleAspect = contentRect.size.width / contentRect.size.height;
  const CGFloat targetAspect = (CGFloat)targetWidth / (CGFloat)targetHeight;
  return fabs((visibleAspect / targetAspect) - 1.0) <= 0.005;
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
  BOOL hasVisibleContentMetadata = NO;
  const CGRect visiblePixelRect = CDRVisibleContentPixelRect(
      attachments, pixelBuffer, &hasVisibleContentMetadata);
  const double bufferWidth = CVPixelBufferGetWidth(pixelBuffer);
  const double bufferHeight = CVPixelBufferGetHeight(pixelBuffer);
  return @{
    @"bufferWidth": @(bufferWidth),
    @"bufferHeight": @(bufferHeight),
    @"contentRectX": @(contentRect.origin.x),
    @"contentRectY": @(contentRect.origin.y),
    @"contentRectWidth": @(contentRect.size.width),
    @"contentRectHeight": @(contentRect.size.height),
    @"contentScale": contentScale ?: @0,
    @"scaleFactor": scaleFactor ?: @0,
    @"visiblePixelRectX": @(visiblePixelRect.origin.x),
    @"visiblePixelRectY": @(visiblePixelRect.origin.y),
    @"visiblePixelRectWidth": @(visiblePixelRect.size.width),
    @"visiblePixelRectHeight": @(visiblePixelRect.size.height),
    @"visibleWidthCoverage": @(bufferWidth > 0
        ? visiblePixelRect.size.width / bufferWidth
        : 0),
    @"visibleHeightCoverage": @(bufferHeight > 0
        ? visiblePixelRect.size.height / bufferHeight
        : 0),
    @"contentRectMetadataPresent": @(hasVisibleContentMetadata),
    @"contentFillsBuffer": @(
        CDRVisibleContentFillsBuffer(visiblePixelRect, pixelBuffer)),
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
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
  if (_lastActiveEncoderPixelBuffer != NULL) {
    CVPixelBufferRelease(_lastActiveEncoderPixelBuffer);
    _lastActiveEncoderPixelBuffer = NULL;
  }
  if (_retiredEncoderPixelBuffer != NULL) {
    CVPixelBufferRelease(_retiredEncoderPixelBuffer);
    _retiredEncoderPixelBuffer = NULL;
  }
#endif
}

#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
- (void)publishFrameGateStatus:(NSString *)status
               rejectionReason:(NSString *)rejectionReason
                   pixelBuffer:(CVPixelBufferRef _Nullable)pixelBuffer
                   attachments:(NSDictionary<SCStreamFrameInfo, id> * _Nullable)attachments
                         force:(BOOL)force API_AVAILABLE(macos(12.3)) {
  const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  const BOOL reasonChanged =
      ![self.lastFrameGateRejection isEqualToString:rejectionReason ?: @""];
  if (!force && !reasonChanged && now - self.lastFrameGateNotificationAt < 0.25) {
    return;
  }
  self.lastFrameGateRejection = rejectionReason ?: @"";
  self.lastFrameGateNotificationAt = now;
  NSMutableDictionary<NSString *, id> *state = [@{
    @"sourceId": self.sourceId ?: @"",
    @"captureGeneration": @(self.captureGeneration),
    @"gateStatus": status ?: @"waiting",
    @"rejectionReason": rejectionReason ?: @"",
    @"stableFrameCount": @(self.stableSwitchFrameCount),
    @"staleFrameCount": @(self.rejectedStaleFrameCount),
    @"wrongSizeCount": @(self.rejectedWrongSizeCount),
    @"missingContentMetadataCount": @(self.missingContentMetadataCount),
    @"contentAspectMismatchCount": @(self.contentAspectMismatchCount),
    @"normalizationFailureCount": @(self.normalizationFailureCount),
    @"gateElapsedMs": @(MAX(0, (now - self.switchFrameGateStartedAt) * 1000.0)),
  } mutableCopy];
  if (pixelBuffer != NULL) {
    [state addEntriesFromDictionary:CDRFrameGeometryDiagnostics(
        attachments ?: @{}, pixelBuffer)];
  }
  if (force || reasonChanged) {
    NSLog(@"CrossDesktopRemote capture frame gate: %@", state);
  }
  [[NSNotificationCenter defaultCenter]
      postNotificationName:@"CrossDesktopRemoteCaptureFrameGate"
                    object:nil
                  userInfo:state];
}

- (void)resetFrameGateForSourceId:(NSString *)sourceId API_AVAILABLE(macos(12.3)) {
  self.sourceId = sourceId ?: @"";
  self.switchFrameDisplayTimeBarrier = mach_absolute_time();
  self.switchFrameGateStartedAt = CFAbsoluteTimeGetCurrent();
  self.stableSwitchFrameCount = 0;
  self.rejectedStaleFrameCount = 0;
  self.rejectedWrongSizeCount = 0;
  self.missingContentMetadataCount = 0;
  self.contentAspectMismatchCount = 0;
  self.normalizationFailureCount = 0;
  self.lastFrameGateRejection = @"";
  self.lastFrameGateNotificationAt = 0;
  [self publishFrameGateStatus:@"waiting"
              rejectionReason:@""
                  pixelBuffer:NULL
                  attachments:nil
                        force:YES];
}

- (void)recordFrameGateRejection:(NSString *)reason
                     pixelBuffer:(CVPixelBufferRef)pixelBuffer
                     attachments:(NSDictionary<SCStreamFrameInfo, id> *)attachments
    API_AVAILABLE(macos(12.3)) {
  if ([reason isEqualToString:@"staleDisplayTime"]) {
    self.rejectedStaleFrameCount += 1;
  } else if ([reason isEqualToString:@"wrongBufferSize"]) {
    self.rejectedWrongSizeCount += 1;
  } else if ([reason isEqualToString:@"missingContentMetadata"]) {
    self.missingContentMetadataCount += 1;
  } else if ([reason isEqualToString:@"contentAspectMismatch"]) {
    self.contentAspectMismatchCount += 1;
  } else if ([reason isEqualToString:@"normalizationFailed"]) {
    self.normalizationFailureCount += 1;
  }
  [self publishFrameGateStatus:@"waiting"
              rejectionReason:reason
                  pixelBuffer:pixelBuffer
                  attachments:attachments
                        force:NO];
}

- (void)stopAndDetachStream:(SCStream *)stream
                 completion:(void (^ _Nullable)(void))completion
    API_AVAILABLE(macos(12.3)) {
  if (stream == nil) {
    if (completion != nil) completion();
    return;
  }
  NSError *removeError = nil;
  [stream removeStreamOutput:self
                        type:SCStreamOutputTypeScreen
                       error:&removeError];
  if (removeError != nil) {
    NSLog(@"CrossDesktopRemote remove stream output failed: %@", removeError);
  }
  [stream stopCaptureWithCompletionHandler:^(__unused NSError * _Nullable error) {
    if (error != nil) {
      NSLog(@"CrossDesktopRemote stop capture stream failed: %@", error);
    }
    if (completion != nil) completion();
  }];
}

- (void)failPendingSwitchGeneration:(NSUInteger)generation
                              error:(NSError *)error
    API_AVAILABLE(macos(12.3)) {
  if (self.pendingStream == nil || self.pendingGeneration != generation) {
    return;
  }
  SCStream *failedStream = self.pendingStream;
  CDRCaptureSwitchCompletion completion = self.pendingSwitchCompletion;
  NSMutableDictionary *diagnostics = [error.userInfo mutableCopy] ?: [NSMutableDictionary dictionary];
  NSString *summary = [NSString stringWithFormat:
      @"%@ (usable=%lu, accepted=%lu, stale=%lu, geometry=%lu, contentAspect=%lu, metadataFallback=%lu, last=%zux%zu, expected=%zux%zu)",
      error.localizedDescription,
      (unsigned long)self.pendingCompleteFrameCount,
      (unsigned long)self.pendingStableFrameCount,
      (unsigned long)self.pendingRejectedStaleFrameCount,
      (unsigned long)self.pendingRejectedGeometryFrameCount,
      (unsigned long)self.pendingContentAspectMismatchCount,
      (unsigned long)self.pendingMetadataFallbackCount,
      self.pendingLastFrameWidth,
      self.pendingLastFrameHeight,
      self.pendingExpectedFrameWidth,
      self.pendingExpectedFrameHeight];
  diagnostics[NSLocalizedDescriptionKey] = summary;
  diagnostics[@"pendingUsableFrames"] = @(self.pendingCompleteFrameCount);
  diagnostics[@"pendingCompleteFrames"] = @(self.pendingCompleteFrameCount);
  diagnostics[@"pendingStableFrames"] = @(self.pendingStableFrameCount);
  diagnostics[@"pendingRejectedStaleFrames"] = @(self.pendingRejectedStaleFrameCount);
  diagnostics[@"pendingRejectedGeometryFrames"] = @(self.pendingRejectedGeometryFrameCount);
  diagnostics[@"pendingMissingMetadataFrames"] = @(self.pendingMissingMetadataFrameCount);
  diagnostics[@"pendingContentAspectMismatchFrames"] =
      @(self.pendingContentAspectMismatchCount);
  diagnostics[@"pendingMetadataFallbackFrames"] =
      @(self.pendingMetadataFallbackCount);
  diagnostics[@"pendingLastWidth"] = @(self.pendingLastFrameWidth);
  diagnostics[@"pendingLastHeight"] = @(self.pendingLastFrameHeight);
  diagnostics[@"pendingExpectedWidth"] = @(self.pendingExpectedFrameWidth);
  diagnostics[@"pendingExpectedHeight"] = @(self.pendingExpectedFrameHeight);
  diagnostics[@"pendingElapsedMs"] = @(
      MAX(0, (CFAbsoluteTimeGetCurrent() - self.pendingStartedAt) * 1000.0));
  NSError *diagnosticError = [NSError errorWithDomain:error.domain
                                                  code:error.code
                                              userInfo:diagnostics];
  NSLog(@"CrossDesktopRemote pending capture generation %lu failed: %@",
        (unsigned long)generation,
        diagnostics);
  self.pendingStream = nil;
  self.pendingSourceId = nil;
  self.pendingSwitchCompletion = nil;
  self.pendingStableFrameCount = 0;
  self.pendingExpectedFrameWidth = 0;
  self.pendingExpectedFrameHeight = 0;
  self.pendingFrameRate = 0;
  self.pendingCompleteFrameCount = 0;
  self.pendingRejectedStaleFrameCount = 0;
  self.pendingRejectedGeometryFrameCount = 0;
  self.pendingMissingMetadataFrameCount = 0;
  self.pendingContentAspectMismatchCount = 0;
  self.pendingMetadataFallbackCount = 0;
  self.pendingLastFrameWidth = 0;
  self.pendingLastFrameHeight = 0;
  self.pendingStartedAt = 0;
  dispatch_async(self.captureQueue, ^{
    [self stopAndDetachStream:failedStream completion:^{
      if (completion != nil) completion(nil, diagnosticError);
    }];
  });
}

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
    // The output dimensions are derived from this display's own contentRect,
    // so full-display capture can safely fill the destination surface. Keeping
    // aspect preservation enabled across a Sidecar -> main-display update can
    // leave the old inset destination transform active in WindowServer.
    config.preservesAspectRatio = NO;
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
        [self resetFrameGateForSourceId:self.sourceId];
        self.expectedFrameWidth = config.width;
        self.expectedFrameHeight = config.height;
        self.expectedFrameRate = MAX((NSInteger)1, fps);
      });

      self.stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
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
                   onCompletion:(void (^)(NSDictionary<NSString *, id> * _Nullable configuration,
                                          NSError * _Nullable error))onCompletion {
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
  if (@available(macOS 13.0, *)) {
    dispatch_async(self.captureQueue, ^{
      if (self.stream == nil) {
        NSError *notRunning = [NSError errorWithDomain:@"FlutterScreenCaptureKit"
                                                   code:-3
                                               userInfo:@{
                                                 NSLocalizedDescriptionKey:
                                                     @"ScreenCaptureKit stream is not running"
                                               }];
        onCompletion(nil, notRunning);
        return;
      }
      if (self.pendingStream != nil || self.retiredStream != nil) {
        NSError *busy = [NSError errorWithDomain:@"FlutterScreenCaptureKit"
                                             code:-4
                                         userInfo:@{
                                           NSLocalizedDescriptionKey:
                                               @"A capture switch transaction is already active"
                                         }];
        onCompletion(nil, busy);
        return;
      }
      if (self.captureFormatUpdateInProgress) {
        NSError *busy = [NSError errorWithDomain:@"FlutterScreenCaptureKit"
                                             code:-10
                                         userInfo:@{
                                           NSLocalizedDescriptionKey:
                                               @"Capture format update is still in progress"
                                         }];
        onCompletion(nil, busy);
        return;
      }
      self.captureGeneration += 1;
      const NSUInteger generation = self.captureGeneration;
      [SCShareableContent
          getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
          if (error != nil) {
            onCompletion(nil, error);
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
            onCompletion(nil, noDisplay);
            return;
          }
          SCContentFilter *filter =
              [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
          SCStreamConfiguration *configuration =
              [self streamConfigurationForDisplay:display
                                           filter:filter
                                              fps:fps
                                   targetLongEdge:targetLongEdge];
          dispatch_async(self.captureQueue, ^{
            if (generation != self.captureGeneration ||
                self.pendingStream != nil || self.retiredStream != nil) {
              NSError *superseded = [NSError errorWithDomain:@"FlutterScreenCaptureKit"
                                                         code:-5
                                                     userInfo:@{
                                                       NSLocalizedDescriptionKey:
                                                           @"Capture switch was superseded"
                                                     }];
              onCompletion(nil, superseded);
              return;
            }

            // ScreenCaptureKit dynamic source updates can acknowledge success
            // while WindowServer keeps emitting the previous Sidecar surface.
            // A fresh stream binds the target display at construction time.
            SCStream *candidate = [[SCStream alloc] initWithFilter:filter
                                                     configuration:configuration
                                                          delegate:self];
            NSError *addOutputError = nil;
            [candidate addStreamOutput:self
                                  type:SCStreamOutputTypeScreen
                   sampleHandlerQueue:self.captureQueue
                                error:&addOutputError];
            if (addOutputError != nil) {
              onCompletion(nil, addOutputError);
              return;
            }

            self.pendingStream = candidate;
            self.pendingSourceId = sourceId;
            self.pendingGeneration = generation;
            self.pendingExpectedFrameWidth = configuration.width;
            self.pendingExpectedFrameHeight = configuration.height;
            self.pendingFrameRate = MAX((NSInteger)1, fps);
            self.pendingStableFrameCount = 0;
            self.pendingCompleteFrameCount = 0;
            self.pendingRejectedStaleFrameCount = 0;
            self.pendingRejectedGeometryFrameCount = 0;
            self.pendingMissingMetadataFrameCount = 0;
            self.pendingContentAspectMismatchCount = 0;
            self.pendingMetadataFallbackCount = 0;
            self.pendingLastFrameWidth = 0;
            self.pendingLastFrameHeight = 0;
            self.pendingStartedAt = CFAbsoluteTimeGetCurrent();
            self.pendingDisplayTimeBarrier = mach_absolute_time();
            self.pendingSwitchCompletion = onCompletion;

            [candidate startCaptureWithCompletionHandler:^(NSError * _Nullable startError) {
              if (startError != nil) {
                dispatch_async(self.captureQueue, ^{
                  [self failPendingSwitchGeneration:generation error:startError];
                });
                return;
              }
              dispatch_after(
                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                  self.captureQueue,
                  ^{
                    if (self.pendingStream == candidate &&
                        self.pendingGeneration == generation) {
                      NSError *timeout = [NSError
                          errorWithDomain:@"FlutterScreenCaptureKit"
                                     code:-6
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                       @"Target display stream did not produce a usable frame"
                                 }];
                      [self failPendingSwitchGeneration:generation error:timeout];
                    }
                  });
            }];
          });
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
  onCompletion(nil, unavailable);
}

- (void)commitCaptureSwitchGeneration:(NSUInteger)generation
                          onCompletion:(void (^)(NSError * _Nullable error))onCompletion {
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
  if (@available(macOS 13.0, *)) {
    dispatch_async(self.captureQueue, ^{
      if (generation != self.captureGeneration) {
        NSError *stale = [NSError errorWithDomain:@"FlutterScreenCaptureKit"
                                              code:-7
                                          userInfo:@{
                                            NSLocalizedDescriptionKey:
                                                @"Capture switch generation is stale"
                                          }];
        onCompletion(stale);
        return;
      }
      SCStream *retired = self.retiredStream;
      self.retiredStream = nil;
      self.retiredSourceId = nil;
      self.retiredExpectedFrameWidth = 0;
      self.retiredExpectedFrameHeight = 0;
      self.retiredFrameRate = 0;
      self.retiredActiveContentRect = CGRectZero;
      if (self.retiredEncoderPixelBuffer != NULL) {
        CVPixelBufferRelease(self.retiredEncoderPixelBuffer);
        self.retiredEncoderPixelBuffer = NULL;
      }
      if (retired == nil) {
        onCompletion(nil);
        return;
      }
      [self stopAndDetachStream:retired completion:^{
        onCompletion(nil);
      }];
    });
    return;
  }
#endif
  NSError *unavailable = [NSError errorWithDomain:@"FlutterScreenCaptureKit"
                                              code:-2
                                          userInfo:@{
                                            NSLocalizedDescriptionKey:
                                                @"Capture switch commit is unavailable"
                                          }];
  onCompletion(unavailable);
}

- (void)rollbackCaptureSwitchGeneration:(NSUInteger)generation
                            onCompletion:(void (^)(NSDictionary<NSString *, id> * _Nullable configuration,
                                                   NSError * _Nullable error))onCompletion {
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
  if (@available(macOS 13.0, *)) {
    dispatch_async(self.captureQueue, ^{
      if (generation != self.captureGeneration || self.retiredStream == nil) {
        NSError *stale = [NSError errorWithDomain:@"FlutterScreenCaptureKit"
                                              code:-8
                                          userInfo:@{
                                            NSLocalizedDescriptionKey:
                                                @"No rollback stream exists for this generation"
                                          }];
        onCompletion(nil, stale);
        return;
      }

      SCStream *failedTarget = self.stream;
      self.stream = self.retiredStream;
      self.sourceId = self.retiredSourceId ?: @"";
      self.expectedFrameWidth = self.retiredExpectedFrameWidth;
      self.expectedFrameHeight = self.retiredExpectedFrameHeight;
      self.expectedFrameRate = MAX((NSInteger)1, self.retiredFrameRate);
      self.retiredStream = nil;
      self.retiredSourceId = nil;
      self.retiredExpectedFrameWidth = 0;
      self.retiredExpectedFrameHeight = 0;
      self.retiredFrameRate = 0;
      if (self.lastActiveEncoderPixelBuffer != NULL) {
        CVPixelBufferRelease(self.lastActiveEncoderPixelBuffer);
      }
      self.lastActiveEncoderPixelBuffer = self.retiredEncoderPixelBuffer;
      self.retiredEncoderPixelBuffer = NULL;
      self.lastActiveContentRect = self.retiredActiveContentRect;
      self.retiredActiveContentRect = CGRectZero;
      self.captureGeneration += 1;
      const NSUInteger rollbackGeneration = self.captureGeneration;
      self.emittedFirstFrame = NO;
      self.emittedColorDiagnostics = NO;
      self.freshCanvasFrameCount = 1;
      self.awaitingStableSwitchFrames = NO;
      [self resetFrameGateForSourceId:self.sourceId];
      self.awaitingStableSwitchFrames = NO;
      [(VideoProcessingAdapter *)self.delegate
          prepareOutputFormatWithWidth:self.expectedFrameWidth
                               height:self.expectedFrameHeight
                                  fps:self.expectedFrameRate];
      NSDictionary<NSString *, id> *restored = @{
        @"result": @YES,
        @"sourceId": self.sourceId ?: @"",
        @"captureGeneration": @(rollbackGeneration),
        @"width": @(self.expectedFrameWidth),
        @"height": @(self.expectedFrameHeight),
        @"frameRate": @(self.expectedFrameRate),
      };
      if (self.lastActiveEncoderPixelBuffer != NULL) {
        id<RTCVideoFrameBuffer> cachedBuffer = [[RTCCVPixelBuffer alloc]
            initWithPixelBuffer:self.lastActiveEncoderPixelBuffer];
        const int64_t timestampNs = (int64_t)(CMTimeGetSeconds(
            CMClockGetTime(CMClockGetHostTimeClock())) * 1000000000.0);
        RTCVideoFrame *cachedFrame = [[RTCVideoFrame alloc]
            initWithBuffer:cachedBuffer
                  rotation:RTCVideoRotation_0
               timeStampNs:timestampNs];
        [self.delegate capturer:self.capturer didCaptureVideoFrame:cachedFrame];
        self.emittedFirstFrame = YES;
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"CrossDesktopRemoteCaptureFirstFrame"
                          object:nil
                        userInfo:@{
                          @"sourceId": self.sourceId ?: @"",
                          @"width": @(CVPixelBufferGetWidth(
                              self.lastActiveEncoderPixelBuffer)),
                          @"height": @(CVPixelBufferGetHeight(
                              self.lastActiveEncoderPixelBuffer)),
                          @"activeContentX": @(self.lastActiveContentRect.origin.x),
                          @"activeContentY": @(self.lastActiveContentRect.origin.y),
                          @"activeContentWidth": @(self.lastActiveContentRect.size.width),
                          @"activeContentHeight": @(self.lastActiveContentRect.size.height),
                          @"captureGeneration": @(rollbackGeneration),
                          @"visibleWidthCoverage": @(
                              self.lastActiveContentRect.size.width /
                              MAX((CGFloat)1, (CGFloat)CVPixelBufferGetWidth(
                                  self.lastActiveEncoderPixelBuffer))),
                          @"visibleHeightCoverage": @(
                              self.lastActiveContentRect.size.height /
                              MAX((CGFloat)1, (CGFloat)CVPixelBufferGetHeight(
                                  self.lastActiveEncoderPixelBuffer))),
                          @"contentNormalized": @NO,
                        }];
      }
      [self stopAndDetachStream:failedTarget completion:^{
        onCompletion(restored, nil);
      }];
    });
    return;
  }
#endif
  NSError *unavailable = [NSError errorWithDomain:@"FlutterScreenCaptureKit"
                                              code:-2
                                          userInfo:@{
                                            NSLocalizedDescriptionKey:
                                                @"Capture switch rollback is unavailable"
                                          }];
  onCompletion(nil, unavailable);
}

- (void)updateCaptureWithFPS:(NSInteger)fps
              targetLongEdge:(NSInteger)targetLongEdge
                onCompletion:(void (^)(NSDictionary<NSString *, id> * _Nullable configuration,
                                       NSError * _Nullable error))onCompletion {
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
  if (@available(macOS 13.0, *)) {
    dispatch_async(self.captureQueue, ^{
      SCStream *stream = self.stream;
      NSString *sourceId = [self.sourceId copy] ?: @"";
      const NSUInteger captureGeneration = self.captureGeneration;
      if (stream == nil) {
        NSError *notRunning = [NSError errorWithDomain:@"FlutterScreenCaptureKit"
                                                   code:-3
                                               userInfo:@{
                                                 NSLocalizedDescriptionKey:
                                                     @"ScreenCaptureKit stream is not running"
                                               }];
        onCompletion(nil, notRunning);
        return;
      }
      if (self.pendingStream != nil || self.retiredStream != nil ||
          self.captureFormatUpdateInProgress) {
        NSError *busy = [NSError errorWithDomain:@"FlutterScreenCaptureKit"
                                             code:-10
                                         userInfo:@{
                                           NSLocalizedDescriptionKey:
                                               @"Capture transaction is busy"
                                         }];
        onCompletion(nil, busy);
        return;
      }
      self.captureFormatUpdateInProgress = YES;
      self.captureFormatEpoch += 1;
      const NSUInteger formatEpoch = self.captureFormatEpoch;

      void (^finishWithError)(NSError *) = ^(NSError *error) {
        dispatch_async(self.captureQueue, ^{
          if (formatEpoch == self.captureFormatEpoch) {
            self.captureFormatUpdateInProgress = NO;
          }
          onCompletion(nil, error);
        });
      };
      [SCShareableContent
          getShareableContentWithCompletionHandler:^(SCShareableContent *content,
                                                      NSError *error) {
            if (error != nil) {
              finishWithError(error);
              return;
            }
            dispatch_async(self.captureQueue, ^{
              const BOOL stillCurrent =
                  formatEpoch == self.captureFormatEpoch &&
                  self.captureFormatUpdateInProgress &&
                  stream == self.stream &&
                  captureGeneration == self.captureGeneration &&
                  [sourceId isEqualToString:self.sourceId ?: @""] &&
                  self.pendingStream == nil && self.retiredStream == nil;
              if (!stillCurrent) {
                NSError *stale = [NSError errorWithDomain:@"FlutterScreenCaptureKit"
                                                       code:-11
                                                   userInfo:@{
                                                     NSLocalizedDescriptionKey:
                                                         @"Capture format update was superseded"
                                                   }];
                self.captureFormatUpdateInProgress = NO;
                onCompletion(nil, stale);
                return;
              }
              SCDisplay *display = [self selectDisplayFromContent:content
                                                         sourceId:sourceId];
              if (display == nil) {
                NSError *noDisplay = [NSError errorWithDomain:@"FlutterScreenCaptureKit"
                                                          code:-1
                                                      userInfo:@{
                                                        NSLocalizedDescriptionKey:
                                                            @"No matching display"
                                                      }];
                self.captureFormatUpdateInProgress = NO;
                onCompletion(nil, noDisplay);
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
                           const BOOL callbackIsCurrent =
                               formatEpoch == self.captureFormatEpoch &&
                               self.captureFormatUpdateInProgress &&
                               stream == self.stream &&
                               captureGeneration == self.captureGeneration &&
                               [sourceId isEqualToString:self.sourceId ?: @""];
                           if (!callbackIsCurrent) {
                             NSError *stale = [NSError errorWithDomain:@"FlutterScreenCaptureKit"
                                                                    code:-11
                                                                userInfo:@{
                                                                  NSLocalizedDescriptionKey:
                                                                      @"Stale capture format callback ignored"
                                                                }];
                             self.captureFormatUpdateInProgress = NO;
                             onCompletion(nil, stale);
                             return;
                           }
                           self.captureFormatUpdateInProgress = NO;
                           if (configurationError != nil) {
                             onCompletion(nil, configurationError);
                             return;
                           }
                           [self resetFrameGateForSourceId:sourceId];
                           self.expectedFrameWidth = configuration.width;
                           self.expectedFrameHeight = configuration.height;
                           self.expectedFrameRate = MAX((NSInteger)1, fps);
                           self.freshCanvasFrameCount = 1;
                           self.awaitingStableSwitchFrames = YES;
                           self.emittedFirstFrame = NO;
                           self.emittedColorDiagnostics = NO;
                           [(VideoProcessingAdapter *)self.delegate
                               prepareOutputFormatWithWidth:configuration.width
                                                    height:configuration.height
                                                       fps:fps];
                           onCompletion(@{
                             @"result": @YES,
                             @"sourceId": sourceId,
                             @"captureGeneration": @(captureGeneration),
                             @"width": @(configuration.width),
                             @"height": @(configuration.height),
                             @"frameRate": @(MAX(1, fps)),
                           }, nil);
                         });
                       }];
            });
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
  onCompletion(nil, unavailable);
}

- (void)stopCaptureWithCompletion:(void (^)(void))completion {
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
  if (@available(macOS 12.3, *)) {
    dispatch_async(self.captureQueue, ^{
      NSMutableArray<SCStream *> *streams = [NSMutableArray array];
      if (self.stream != nil) [streams addObject:self.stream];
      if (self.pendingStream != nil) [streams addObject:self.pendingStream];
      if (self.retiredStream != nil) [streams addObject:self.retiredStream];
      CDRCaptureSwitchCompletion pendingCompletion = self.pendingSwitchCompletion;
      self.stream = nil;
      self.pendingStream = nil;
      self.retiredStream = nil;
      self.pendingSwitchCompletion = nil;
      self.pendingSourceId = nil;
      self.retiredSourceId = nil;
      self.captureFormatEpoch += 1;
      self.captureFormatUpdateInProgress = NO;
      if (self.lastActiveEncoderPixelBuffer != NULL) {
        CVPixelBufferRelease(self.lastActiveEncoderPixelBuffer);
        self.lastActiveEncoderPixelBuffer = NULL;
      }
      if (self.retiredEncoderPixelBuffer != NULL) {
        CVPixelBufferRelease(self.retiredEncoderPixelBuffer);
        self.retiredEncoderPixelBuffer = NULL;
      }
      NSMutableArray<SCStream *> *uniqueStreams = [NSMutableArray array];
      for (SCStream *stream in streams) {
        if ([uniqueStreams containsObject:stream]) continue;
        [uniqueStreams addObject:stream];
      }
      if (pendingCompletion != nil) {
        NSError *cancelled = [NSError errorWithDomain:@"FlutterScreenCaptureKit"
                                                  code:-9
                                              userInfo:@{
                                                NSLocalizedDescriptionKey:
                                                    @"Capture stopped during display switch"
                                              }];
        pendingCompletion(nil, cancelled);
      }
      if (uniqueStreams.count == 0) {
        completion();
        return;
      }
      dispatch_group_t group = dispatch_group_create();
      for (SCStream *stream in uniqueStreams) {
        dispatch_group_enter(group);
        [self stopAndDetachStream:stream completion:^{
          dispatch_group_leave(group);
        }];
      }
      dispatch_group_notify(group, self.captureQueue, completion);
    });
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

- (CVPixelBufferRef)newNormalizedSDRPixelBufferFromPixelBuffer:(CVPixelBufferRef)source
                                             visiblePixelRect:(CGRect)visiblePixelRect
                                                  outputWidth:(size_t)outputWidth
                                                 outputHeight:(size_t)outputHeight
                                            activeContentRect:(CGRect * _Nullable)activeContentRect {
  const size_t sourceWidth = CVPixelBufferGetWidth(source);
  const size_t sourceHeight = CVPixelBufferGetHeight(source);
  const size_t width = outputWidth > 0 ? outputWidth : sourceWidth;
  const size_t height = outputHeight > 0 ? outputHeight : sourceHeight;
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
  CGRect cropRect = CGRectIntersection(
      CGRectMake(visiblePixelRect.origin.x,
                 sourceHeight - CGRectGetMaxY(visiblePixelRect),
                 visiblePixelRect.size.width,
                 visiblePixelRect.size.height),
      image.extent);
  if (CGRectIsNull(cropRect) || CGRectIsEmpty(cropRect)) {
    CVPixelBufferRelease(output);
    return NULL;
  }
  image = [image imageByCroppingToRect:cropRect];
  CGRect croppedExtent = image.extent;
  if (croppedExtent.origin.x != 0 || croppedExtent.origin.y != 0) {
    image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(
        -croppedExtent.origin.x, -croppedExtent.origin.y)];
    croppedExtent = image.extent;
  }
  if (croppedExtent.size.width <= 0 || croppedExtent.size.height <= 0) {
    CVPixelBufferRelease(output);
    return NULL;
  }
  // Geometry-v2 controllers render and map input from the exact same active
  // rectangle. Preserve the complete Sidecar surface inside the stable
  // encoder canvas; legacy Apple controllers retain the prior fill behavior.
  const CGFloat scale = self.preserveVisibleContentGeometry
      ? MIN((CGFloat)width / croppedExtent.size.width,
            (CGFloat)height / croppedExtent.size.height)
      : MAX((CGFloat)width / croppedExtent.size.width,
            (CGFloat)height / croppedExtent.size.height);
  const CGFloat scaledWidth = croppedExtent.size.width * scale;
  const CGFloat scaledHeight = croppedExtent.size.height * scale;
  const CGFloat destinationX = ((CGFloat)width - scaledWidth) / 2.0;
  const CGFloat destinationY = ((CGFloat)height - scaledHeight) / 2.0;
  if (activeContentRect != NULL) {
    *activeContentRect = self.preserveVisibleContentGeometry
        ? CGRectIntersection(
              CGRectMake(destinationX,
                         destinationY,
                         scaledWidth,
                         scaledHeight),
              CGRectMake(0, 0, width, height))
        : CGRectMake(0, 0, width, height);
  }
  image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
  image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(
      destinationX, destinationY)];
  CIImage *background = [[CIImage imageWithColor:
      [CIColor colorWithRed:0 green:0 blue:0 alpha:1]]
      imageByCroppingToRect:CGRectMake(0, 0, width, height)];
  image = [image imageByCompositingOverImage:background];
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
    didStopWithError:(NSError *)error API_AVAILABLE(macos(12.3)) {
  dispatch_async(self.captureQueue, ^{
    if (stream == self.pendingStream) {
      [self failPendingSwitchGeneration:self.pendingGeneration error:error];
      return;
    }
    if (stream == self.stream) {
      NSLog(@"CrossDesktopRemote active capture stream stopped: %@", error);
    }
  });
}

- (void)stream:(SCStream *)stream
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
        ofType:(SCStreamOutputType)type API_AVAILABLE(macos(12.3)) {
  if (type != SCStreamOutputTypeScreen) {
    return;
  }

  NSDictionary<SCStreamFrameInfo, id> *frameAttachments = nil;
  if (!CDRFrameIsUsable(sampleBuffer, &frameAttachments)) {
    return;
  }

  CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  if (pixelBuffer == nil) {
    return;
  }

  if (stream == self.pendingStream) {
    const NSUInteger generation = self.pendingGeneration;
    const size_t width = CVPixelBufferGetWidth(pixelBuffer);
    const size_t height = CVPixelBufferGetHeight(pixelBuffer);
    self.pendingCompleteFrameCount += 1;
    self.pendingLastFrameWidth = width;
    self.pendingLastFrameHeight = height;
    NSNumber *displayTime = frameAttachments[SCStreamFrameInfoDisplayTime];
    if ([displayTime isKindOfClass:[NSNumber class]] &&
        displayTime.unsignedLongLongValue <= self.pendingDisplayTimeBarrier) {
      self.pendingRejectedStaleFrameCount += 1;
      return;
    }
    BOOL pendingHasVisibleMetadata = NO;
    (void)CDRVisibleContentPixelRect(
        frameAttachments, pixelBuffer, &pendingHasVisibleMetadata);
    if (!pendingHasVisibleMetadata) {
      self.pendingMissingMetadataFrameCount += 1;
    }
    const BOOL bufferGeometryMatches = CDRBufferDimensionsMatch(
        width,
        height,
        self.pendingExpectedFrameWidth,
        self.pendingExpectedFrameHeight);
    if (!bufferGeometryMatches) {
      self.pendingRejectedGeometryFrameCount += 1;
      self.pendingStableFrameCount = 0;
      return;
    }
    const BOOL pendingContentAspectMatches = pendingHasVisibleMetadata &&
        CDRVisibleContentMatchesTargetAspect(
            frameAttachments,
            self.pendingExpectedFrameWidth,
            self.pendingExpectedFrameHeight);
    if (!pendingHasVisibleMetadata || !pendingContentAspectMatches) {
      if (pendingHasVisibleMetadata) {
        self.pendingContentAspectMismatchCount += 1;
      }
      // contentRect is advisory crop/scale metadata. Sidecar can omit it or
      // briefly report the previous surface even when this target-bound stream
      // already owns a valid pixel buffer. Fall back to the full canonical
      // buffer immediately instead of waiting for another frame which a static
      // desktop might never emit.
      self.pendingMetadataFallbackCount += 1;
    }
    self.pendingStableFrameCount = 1;

    // The stream object, capture generation, post-start display time and exact
    // destination dimensions identify the target transaction. Promote its
    // first usable pixel buffer; the previous stream remains warm until the
    // controller confirms that new media arrived.
    self.retiredStream = self.stream;
    self.retiredSourceId = self.sourceId ?: @"";
    self.retiredExpectedFrameWidth = self.expectedFrameWidth;
    self.retiredExpectedFrameHeight = self.expectedFrameHeight;
    self.retiredFrameRate = MAX((NSInteger)1, self.expectedFrameRate);
    if (self.retiredEncoderPixelBuffer != NULL) {
      CVPixelBufferRelease(self.retiredEncoderPixelBuffer);
    }
    self.retiredEncoderPixelBuffer = self.lastActiveEncoderPixelBuffer;
    self.retiredActiveContentRect = self.lastActiveContentRect;
    self.lastActiveEncoderPixelBuffer = NULL;
    self.lastActiveContentRect = CGRectZero;
    self.stream = stream;
    self.sourceId = self.pendingSourceId ?: @"";
    self.expectedFrameWidth = self.pendingExpectedFrameWidth;
    self.expectedFrameHeight = self.pendingExpectedFrameHeight;
    self.expectedFrameRate = MAX((NSInteger)1, self.pendingFrameRate);
    CDRCaptureSwitchCompletion completion = self.pendingSwitchCompletion;
    self.pendingStream = nil;
    self.pendingSourceId = nil;
    self.pendingSwitchCompletion = nil;
    const NSUInteger acceptedCompleteFrames = self.pendingCompleteFrameCount;
    const NSUInteger acceptedGeometryRejects = self.pendingRejectedGeometryFrameCount;
    const NSUInteger acceptedContentAspectMismatches =
        self.pendingContentAspectMismatchCount;
    const NSUInteger acceptedMetadataFallbacks =
        self.pendingMetadataFallbackCount;
    self.pendingStableFrameCount = 0;
    self.pendingExpectedFrameWidth = 0;
    self.pendingExpectedFrameHeight = 0;
    self.pendingFrameRate = 0;
    self.pendingCompleteFrameCount = 0;
    self.pendingRejectedStaleFrameCount = 0;
    self.pendingRejectedGeometryFrameCount = 0;
    self.pendingMissingMetadataFrameCount = 0;
    self.pendingContentAspectMismatchCount = 0;
    self.pendingMetadataFallbackCount = 0;
    self.pendingLastFrameWidth = 0;
    self.pendingLastFrameHeight = 0;
    self.pendingStartedAt = 0;
    self.emittedFirstFrame = NO;
    self.emittedColorDiagnostics = NO;
    self.freshCanvasFrameCount = 2;
    self.awaitingStableSwitchFrames = NO;
    [self resetFrameGateForSourceId:self.sourceId];
    self.awaitingStableSwitchFrames = NO;
    [(VideoProcessingAdapter *)self.delegate
        prepareOutputFormatWithWidth:self.expectedFrameWidth
                             height:self.expectedFrameHeight
                                fps:self.expectedFrameRate];
    NSDictionary<NSString *, id> *configuration = @{
      @"result": @YES,
      @"sourceId": self.sourceId ?: @"",
      @"captureGeneration": @(generation),
      @"width": @(self.expectedFrameWidth),
      @"height": @(self.expectedFrameHeight),
      @"frameRate": @(self.expectedFrameRate),
    };
    NSLog(@"CrossDesktopRemote promoted capture generation %lu for source %@ (%zux%zu), usable=%lu geometryRejects=%lu contentAspect=%lu metadataFallback=%lu",
          (unsigned long)generation,
          self.sourceId,
          self.expectedFrameWidth,
          self.expectedFrameHeight,
          (unsigned long)acceptedCompleteFrames,
          (unsigned long)acceptedGeometryRejects,
          (unsigned long)acceptedContentAspectMismatches,
          (unsigned long)acceptedMetadataFallbacks);
    if (completion != nil) {
      completion(configuration, nil);
    }
  } else if (stream != self.stream) {
    // Retired streams remain warm for rollback but must never reach WebRTC.
    return;
  }

  BOOL hasVisibleContentMetadata = NO;
  const CGRect visiblePixelRect = CDRVisibleContentPixelRect(
      frameAttachments, pixelBuffer, &hasVisibleContentMetadata);
  const BOOL contentAspectMatches = CDRVisibleContentMatchesTargetAspect(
      frameAttachments,
      self.expectedFrameWidth,
      self.expectedFrameHeight);
  BOOL frameGateBecameReady = NO;

  if (self.awaitingStableSwitchFrames) {
    const size_t width = CVPixelBufferGetWidth(pixelBuffer);
    const size_t height = CVPixelBufferGetHeight(pixelBuffer);
    NSNumber *displayTime = frameAttachments[SCStreamFrameInfoDisplayTime];
    if ([displayTime isKindOfClass:[NSNumber class]] &&
        displayTime.unsignedLongLongValue <= self.switchFrameDisplayTimeBarrier) {
      self.stableSwitchFrameCount = 0;
      [self recordFrameGateRejection:@"staleDisplayTime"
                         pixelBuffer:pixelBuffer
                         attachments:frameAttachments];
      return;
    }
    if (self.expectedFrameWidth > 0 && self.expectedFrameHeight > 0 &&
        !CDRBufferDimensionsMatch(
            width,
            height,
            self.expectedFrameWidth,
            self.expectedFrameHeight)) {
      self.stableSwitchFrameCount = 0;
      [self recordFrameGateRejection:@"wrongBufferSize"
                         pixelBuffer:pixelBuffer
                         attachments:frameAttachments];
      return;
    }
    if (!hasVisibleContentMetadata) {
      [self recordFrameGateRejection:@"missingContentMetadata"
                         pixelBuffer:pixelBuffer
                         attachments:frameAttachments];
    } else if (!contentAspectMatches) {
      [self recordFrameGateRejection:@"contentAspectMismatch"
                         pixelBuffer:pixelBuffer
                         attachments:frameAttachments];
    }
    self.stableSwitchFrameCount = 1;
    self.awaitingStableSwitchFrames = NO;
    frameGateBecameReady = YES;
    NSLog(@"CrossDesktopRemote accepted display generation %lu after its first usable frame (%zux%zu), metadata=%@",
          (unsigned long)self.captureGeneration,
          width,
          height,
          frameAttachments);
  }

  // contentRect can temporarily describe an old or differently transformed
  // surface after a Sidecar switch. Do not drop an otherwise valid target-bound
  // frame, and do not crop with metadata that disagrees with the selected
  // display. The canonical output buffer is the safe fallback coordinate
  // space.
  if (hasVisibleContentMetadata && !contentAspectMatches) {
    if (!frameGateBecameReady) {
      // The bounded gate already reported its mismatch before becoming ready.
      // Outside a gate this remains a diagnostic counter only; publishing a
      // waiting/ready notification for every frame would create control-plane
      // churn while the canonical-buffer fallback is working normally.
      self.contentAspectMismatchCount += 1;
    }
  }
  // contentRect describes the pixels that belong to the selected display.
  // Its validity is independent from the encoder target aspect: automatic
  // quality scaling and codec alignment may legitimately make those aspects
  // differ by a few pixels. Ignoring a valid inset here encodes ScreenCaptureKit
  // padding and makes Sidecar appear top-aligned on the controller.
  const BOOL hasTrustedVisibleContentMetadata =
      hasVisibleContentMetadata &&
      (contentAspectMatches || self.preserveVisibleContentGeometry);
  const CGRect normalizationVisiblePixelRect =
      hasTrustedVisibleContentMetadata
      ? visiblePixelRect
      : CGRectMake(0,
                   0,
                   CVPixelBufferGetWidth(pixelBuffer),
                   CVPixelBufferGetHeight(pixelBuffer));

  const BOOL needsFreshCanvas = self.freshCanvasFrameCount > 0;
  if (needsFreshCanvas) {
    self.freshCanvasFrameCount -= 1;
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
  const BOOL needsContentNormalization =
      hasTrustedVisibleContentMetadata &&
      !CDRVisibleContentFillsBuffer(visiblePixelRect, pixelBuffer);
  const BOOL needsCanonicalGeometry =
      self.expectedFrameWidth > 0 && self.expectedFrameHeight > 0 &&
      (CVPixelBufferGetWidth(pixelBuffer) != self.expectedFrameWidth ||
       CVPixelBufferGetHeight(pixelBuffer) != self.expectedFrameHeight);
  const CFAbsoluteTime normalizationStartedAt = CFAbsoluteTimeGetCurrent();
  CGRect normalizedActiveContentRect = CGRectMake(
      0, 0, self.expectedFrameWidth, self.expectedFrameHeight);
  CVPixelBufferRef normalizedPixelBuffer =
      (needsNormalization || needsFreshCanvas || needsContentNormalization ||
       needsCanonicalGeometry)
      ? [self newNormalizedSDRPixelBufferFromPixelBuffer:pixelBuffer
                                         visiblePixelRect:normalizationVisiblePixelRect
                                              outputWidth:self.expectedFrameWidth
                                             outputHeight:self.expectedFrameHeight
                                        activeContentRect:&normalizedActiveContentRect]
      : NULL;
  if ((needsContentNormalization || needsCanonicalGeometry) &&
      normalizedPixelBuffer == NULL) {
    [self recordFrameGateRejection:@"normalizationFailed"
                       pixelBuffer:pixelBuffer
                       attachments:frameAttachments];
    return;
  }
  const double normalizationDurationMs =
      (CFAbsoluteTimeGetCurrent() - normalizationStartedAt) * 1000.0;
  CVPixelBufferRef encoderPixelBuffer = normalizedPixelBuffer ?: pixelBuffer;
  const CGRect encoderActiveContentRect = normalizedPixelBuffer != NULL
      ? normalizedActiveContentRect
      : CGRectMake(0,
                   0,
                   CVPixelBufferGetWidth(encoderPixelBuffer),
                   CVPixelBufferGetHeight(encoderPixelBuffer));

  if (frameGateBecameReady || self.lastFrameGateRejection.length > 0) {
    [self publishFrameGateStatus:@"ready"
                rejectionReason:@""
                    pixelBuffer:pixelBuffer
                    attachments:frameAttachments
                          force:YES];
  }

  if (!self.emittedFirstFrame) {
    self.emittedFirstFrame = YES;
    const double widthCoverage = (double)visiblePixelRect.size.width /
        MAX((double)1, (double)CVPixelBufferGetWidth(pixelBuffer));
    const double heightCoverage = (double)visiblePixelRect.size.height /
        MAX((double)1, (double)CVPixelBufferGetHeight(pixelBuffer));
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"CrossDesktopRemoteCaptureFirstFrame"
                      object:nil
                    userInfo:@{
                      @"sourceId": self.sourceId ?: @"",
                      @"width": @(CVPixelBufferGetWidth(encoderPixelBuffer)),
                      @"height": @(CVPixelBufferGetHeight(encoderPixelBuffer)),
                      @"activeContentX": @(encoderActiveContentRect.origin.x),
                      @"activeContentY": @(encoderActiveContentRect.origin.y),
                      @"activeContentWidth": @(encoderActiveContentRect.size.width),
                      @"activeContentHeight": @(encoderActiveContentRect.size.height),
                      @"captureGeneration": @(self.captureGeneration),
                      @"visibleWidthCoverage": @(widthCoverage),
                      @"visibleHeightCoverage": @(heightCoverage),
                      @"contentNormalized": @(needsContentNormalization),
                    }];
  }

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
    diagnostics[@"normalization"] = needsContentNormalization && normalizedPixelBuffer != NULL
        ? @"Visible content crop + full-canvas scale · Rec.709 · Video Range NV12"
        : !needsNormalization && !needsFreshCanvas
        ? @"Native SDR Rec.709 420v · zero-copy bypass"
        : !needsNormalization && normalizedPixelBuffer != NULL
            ? @"Fresh switch canvas · Rec.709 · Video Range NV12"
        : normalizedPixelBuffer != NULL
            ? @"Core Image GPU HDR→SDR · Rec.709 · Video Range NV12"
            : @"Normalization failed; original frame forwarded";
    diagnostics[@"normalizationBypassed"] = @(
        !needsNormalization && !needsFreshCanvas && !needsContentNormalization &&
        !needsCanonicalGeometry);
    diagnostics[@"normalizationDurationMs"] = @(normalizationDurationMs);
    diagnostics[@"rawFrame"] = rawDiagnostics ?: @{};
    diagnostics[@"encoderInput"] = encoderDiagnostics;
    NSMutableDictionary<NSString *, id> *frameGeometry =
        [CDRFrameGeometryDiagnostics(frameAttachments, pixelBuffer) mutableCopy];
    frameGeometry[@"captureGeneration"] = @(self.captureGeneration);
    frameGeometry[@"activeContentX"] = @(encoderActiveContentRect.origin.x);
    frameGeometry[@"activeContentY"] = @(encoderActiveContentRect.origin.y);
    frameGeometry[@"activeContentWidth"] = @(encoderActiveContentRect.size.width);
    frameGeometry[@"activeContentHeight"] = @(encoderActiveContentRect.size.height);
    diagnostics[@"frameGeometry"] = frameGeometry;
    NSLog(@"CrossDesktopRemote capture color diagnostics: %@", diagnostics);
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"CrossDesktopRemoteCaptureColorDiagnostics"
                      object:nil
                    userInfo:diagnostics];
  }

  CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
  int64_t timeStampNs = (int64_t)(CMTimeGetSeconds(timestamp) * 1000000000.0);

  if (self.lastActiveEncoderPixelBuffer != NULL) {
    CVPixelBufferRelease(self.lastActiveEncoderPixelBuffer);
  }
  self.lastActiveEncoderPixelBuffer = CVPixelBufferRetain(encoderPixelBuffer);
  self.lastActiveContentRect = encoderActiveContentRect;

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
