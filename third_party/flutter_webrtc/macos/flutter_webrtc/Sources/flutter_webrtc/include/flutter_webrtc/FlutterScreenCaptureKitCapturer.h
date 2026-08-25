#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>

NS_ASSUME_NONNULL_BEGIN

@interface FlutterScreenCaptureKitCapturer : NSObject

- (instancetype)initWithDelegate:(id<RTCVideoCapturerDelegate>)delegate;

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
