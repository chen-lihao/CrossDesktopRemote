#import "FlutterWebRTCPlugin.h"

#if TARGET_OS_OSX

@class FlutterSystemAudioCapturer;
@class FlutterRTCExternalAudioDevice;

@interface FlutterWebRTCPlugin (SystemAudioCapturer)

- (void)getSystemAudio:(nonnull FlutterResult)result;
- (void)stopSystemAudio:(nonnull FlutterResult)result;
- (void)getSystemAudioBackendInfo:(nonnull FlutterResult)result;

@end

@interface FlutterSystemAudioCapturer : NSObject

@property(nonatomic, readonly, getter=isActive) BOOL active;

- (nonnull instancetype)initWithAudioDevice:
    (nonnull FlutterRTCExternalAudioDevice*)audioDevice;
- (void)startWithCompletion:(void (^_Nonnull)(NSError* _Nullable error))completion;
- (void)stopWithCompletion:(void (^_Nonnull)(void))completion;

@end

#endif
