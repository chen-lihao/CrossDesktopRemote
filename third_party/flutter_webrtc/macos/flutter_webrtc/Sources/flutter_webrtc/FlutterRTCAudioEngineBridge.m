#import "FlutterRTCAudioEngineBridge.h"

#import "FlutterRTCSystemAudioCapturer.h"

@interface FlutterRTCAudioEngineBridge ()

@property(nonatomic, copy) FlutterRTCSystemAudioCapturerProvider capturerProvider;
@property(nonatomic, copy) FlutterRTCAudioDeviceChangeHandler deviceChangeHandler;

@end

#pragma clang diagnostic push
#pragma clang diagnostic error "-Wprotocol"
@implementation FlutterRTCAudioEngineBridge

- (instancetype)initWithSystemAudioCapturerProvider:
                    (FlutterRTCSystemAudioCapturerProvider)capturerProvider
                              deviceChangeHandler:
                    (FlutterRTCAudioDeviceChangeHandler)deviceChangeHandler {
  self = [super init];
  if (self) {
    _capturerProvider = [capturerProvider copy];
    _deviceChangeHandler = [deviceChangeHandler copy];
  }
  return self;
}

- (void)audioDeviceModule:(RTCAudioDeviceModule*)audioDeviceModule
    didReceiveSpeechActivityEvent:(RTCSpeechActivityEvent)speechActivityEvent {
  // System-audio sharing does not consume microphone speech activity.
}

- (NSInteger)audioDeviceModule:(RTCAudioDeviceModule*)audioDeviceModule
               didCreateEngine:(AVAudioEngine*)engine {
  return 0;
}

- (NSInteger)audioDeviceModule:(RTCAudioDeviceModule*)audioDeviceModule
              willEnableEngine:(AVAudioEngine*)engine
              isPlayoutEnabled:(BOOL)isPlayoutEnabled
            isRecordingEnabled:(BOOL)isRecordingEnabled {
  return 0;
}

- (NSInteger)audioDeviceModule:(RTCAudioDeviceModule*)audioDeviceModule
               willStartEngine:(AVAudioEngine*)engine
              isPlayoutEnabled:(BOOL)isPlayoutEnabled
            isRecordingEnabled:(BOOL)isRecordingEnabled {
  return 0;
}

- (NSInteger)audioDeviceModule:(RTCAudioDeviceModule*)audioDeviceModule
                 didStopEngine:(AVAudioEngine*)engine
              isPlayoutEnabled:(BOOL)isPlayoutEnabled
            isRecordingEnabled:(BOOL)isRecordingEnabled {
  return 0;
}

- (NSInteger)audioDeviceModule:(RTCAudioDeviceModule*)audioDeviceModule
              didDisableEngine:(AVAudioEngine*)engine
              isPlayoutEnabled:(BOOL)isPlayoutEnabled
            isRecordingEnabled:(BOOL)isRecordingEnabled {
  return 0;
}

- (NSInteger)audioDeviceModule:(RTCAudioDeviceModule*)audioDeviceModule
             willReleaseEngine:(AVAudioEngine*)engine {
  return 0;
}

- (NSInteger)audioDeviceModule:(RTCAudioDeviceModule*)audioDeviceModule
                        engine:(AVAudioEngine*)engine
      configureInputFromSource:(AVAudioNode* _Nullable)source
                 toDestination:(AVAudioNode*)destination
                    withFormat:(AVAudioFormat*)format
                       context:(NSDictionary*)context {
  FlutterSystemAudioCapturer* capturer = self.capturerProvider();
  if (capturer != nil && capturer.isActive) {
    return [capturer configureInputForEngine:engine
                                     source:source
                                destination:destination
                                     format:format];
  }
  if (source != nil) {
    [engine connect:source to:destination format:format];
  }
  return 0;
}

- (NSInteger)audioDeviceModule:(RTCAudioDeviceModule*)audioDeviceModule
                        engine:(AVAudioEngine*)engine
     configureOutputFromSource:(AVAudioNode*)source
                 toDestination:(AVAudioNode* _Nullable)destination
                    withFormat:(AVAudioFormat*)format
                       context:(NSDictionary*)context {
  if (destination != nil) {
    [engine connect:source to:destination format:format];
  }
  return 0;
}

- (void)audioDeviceModuleDidUpdateDevices:(RTCAudioDeviceModule*)audioDeviceModule {
  self.deviceChangeHandler();
}

@end
#pragma clang diagnostic pop
