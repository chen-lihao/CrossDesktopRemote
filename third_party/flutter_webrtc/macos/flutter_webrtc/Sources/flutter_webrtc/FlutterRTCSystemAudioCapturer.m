#import "FlutterRTCSystemAudioCapturer.h"

#if TARGET_OS_OSX

#import "LocalAudioTrack.h"
#import "FlutterRTCMediaStream.h"
#import "FlutterRTCExternalAudioDevice.h"
#import "FlutterScreenCaptureKitCapturer.h"

static NSString* const FlutterSystemAudioErrorDomain = @"FlutterSystemAudioCapture";

@interface FlutterSystemAudioCapturer ()
@property(nonatomic, weak) FlutterRTCExternalAudioDevice* audioDevice;
@property(nonatomic, strong) FlutterScreenCaptureKitCapturer* screenCapturer;
@property(nonatomic, readwrite, getter=isActive) BOOL active;
@property(nonatomic) BOOL cancelled;

@end


@implementation FlutterSystemAudioCapturer

- (instancetype)initWithAudioDevice:(FlutterRTCExternalAudioDevice*)audioDevice
                      screenCapturer:(FlutterScreenCaptureKitCapturer*)screenCapturer {
  self = [super init];
  if (self) {
    _audioDevice = audioDevice;
    _screenCapturer = screenCapturer;
  }
  return self;
}

- (void)startWithCompletion:(void (^)(NSError* _Nullable error))completion {
  if (self.active) {
    completion(nil);
    return;
  }
  if (@available(macOS 13.0, *)) {
    self.cancelled = NO;
    __weak FlutterSystemAudioCapturer* weakSelf = self;
    [self.screenCapturer startSystemAudioWithDevice:self.audioDevice
                                         completion:^(NSError* _Nullable error) {
      FlutterSystemAudioCapturer* strongSelf = weakSelf;
      if (strongSelf == nil) {
        completion([NSError errorWithDomain:FlutterSystemAudioErrorDomain
                                       code:1
                                   userInfo:@{NSLocalizedDescriptionKey : @"System audio capture was cancelled"}]);
        return;
      }
      if (strongSelf.cancelled) {
        [strongSelf.screenCapturer stopSystemAudioWithCompletion:^{}];
        completion([NSError errorWithDomain:FlutterSystemAudioErrorDomain
                                       code:5
                                   userInfo:@{NSLocalizedDescriptionKey : @"System audio capture was cancelled"}]);
        return;
      }
      strongSelf.active = error == nil;
      completion(error);
    }];
  } else {
    completion([NSError errorWithDomain:FlutterSystemAudioErrorDomain
                                   code:4
                               userInfo:@{NSLocalizedDescriptionKey : @"System audio capture requires macOS 13 or later"}]);
  }
}

- (void)stopWithCompletion:(void (^)(void))completion {
  self.cancelled = YES;
  self.active = NO;
  [self.screenCapturer stopSystemAudioWithCompletion:completion];
}

@end


@implementation FlutterWebRTCPlugin (SystemAudioCapturer)

