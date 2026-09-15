#import "FlutterWebRTCPlugin.h"

#if TARGET_OS_OSX

@class FlutterSystemAudioCapturer;

@interface FlutterWebRTCPlugin (SystemAudioCapturer)

- (void)getSystemAudio:(nonnull FlutterResult)result;
- (void)stopSystemAudio:(nonnull FlutterResult)result;

@end

@interface FlutterSystemAudioCapturer : NSObject

@property(nonatomic, readonly, getter=isActive) BOOL active;

- (void)startWithCompletion:(void (^_Nonnull)(NSError* _Nullable error))completion;
- (void)stopWithCompletion:(void (^_Nonnull)(void))completion;
- (NSInteger)configureInputForEngine:(nonnull AVAudioEngine*)engine
                              source:(nullable AVAudioNode*)source
                         destination:(nonnull AVAudioNode*)destination
                              format:(nonnull AVAudioFormat*)format;

@end

#endif
