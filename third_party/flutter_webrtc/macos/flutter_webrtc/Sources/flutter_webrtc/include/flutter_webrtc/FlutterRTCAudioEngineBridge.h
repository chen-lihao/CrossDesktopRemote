#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>

typedef void (^FlutterRTCAudioDeviceChangeHandler)(void);

/// Complete RTCAudioDeviceModuleDelegate implementation used to isolate
/// WebRTC's native audio-engine lifecycle from the Flutter plugin itself.
///
/// The WebRTC protocol methods are required and may be invoked from its worker
/// thread. Keeping the complete contract in one retained object prevents an
/// Objective-C `unrecognized selector` abort when playout or recording starts.
@interface FlutterRTCAudioEngineBridge : NSObject <RTCAudioDeviceModuleDelegate>

- (nonnull instancetype)initWithDeviceChangeHandler:
                            (nonnull FlutterRTCAudioDeviceChangeHandler)deviceChangeHandler;

@end