- (void)getSystemAudio:(FlutterResult)result {
  FlutterRTCExternalAudioDevice* audioDevice = self.externalAudioDevice;
  if (audioDevice == nil) {
    result([FlutterError errorWithCode:@"SystemAudioExternalRecordingUnavailable"
                               message:@"The microphone-free external audio device is unavailable"
                               details:nil]);
    return;
  }
  if (@available(macOS 13.0, *)) {
    if (self.systemAudioCapturer != nil) {
      result([FlutterError errorWithCode:@"SystemAudioAlreadyActive"
                                 message:@"System audio capture is already active"
                                 details:nil]);
      return;
    }
    NSArray<FlutterScreenCaptureKitCapturer*>* screenCapturers =
        self.screenCaptureKitCapturers.allValues;
    if (screenCapturers.count != 1) {
      result([FlutterError errorWithCode:@"SystemAudioScreenSessionUnavailable"
                                 message:@"System audio requires exactly one active screen capture session"
                                 details:@{ @"activeScreenCapturers" : @(screenCapturers.count) }]);
      return;
    }
    FlutterScreenCaptureKitCapturer* screenCapturer = screenCapturers.firstObject;
    if (!screenCapturer.isCaptureRunning) {
      result([FlutterError errorWithCode:@"SystemAudioScreenSessionNotReady"
                                 message:@"System audio requires a running screen capture session"
                                 details:nil]);
      return;
    }
    FlutterSystemAudioCapturer* capturer =
        [[FlutterSystemAudioCapturer alloc] initWithAudioDevice:audioDevice
                                                screenCapturer:screenCapturer];
    self.systemAudioCapturer = capturer;
    __weak FlutterWebRTCPlugin* weakSelf = self;
    [capturer startWithCompletion:^(NSError* _Nullable error) {
      dispatch_async(dispatch_get_main_queue(), ^{
        FlutterWebRTCPlugin* strongSelf = weakSelf;
        if (strongSelf == nil) return;
        if (strongSelf.systemAudioCapturer != capturer) {
          result([FlutterError errorWithCode:@"SystemAudioCancelled"
                                     message:@"System audio capture was cancelled"
                                     details:nil]);
          return;
        }
        if (error != nil) {
          strongSelf.systemAudioCapturer = nil;
          result([FlutterError errorWithCode:@"SystemAudioUnavailable"
                                     message:error.localizedDescription
                                     details:nil]);
          return;
        }

        NSString* streamId = [[NSUUID UUID] UUIDString];
        NSString* trackId = [[NSUUID UUID] UUIDString];
        RTCMediaStream* stream =
            [strongSelf.peerConnectionFactory mediaStreamWithStreamId:streamId];
        RTCAudioSource* source =
            [strongSelf.peerConnectionFactory audioSourceWithConstraints:nil];
        RTCAudioTrack* track =
            [strongSelf.peerConnectionFactory audioTrackWithSource:source trackId:trackId];
        RTCAudioProcessingOptionsResult* processingResult =
            [track setAudioProcessingOptions:[RTCAudioProcessingOptions rawOptions]];
        if (!processingResult.isSuccess) {
          strongSelf.systemAudioCapturer = nil;
          [capturer stopWithCompletion:^{
            dispatch_async(dispatch_get_main_queue(), ^{
              result([FlutterError
                  errorWithCode:@"SystemAudioRawProcessingRejected"
                         message:[NSString
                                     stringWithFormat:
                                         @"Unable to disable voice processing for system audio: %@",
                                         processingResult.message]
                         details:@{@"resultCode" : @(processingResult.code)}]);
            });
          }];
          return;
        }
        track.settings = @{
          @"deviceId" : @"system-audio",
          @"kind" : @"audioinput",
          @"autoGainControl" : @NO,
          @"echoCancellation" : @NO,
          @"noiseSuppression" : @NO,
          @"channelCount" : @2,
          @"sampleRate" : @48000,
        };
        [stream addAudioTrack:track];
        LocalAudioTrack* localTrack = [[LocalAudioTrack alloc] initWithTrack:track];
        strongSelf.localTracks[trackId] = localTrack;
        strongSelf.localStreams[streamId] = stream;
        result(@{
          @"streamId" : streamId,
          @"audioTracks" : @[@{
            @"id" : track.trackId,
            @"kind" : track.kind,
            @"label" : track.trackId,
            @"enabled" : @(track.isEnabled),
            @"remote" : @YES,
            @"readyState" : @"live",
            @"settings" : track.settings,
          }],
          @"videoTracks" : @[],
        });
      });
    }];
    return;
  }
  result([FlutterError errorWithCode:@"SystemAudioUnavailable"
                             message:@"System audio capture requires macOS 13 or later"
                             details:nil]);
}

- (void)getSystemAudioBackendInfo:(FlutterResult)result {
  FlutterRTCExternalAudioDevice* audioDevice = self.externalAudioDevice;
  if (audioDevice == nil) {
    result(@{
      @"backend" : @"unsupported",
      @"version" : @0,
      @"microphoneFree" : @NO,
    });
    return;
  }
  result([audioDevice backendInfo]);
}

- (void)stopSystemAudio:(FlutterResult)result {
  FlutterSystemAudioCapturer* capturer = self.systemAudioCapturer;
  self.systemAudioCapturer = nil;
  if (capturer == nil) {
    result(nil);
    return;
  }
  [capturer stopWithCompletion:^{
    dispatch_async(dispatch_get_main_queue(), ^{
      result(nil);
    });
  }];
}

@end

#endif
