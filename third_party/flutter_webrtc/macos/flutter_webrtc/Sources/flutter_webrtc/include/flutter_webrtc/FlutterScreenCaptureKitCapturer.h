#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>

NS_ASSUME_NONNULL_BEGIN

@class FlutterRTCExternalAudioDevice;

@interface FlutterScreenCaptureKitCapturer : NSObject

- (instancetype)initWithDelegate:(id<RTCVideoCapturerDelegate>)delegate;

/// Keeps ScreenCaptureKit's visible content geometry inside the canonical
/// encoder canvas instead of cropping it to fill. This is capability-gated so
/// existing Apple controllers retain their physically verified media path.
- (void)setPreserveVisibleContentGeometry:(BOOL)enabled;

/// Excludes only the privacy overlay windows owned by the current host
/// session. The IDs are NSWindow.windowNumber / CGWindowID values returned by
/// the macOS host bridge; application-wide exclusion is intentionally not
/// supported because it changes ScreenCaptureKit process lifetime semantics.
- (void)configureExcludedWindowIds:(NSArray<NSNumber *> *)windowIds;

/// Attaches system-audio delivery to the same ScreenCaptureKit stream that
/// owns the screen output and privacy filter. A second SCStream is never
/// created, so filter/window/audio callbacks share one lifecycle barrier.
- (void)startSystemAudioWithDevice:(FlutterRTCExternalAudioDevice *)audioDevice
                        completion:(void (^)(NSError * _Nullable error))completion;

/// Stops audio delivery without destroying the screen stream. Completion is
/// invoked only after queued audio callbacks have drained and the external ADM
/// no longer references the capture source.
- (void)stopSystemAudioWithCompletion:(void (^)(void))completion;

- (void)startCaptureWithFPS:(NSInteger)fps
                   sourceId:(NSString* _Nullable)sourceId
             targetLongEdge:(NSInteger)targetLongEdge
                  onStarted:(void (^ _Nonnull)(NSError * _Nullable error))onStarted;

- (void)stopCaptureWithCompletion:(void (^ _Nonnull)(void))completion;

- (void)switchCaptureToSourceId:(NSString* _Nonnull)sourceId
                            fps:(NSInteger)fps
                 targetLongEdge:(NSInteger)targetLongEdge
                   onCompletion:(void (^ _Nonnull)(NSDictionary<NSString *, id> * _Nullable configuration,
                                                    NSError * _Nullable error))onCompletion;

- (void)commitCaptureSwitchGeneration:(NSUInteger)generation
                          onCompletion:(void (^ _Nonnull)(NSError * _Nullable error))onCompletion;

- (void)rollbackCaptureSwitchGeneration:(NSUInteger)generation
                            onCompletion:(void (^ _Nonnull)(NSDictionary<NSString *, id> * _Nullable configuration,
                                                             NSError * _Nullable error))onCompletion;

- (void)updateCaptureWithFPS:(NSInteger)fps
              targetLongEdge:(NSInteger)targetLongEdge
                onCompletion:(void (^ _Nonnull)(NSDictionary<NSString *, id> * _Nullable configuration,
                                                 NSError * _Nullable error))onCompletion;

@end

NS_ASSUME_NONNULL_END
