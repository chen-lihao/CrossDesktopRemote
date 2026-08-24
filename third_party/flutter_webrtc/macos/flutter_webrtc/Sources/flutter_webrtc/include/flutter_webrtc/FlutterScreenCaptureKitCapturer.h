#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>

NS_ASSUME_NONNULL_BEGIN

@interface FlutterScreenCaptureKitCapturer : NSObject

- (instancetype)initWithDelegate:(id<RTCVideoCapturerDelegate>)delegate;

- (void)startCaptureWithFPS:(NSInteger)fps
                   sourceId:(NSString* _Nullable)sourceId
                  onStarted:(void (^ _Nonnull)(NSError * _Nullable error))onStarted;

- (void)stopCaptureWithCompletion:(void (^ _Nonnull)(void))completion;

- (void)switchCaptureToSourceId:(NSString* _Nonnull)sourceId
                            fps:(NSInteger)fps
                   onCompletion:(void (^ _Nonnull)(NSError * _Nullable error))onCompletion;

@end

NS_ASSUME_NONNULL_END
