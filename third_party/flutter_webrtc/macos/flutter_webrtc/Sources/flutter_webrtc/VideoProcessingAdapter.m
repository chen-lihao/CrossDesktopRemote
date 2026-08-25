#import "VideoProcessingAdapter.h"
#import <os/lock.h>

@implementation VideoProcessingAdapter {
  RTCVideoSource* _videoSource;
  CGSize _frameSize;
  NSArray<id<ExternalVideoProcessingDelegate>>* _processors;
  os_unfair_lock _lock;
  NSInteger _preferredFramesPerSecond;
  int _adaptedWidth;
  int _adaptedHeight;
}

- (instancetype)initWithRTCVideoSource:(RTCVideoSource*)source {
  self = [super init];
  if (self) {
    _lock = OS_UNFAIR_LOCK_INIT;
    _videoSource = source;
    _processors = [NSArray<id<ExternalVideoProcessingDelegate>> new];
    _preferredFramesPerSecond = 30;
  }
  return self;
}

- (RTCVideoSource* _Nonnull) source {
    return _videoSource;
}

- (void)addProcessing:(id<ExternalVideoProcessingDelegate>)processor {
  os_unfair_lock_lock(&_lock);
  _processors = [_processors arrayByAddingObject:processor];
  os_unfair_lock_unlock(&_lock);
}

- (void)removeProcessing:(id<ExternalVideoProcessingDelegate>)processor {
  os_unfair_lock_lock(&_lock);
  _processors = [_processors
      filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id evaluatedObject,
                                                                        NSDictionary* bindings) {
        return evaluatedObject != processor;
      }]];
  os_unfair_lock_unlock(&_lock);
}

- (void)setSize:(CGSize)size {
  _frameSize = size;
}

- (void)setPreferredFramesPerSecond:(NSInteger)fps {
  os_unfair_lock_lock(&_lock);
  _preferredFramesPerSecond = MAX(1, fps);
  os_unfair_lock_unlock(&_lock);
}

- (void)prepareOutputFormatWithWidth:(NSInteger)width
                              height:(NSInteger)height
                                 fps:(NSInteger)fps {
  if (width <= 0 || height <= 0) {
    return;
  }
  os_unfair_lock_lock(&_lock);
  _preferredFramesPerSecond = MAX(1, fps);
  [_videoSource adaptOutputFormatToWidth:(int)width
                                  height:(int)height
                                     fps:(int)_preferredFramesPerSecond];
  _adaptedWidth = (int)width;
  _adaptedHeight = (int)height;
  os_unfair_lock_unlock(&_lock);
}

- (void)capturer:(RTC_OBJC_TYPE(RTCVideoCapturer) *)capturer
    didCaptureVideoFrame:(RTC_OBJC_TYPE(RTCVideoFrame) *)frame {
  os_unfair_lock_lock(&_lock);
  if (frame.width > 0 &&
      frame.height > 0 &&
      (_adaptedWidth != frame.width || _adaptedHeight != frame.height)) {
    // ScreenCaptureKit displays may use different aspect ratios and backing
    // resolutions. Explicitly update the source adaptation envelope on the
    // first frame of each geometry instead of relying on an SDP renegotiation.
    [_videoSource adaptOutputFormatToWidth:frame.width
                                    height:frame.height
                                       fps:(int)_preferredFramesPerSecond];
    _adaptedWidth = frame.width;
    _adaptedHeight = frame.height;
  }
  for (id<ExternalVideoProcessingDelegate> processor in _processors) {
    frame = [processor onFrame:frame];
  }
  [_videoSource capturer:capturer didCaptureVideoFrame:frame];
  os_unfair_lock_unlock(&_lock);
}

@end
