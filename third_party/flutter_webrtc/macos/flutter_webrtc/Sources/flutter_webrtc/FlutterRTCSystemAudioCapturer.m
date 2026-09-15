#import "FlutterRTCSystemAudioCapturer.h"

#if TARGET_OS_OSX

#import "LocalAudioTrack.h"
#import "FlutterRTCMediaStream.h"

#import <CoreMedia/CoreMedia.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

static NSString* const FlutterSystemAudioErrorDomain = @"FlutterSystemAudioCapture";
static const NSUInteger FlutterSystemAudioMaximumPendingBuffers = 20;

API_AVAILABLE(macos(13.0))
@interface FlutterSystemAudioCapturer () <SCStreamOutput>

@property(nonatomic, strong, nullable) SCStream* stream;
@property(nonatomic, strong, nullable) AVAudioPlayerNode* playerNode;
@property(nonatomic, weak, nullable) AVAudioEngine* engine;
@property(nonatomic, strong) dispatch_queue_t captureQueue;
@property(nonatomic) NSUInteger pendingBufferCount;
@property(nonatomic, readwrite, getter=isActive) BOOL active;
@property(nonatomic) BOOL cancelled;

@end


@implementation FlutterSystemAudioCapturer

- (instancetype)init {
  self = [super init];
  if (self) {
    _captureQueue = dispatch_queue_create("com.crossdesktopremote.system-audio", DISPATCH_QUEUE_SERIAL);
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
    [SCShareableContent
        getShareableContentExcludingDesktopWindows:NO
                                  onScreenWindowsOnly:NO
                                    completionHandler:^(SCShareableContent* _Nullable content,
                                                        NSError* _Nullable error) {
      FlutterSystemAudioCapturer* strongSelf = weakSelf;
      if (strongSelf == nil) {
        completion([NSError errorWithDomain:FlutterSystemAudioErrorDomain
                                       code:1
                                   userInfo:@{NSLocalizedDescriptionKey : @"System audio capture was cancelled"}]);
        return;
      }
      if (strongSelf.cancelled) {
        completion([NSError errorWithDomain:FlutterSystemAudioErrorDomain
                                       code:5
                                   userInfo:@{NSLocalizedDescriptionKey : @"System audio capture was cancelled"}]);
        return;
      }
      if (error != nil || content.displays.count == 0) {
        completion(error ?: [NSError errorWithDomain:FlutterSystemAudioErrorDomain
                                                code:2
                                            userInfo:@{NSLocalizedDescriptionKey : @"No display is available for system audio capture"}]);
        return;
      }

      SCContentFilter* filter =
          [[SCContentFilter alloc] initWithDisplay:content.displays.firstObject
                                 excludingWindows:@[]];
      SCStreamConfiguration* configuration = [[SCStreamConfiguration alloc] init];
      configuration.capturesAudio = YES;
      configuration.sampleRate = 48000;
      configuration.channelCount = 2;
      configuration.excludesCurrentProcessAudio = YES;
      configuration.width = 2;
      configuration.height = 2;
      configuration.minimumFrameInterval = CMTimeMake(1, 1);
      configuration.queueDepth = 3;

      SCStream* stream = [[SCStream alloc] initWithFilter:filter
                                           configuration:configuration
                                                delegate:nil];
      NSError* outputError = nil;
      if (![stream addStreamOutput:strongSelf
                              type:SCStreamOutputTypeAudio
                sampleHandlerQueue:strongSelf.captureQueue
                             error:&outputError]) {
        completion(outputError ?: [NSError errorWithDomain:FlutterSystemAudioErrorDomain
                                                   code:3
                                               userInfo:@{NSLocalizedDescriptionKey : @"Unable to attach system audio output"}]);
        return;
      }
      strongSelf.stream = stream;
      [stream startCaptureWithCompletionHandler:^(NSError* _Nullable startError) {
        if (strongSelf.cancelled && startError == nil) {
          [stream stopCaptureWithCompletionHandler:nil];
          startError = [NSError errorWithDomain:FlutterSystemAudioErrorDomain
                                           code:5
                                       userInfo:@{NSLocalizedDescriptionKey : @"System audio capture was cancelled"}];
        }
        strongSelf.active = startError == nil;
        if (startError != nil) {
          strongSelf.stream = nil;
        }
        completion(startError);
      }];
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
  self.pendingBufferCount = 0;
  [self.playerNode stop];
  [self.playerNode reset];
  if (self.engine != nil && self.playerNode.engine == self.engine) {
    [self.engine disconnectNodeOutput:self.playerNode];
    [self.engine detachNode:self.playerNode];
  }
  self.playerNode = nil;
  self.engine = nil;

  if (@available(macOS 12.3, *)) {
    SCStream* stream = self.stream;
    self.stream = nil;
    if (stream == nil) {
      completion();
      return;
    }
    [stream stopCaptureWithCompletionHandler:^(NSError* _Nullable error) {
      if (error != nil) {
        NSLog(@"System audio capture stop failed: %@", error);
      }
      completion();
    }];
  } else {
    completion();
  }
}

- (NSInteger)configureInputForEngine:(AVAudioEngine*)engine
                              source:(AVAudioNode* _Nullable)source
                         destination:(AVAudioNode*)destination
                              format:(AVAudioFormat*)format {
  if (!self.active) {
    if (source != nil) {
      [engine connect:source to:destination format:format];
    }
    return 0;
  }

  AVAudioPlayerNode* playerNode = [[AVAudioPlayerNode alloc] init];
  AVAudioFormat* captureFormat = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000
                                                                                channels:2];
  if (captureFormat == nil) {
    return -1;
  }
  [engine attachNode:playerNode];
  [engine connect:playerNode to:destination format:captureFormat];
  self.engine = engine;
  self.playerNode = playerNode;
  [playerNode play];
  return 0;
}

- (void)stream:(SCStream*)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   ofType:(SCStreamOutputType)type API_AVAILABLE(macos(13.0)) {
  if (!self.active || type != SCStreamOutputTypeAudio ||
      !CMSampleBufferIsValid(sampleBuffer) ||
      !CMSampleBufferDataIsReady(sampleBuffer)) {
    return;
  }
  AVAudioPlayerNode* playerNode = self.playerNode;
  if (playerNode == nil) {
    return;
  }
  @synchronized(self) {
    if (self.pendingBufferCount >= FlutterSystemAudioMaximumPendingBuffers) {
      return;
    }
    self.pendingBufferCount += 1;
  }

  CMAudioFormatDescriptionRef formatDescription =
      (CMAudioFormatDescriptionRef)CMSampleBufferGetFormatDescription(sampleBuffer);
  const AudioStreamBasicDescription* streamDescription =
      CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription);
  AVAudioFormat* format = streamDescription == NULL
                              ? nil
                              : [[AVAudioFormat alloc] initWithStreamDescription:streamDescription];
  CMItemCount sampleCount = CMSampleBufferGetNumSamples(sampleBuffer);
  AVAudioPCMBuffer* pcmBuffer =
      format == nil || sampleCount <= 0
          ? nil
          : [[AVAudioPCMBuffer alloc] initWithPCMFormat:format
                                         frameCapacity:(AVAudioFrameCount)sampleCount];
  if (pcmBuffer == nil) {
    @synchronized(self) {
      self.pendingBufferCount -= 1;
    }
    return;
  }
  pcmBuffer.frameLength = (AVAudioFrameCount)sampleCount;
  OSStatus copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
      sampleBuffer,
      0,
      (int32_t)sampleCount,
      pcmBuffer.mutableAudioBufferList);
  if (copyStatus != noErr) {
    @synchronized(self) {
      self.pendingBufferCount -= 1;
    }
    return;
  }

  __weak FlutterSystemAudioCapturer* weakSelf = self;
  [playerNode scheduleBuffer:pcmBuffer
      completionCallbackType:AVAudioPlayerNodeCompletionDataConsumed
           completionHandler:^(AVAudioPlayerNodeCompletionCallbackType callbackType) {
    FlutterSystemAudioCapturer* strongSelf = weakSelf;
    if (strongSelf == nil) return;
    @synchronized(strongSelf) {
      if (strongSelf.pendingBufferCount > 0) {
        strongSelf.pendingBufferCount -= 1;
      }
    }
  }];
}

@end


@implementation FlutterWebRTCPlugin (SystemAudioCapturer)

- (void)getSystemAudio:(FlutterResult)result {
  if (@available(macOS 13.0, *)) {
    if (self.systemAudioCapturer != nil) {
      result([FlutterError errorWithCode:@"SystemAudioAlreadyActive"
                                 message:@"System audio capture is already active"
                                 details:nil]);
      return;
    }
    FlutterSystemAudioCapturer* capturer = [[FlutterSystemAudioCapturer alloc] init];
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
        [track setAudioProcessingOptions:[RTCAudioProcessingOptions rawOptions]];
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
