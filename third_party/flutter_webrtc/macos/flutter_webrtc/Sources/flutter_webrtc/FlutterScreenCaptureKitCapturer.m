#import "FlutterScreenCaptureKitCapturer.h"

#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>

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
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
@property(nonatomic, strong) SCStream *stream API_AVAILABLE(macos(12.3));
#endif
@end

@implementation FlutterScreenCaptureKitCapturer

- (instancetype)initWithDelegate:(id<RTCVideoCapturerDelegate>)delegate {
  self = [super init];
  if (self) {
    _delegate = delegate;
    _capturer = [[RTCVideoCapturer alloc] initWithDelegate:delegate];
    _captureQueue = dispatch_queue_create("com.iperius.sck.capture", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (void)startCaptureWithFPS:(NSInteger)fps
                   sourceId:(NSString* _Nullable)sourceId
                  onStarted:(void (^)(NSError * _Nullable error))onStarted {
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
  if (@available(macOS 12.3, *)) {
    self.sourceId = sourceId ?: @"";
    self.emittedColorDiagnostics = NO;
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
      SCStreamConfiguration *config = [SCStreamConfiguration new];
      config.width = display.width;
      config.height = display.height;
      config.minimumFrameInterval = CMTimeMake(1, (int32_t)MAX(1, fps));
      // CrossDesktopRemote's MVP media contract is explicitly SDR Rec.709
      // using video-range NV12. Full-range buffers without matching metadata
      // are interpreted inconsistently by hardware encoders and renderers.
      config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
      config.colorSpaceName = kCGColorSpaceITUR_709;
      config.colorMatrix = kCGDisplayStreamYCbCrMatrix_ITU_R_709_2;
      if (@available(macOS 15.0, *)) {
        config.captureDynamicRange = SCCaptureDynamicRangeSDR;
      }
      if (@available(macOS 13.0, *)) {
        config.showsCursor = YES;
      }

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

  CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  if (pixelBuffer == nil) {
    return;
  }

  CVBufferSetAttachment(pixelBuffer,
                        kCVImageBufferColorPrimariesKey,
                        kCVImageBufferColorPrimaries_ITU_R_709_2,
                        kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(pixelBuffer,
                        kCVImageBufferTransferFunctionKey,
                        kCVImageBufferTransferFunction_ITU_R_709_2,
                        kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(pixelBuffer,
                        kCVImageBufferYCbCrMatrixKey,
                        kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                        kCVAttachmentMode_ShouldPropagate);

  if (!self.emittedColorDiagnostics) {
    self.emittedColorDiagnostics = YES;
    OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
    NSString *pixelFormatName = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ? @"420v/NV12"
        : pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ? @"420f/NV12"
            : [NSString stringWithFormat:@"0x%08x", (unsigned int)pixelFormat];
    NSString *range = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ? @"Video Range"
        : pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ? @"Full Range"
            : @"Unknown";
    NSString *primaries = (__bridge NSString *)CVBufferGetAttachment(
        pixelBuffer, kCVImageBufferColorPrimariesKey, NULL) ?: @"Unknown";
    NSString *transfer = (__bridge NSString *)CVBufferGetAttachment(
        pixelBuffer, kCVImageBufferTransferFunctionKey, NULL) ?: @"Unknown";
    NSString *matrix = (__bridge NSString *)CVBufferGetAttachment(
        pixelBuffer, kCVImageBufferYCbCrMatrixKey, NULL) ?: @"Unknown";
    NSDictionary *diagnostics = @{
      @"sourceId": self.sourceId ?: @"",
      @"pixelFormat": pixelFormatName,
      @"range": range,
      @"colorPrimaries": primaries,
      @"transferFunction": transfer,
      @"yCbCrMatrix": matrix,
      @"colorSpace": @"ITU-R BT.709",
      @"captureDynamicRange": @"SDR"
    };
    NSLog(@"CrossDesktopRemote capture color diagnostics: %@", diagnostics);
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"CrossDesktopRemoteCaptureColorDiagnostics"
                      object:nil
                    userInfo:diagnostics];
  }

  CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
  int64_t timeStampNs = (int64_t)(CMTimeGetSeconds(timestamp) * 1000000000.0);

  id<RTCVideoFrameBuffer> rtcBuffer = [[RTCCVPixelBuffer alloc] initWithPixelBuffer:pixelBuffer];
  RTCVideoFrame *frame = [[RTCVideoFrame alloc] initWithBuffer:rtcBuffer
                                                      rotation:RTCVideoRotation_0
                                                   timeStampNs:timeStampNs];
  [self.delegate capturer:self.capturer didCaptureVideoFrame:frame];
}
#endif

@end
