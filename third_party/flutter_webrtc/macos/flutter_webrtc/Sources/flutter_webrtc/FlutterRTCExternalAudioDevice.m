#import "FlutterRTCExternalAudioDevice.h"

#if TARGET_OS_OSX

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <mach/mach_time.h>
#import <math.h>
#import <stdatomic.h>
#import <string.h>

static const double FlutterRTCAudioSampleRate = 48000.0;
static const NSTimeInterval FlutterRTCAudioBufferDuration = 0.01;
enum {
  FlutterRTCAudioChannels = 2,
};

static AudioStreamBasicDescription FlutterRTCSignedIntegerFormat(void) {
  AudioStreamBasicDescription format = {0};
  format.mSampleRate = FlutterRTCAudioSampleRate;
  format.mFormatID = kAudioFormatLinearPCM;
  format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
  format.mBytesPerPacket = (UInt32)(sizeof(int16_t) * FlutterRTCAudioChannels);
  format.mFramesPerPacket = 1;
  format.mBytesPerFrame = (UInt32)(sizeof(int16_t) * FlutterRTCAudioChannels);
  format.mChannelsPerFrame = (UInt32)FlutterRTCAudioChannels;
  format.mBitsPerChannel = 16;
  return format;
}

@interface FlutterRTCExternalAudioDevice () {
  AudioUnit _playoutUnit;
  atomic_bool _initialized;
  atomic_bool _playoutInitialized;
  atomic_bool _playing;
  atomic_bool _recordingInitialized;
  atomic_bool _recording;
  atomic_bool _systemAudioSourceAttached;
  atomic_uint_fast64_t _capturedFrames;
  atomic_uint_fast64_t _deliveredFrames;
  atomic_uint_fast64_t _conversionFailures;
  atomic_uint_fast64_t _deliveryFailures;
  atomic_uint_fast64_t _timestampDiscontinuities;
  uint64_t _lastCaptureHostTime;
}

@property(nonatomic, weak, nullable) id<RTCAudioDeviceDelegate> delegate;
@property(nonatomic, strong, nullable) AVAudioConverter* inputConverter;
@property(nonatomic, strong, nullable) AVAudioFormat* converterInputFormat;
@property(nonatomic, strong) AVAudioFormat* converterOutputFormat;

@end

static OSStatus FlutterRTCPlayoutCallback(void* context,
                                         AudioUnitRenderActionFlags* actionFlags,
                                         const AudioTimeStamp* timestamp,
                                         UInt32 busNumber,
                                         UInt32 frameCount,
                                         AudioBufferList* outputData) {
  FlutterRTCExternalAudioDevice* device = (__bridge FlutterRTCExternalAudioDevice*)context;
  id<RTCAudioDeviceDelegate> delegate = device.delegate;
  if (delegate == nil || !device.isPlaying) {
    for (UInt32 index = 0; index < outputData->mNumberBuffers; index += 1) {
      AudioBuffer* buffer = &outputData->mBuffers[index];
      if (buffer->mData != NULL) {
        memset(buffer->mData, 0, buffer->mDataByteSize);
      }
    }
    *actionFlags |= kAudioUnitRenderAction_OutputIsSilence;
    return noErr;
  }
  RTCAudioDeviceGetPlayoutDataBlock playout = delegate.getPlayoutData;
  return playout(actionFlags, timestamp, (NSInteger)busNumber, frameCount, outputData);
}

@implementation FlutterRTCExternalAudioDevice

- (instancetype)init {
  self = [super init];
  if (self) {
    atomic_init(&_initialized, false);
    atomic_init(&_playoutInitialized, false);
    atomic_init(&_playing, false);
    atomic_init(&_recordingInitialized, false);
    atomic_init(&_recording, false);
    atomic_init(&_systemAudioSourceAttached, false);
    atomic_init(&_capturedFrames, 0);
    atomic_init(&_deliveredFrames, 0);
    atomic_init(&_conversionFailures, 0);
    atomic_init(&_deliveryFailures, 0);
    atomic_init(&_timestampDiscontinuities, 0);
    _lastCaptureHostTime = 0;
    AudioStreamBasicDescription outputDescription = FlutterRTCSignedIntegerFormat();
    _converterOutputFormat = [[AVAudioFormat alloc] initWithStreamDescription:&outputDescription];
  }
  return self;
}

- (double)deviceInputSampleRate { return FlutterRTCAudioSampleRate; }
- (NSTimeInterval)inputIOBufferDuration { return FlutterRTCAudioBufferDuration; }
- (NSInteger)inputNumberOfChannels { return FlutterRTCAudioChannels; }
- (NSTimeInterval)inputLatency { return FlutterRTCAudioBufferDuration; }
- (double)deviceOutputSampleRate { return FlutterRTCAudioSampleRate; }
- (NSTimeInterval)outputIOBufferDuration { return FlutterRTCAudioBufferDuration; }
- (NSInteger)outputNumberOfChannels { return FlutterRTCAudioChannels; }
- (NSTimeInterval)outputLatency { return FlutterRTCAudioBufferDuration; }
- (BOOL)isInitialized { return atomic_load(&_initialized); }
- (BOOL)isPlayoutInitialized { return atomic_load(&_playoutInitialized); }
- (BOOL)isPlaying { return atomic_load(&_playing); }
- (BOOL)isRecordingInitialized { return atomic_load(&_recordingInitialized); }
- (BOOL)isRecording { return atomic_load(&_recording); }
- (BOOL)isSystemAudioSourceAttached { return atomic_load(&_systemAudioSourceAttached); }

- (BOOL)initializeWithDelegate:(id<RTCAudioDeviceDelegate>)delegate {
  if (delegate == nil) return NO;
  self.delegate = delegate;
  atomic_store(&_initialized, true);
  return YES;
}

- (BOOL)terminateDevice {
  [self stopRecording];
  [self stopPlayout];
  if (_playoutUnit != NULL) {
    AudioUnitUninitialize(_playoutUnit);
    AudioComponentInstanceDispose(_playoutUnit);
    _playoutUnit = NULL;
  }
  atomic_store(&_playoutInitialized, false);
  atomic_store(&_recordingInitialized, false);
  atomic_store(&_initialized, false);
  self.delegate = nil;
  return YES;
}

- (BOOL)initializePlayout {
  if (atomic_load(&_playoutInitialized)) return YES;
  AudioComponentDescription description = {0};
  description.componentType = kAudioUnitType_Output;
  description.componentSubType = kAudioUnitSubType_DefaultOutput;
  description.componentManufacturer = kAudioUnitManufacturer_Apple;
  AudioComponent component = AudioComponentFindNext(NULL, &description);
  if (component == NULL || AudioComponentInstanceNew(component, &_playoutUnit) != noErr) {
    _playoutUnit = NULL;
    return NO;
  }

  AudioStreamBasicDescription format = FlutterRTCSignedIntegerFormat();
  OSStatus status = AudioUnitSetProperty(_playoutUnit,
                                         kAudioUnitProperty_StreamFormat,
                                         kAudioUnitScope_Input,
                                         0,
                                         &format,
                                         sizeof(format));
  if (status == noErr) {
    AURenderCallbackStruct callback = {0};
    callback.inputProc = FlutterRTCPlayoutCallback;
    callback.inputProcRefCon = (__bridge void*)self;
    status = AudioUnitSetProperty(_playoutUnit,
                                  kAudioUnitProperty_SetRenderCallback,
                                  kAudioUnitScope_Input,
                                  0,
                                  &callback,
                                  sizeof(callback));
  }
  if (status == noErr) {
    status = AudioUnitInitialize(_playoutUnit);
  }
  if (status != noErr) {
    AudioComponentInstanceDispose(_playoutUnit);
    _playoutUnit = NULL;
    return NO;
  }
  atomic_store(&_playoutInitialized, true);
  return YES;
}

- (BOOL)startPlayout {
  if (![self initializePlayout]) return NO;
  if (atomic_load(&_playing)) return YES;
  if (AudioOutputUnitStart(_playoutUnit) != noErr) return NO;
  atomic_store(&_playing, true);
  return YES;
}

- (BOOL)stopPlayout {
  if (_playoutUnit != NULL && atomic_load(&_playing)) {
    AudioOutputUnitStop(_playoutUnit);
  }
  atomic_store(&_playing, false);
  return YES;
}

- (BOOL)initializeRecording {
  atomic_store(&_recordingInitialized, true);
  return YES;
}

- (BOOL)startRecording {
  if (![self initializeRecording]) return NO;
  _lastCaptureHostTime = 0;
  atomic_store(&_recording, true);
  return YES;
}

- (BOOL)stopRecording {
  atomic_store(&_recording, false);
  _lastCaptureHostTime = 0;
  return YES;
}

- (void)attachSystemAudioSource {
  atomic_store(&_systemAudioSourceAttached, true);
}

- (void)detachSystemAudioSource {
  atomic_store(&_systemAudioSourceAttached, false);
  _lastCaptureHostTime = 0;
  self.inputConverter = nil;
  self.converterInputFormat = nil;
}

- (BOOL)prepareConverterForInputFormat:(AVAudioFormat*)inputFormat {
  const AudioStreamBasicDescription* current = self.converterInputFormat.streamDescription;
  const AudioStreamBasicDescription* next = inputFormat.streamDescription;
  BOOL unchanged = current != NULL && next != NULL &&
      current->mSampleRate == next->mSampleRate &&
      current->mFormatID == next->mFormatID &&
      current->mFormatFlags == next->mFormatFlags &&
      current->mChannelsPerFrame == next->mChannelsPerFrame &&
      current->mBitsPerChannel == next->mBitsPerChannel &&
      current->mBytesPerFrame == next->mBytesPerFrame;
  if (unchanged && self.inputConverter != nil) return YES;
  AVAudioConverter* converter = [[AVAudioConverter alloc]
      initFromFormat:inputFormat
            toFormat:self.converterOutputFormat];
  if (converter == nil) return NO;
  self.converterInputFormat = inputFormat;
  self.inputConverter = converter;
  return YES;
}

- (void)consumeSystemAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer {
  if (!atomic_load(&_systemAudioSourceAttached) ||
      !atomic_load(&_recording) ||
      !CMSampleBufferIsValid(sampleBuffer) ||
      !CMSampleBufferDataIsReady(sampleBuffer)) {
    return;
  }
  CMAudioFormatDescriptionRef description =
      (CMAudioFormatDescriptionRef)CMSampleBufferGetFormatDescription(sampleBuffer);
  const AudioStreamBasicDescription* inputDescription =
      description == NULL ? NULL : CMAudioFormatDescriptionGetStreamBasicDescription(description);
  CMItemCount sampleCount = CMSampleBufferGetNumSamples(sampleBuffer);
  if (inputDescription == NULL || sampleCount <= 0) return;

  AVAudioFormat* inputFormat = [[AVAudioFormat alloc] initWithStreamDescription:inputDescription];
  AVAudioPCMBuffer* inputBuffer = inputFormat == nil
      ? nil
      : [[AVAudioPCMBuffer alloc] initWithPCMFormat:inputFormat
                                      frameCapacity:(AVAudioFrameCount)sampleCount];
  if (inputBuffer == nil || ![self prepareConverterForInputFormat:inputFormat]) {
    atomic_fetch_add(&_conversionFailures, 1);
    return;
  }
  inputBuffer.frameLength = (AVAudioFrameCount)sampleCount;
  if (CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer,
                                                   0,
                                                   (int32_t)sampleCount,
                                                   inputBuffer.mutableAudioBufferList) != noErr) {
    atomic_fetch_add(&_conversionFailures, 1);
    return;
  }

  double inputRate = MAX(inputFormat.sampleRate, 1.0);
  AVAudioFrameCount outputCapacity =
      (AVAudioFrameCount)ceil(((double)sampleCount * FlutterRTCAudioSampleRate) / inputRate) + 32;
  AVAudioPCMBuffer* outputBuffer =
      [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.converterOutputFormat
                                    frameCapacity:outputCapacity];
  if (outputBuffer == nil) {
    atomic_fetch_add(&_conversionFailures, 1);
    return;
  }

  __block BOOL suppliedInput = NO;
  NSError* conversionError = nil;
  AVAudioConverterOutputStatus conversionStatus =
      [self.inputConverter convertToBuffer:outputBuffer
                                     error:&conversionError
                        withInputFromBlock:^AVAudioBuffer* _Nullable(
                            AVAudioPacketCount packetCount,
                            AVAudioConverterInputStatus* outStatus) {
    if (suppliedInput) {
      *outStatus = AVAudioConverterInputStatus_NoDataNow;
      return nil;
    }
    suppliedInput = YES;
    *outStatus = AVAudioConverterInputStatus_HaveData;
    return inputBuffer;
  }];
  if ((conversionStatus != AVAudioConverterOutputStatus_HaveData &&
       conversionStatus != AVAudioConverterOutputStatus_InputRanDry) ||
      conversionError != nil || outputBuffer.frameLength == 0) {
    atomic_fetch_add(&_conversionFailures, 1);
    return;
  }

  UInt32 frameCount = outputBuffer.frameLength;
  atomic_fetch_add(&_capturedFrames, (uint_fast64_t)frameCount);
  const int16_t* samples = outputBuffer.int16ChannelData == NULL
      ? NULL
      : outputBuffer.int16ChannelData[0];
  if (samples == NULL) {
    atomic_fetch_add(&_conversionFailures, 1);
    return;
  }

  const NSUInteger byteCount =
      (NSUInteger)frameCount * FlutterRTCAudioChannels * sizeof(int16_t);
  NSData* pcmData = [NSData dataWithBytes:samples length:byteCount];
  CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
  uint64_t hostTime = mach_absolute_time();
  Float64 sampleTime = 0;
  AudioTimeStampFlags timestampFlags = kAudioTimeStampHostTimeValid;
  if (CMTIME_IS_VALID(presentationTime) && CMTIME_IS_NUMERIC(presentationTime)) {
    uint64_t presentationHostTime =
        CMClockConvertHostTimeToSystemUnits(presentationTime);
    if (presentationHostTime != 0) {
      hostTime = presentationHostTime;
    }
    Float64 seconds = CMTimeGetSeconds(presentationTime);
    if (isfinite(seconds) && seconds >= 0) {
      sampleTime = seconds * FlutterRTCAudioSampleRate;
      timestampFlags |= kAudioTimeStampSampleTimeValid;
    }
  }
  if (_lastCaptureHostTime != 0 && hostTime <= _lastCaptureHostTime) {
    atomic_fetch_add(&_timestampDiscontinuities, 1);
    hostTime = _lastCaptureHostTime + 1;
  }
  _lastCaptureHostTime = hostTime;

  AudioTimeStamp timestamp = {0};
  timestamp.mFlags = timestampFlags;
  timestamp.mHostTime = hostTime;
  timestamp.mSampleTime = sampleTime;
  AudioUnitRenderActionFlags actionFlags = 0;
  RTCAudioDeviceRenderRecordedDataBlock renderBlock = ^OSStatus(
      AudioUnitRenderActionFlags* renderActionFlags,
      const AudioTimeStamp* renderTimestamp,
      NSInteger inputBusNumber,
      UInt32 requestedFrameCount,
      AudioBufferList* outputData,
      void* renderContext) {
    if (requestedFrameCount != frameCount || outputData == NULL) {
      return kAudio_ParamError;
    }
    const int16_t* interleaved = (const int16_t*)pcmData.bytes;
    if (outputData->mNumberBuffers == 1) {
      AudioBuffer* buffer = &outputData->mBuffers[0];
      if (buffer->mData == NULL || buffer->mDataByteSize < byteCount) {
        return kAudio_ParamError;
      }
      memcpy(buffer->mData, interleaved, byteCount);
      buffer->mNumberChannels = FlutterRTCAudioChannels;
      buffer->mDataByteSize = (UInt32)byteCount;
      return noErr;
    }
    if (outputData->mNumberBuffers == FlutterRTCAudioChannels) {
      for (UInt32 channel = 0; channel < FlutterRTCAudioChannels; channel += 1) {
        AudioBuffer* buffer = &outputData->mBuffers[channel];
        NSUInteger channelBytes = (NSUInteger)frameCount * sizeof(int16_t);
        if (buffer->mData == NULL || buffer->mDataByteSize < channelBytes) {
          return kAudio_ParamError;
        }
        int16_t* destination = (int16_t*)buffer->mData;
        for (UInt32 frame = 0; frame < frameCount; frame += 1) {
          destination[frame] =
              interleaved[(frame * FlutterRTCAudioChannels) + channel];
        }
        buffer->mNumberChannels = 1;
        buffer->mDataByteSize = (UInt32)channelBytes;
      }
      return noErr;
    }
    return kAudio_ParamError;
  };
  id<RTCAudioDeviceDelegate> delegate = self.delegate;
  if (delegate == nil) return;
  RTCAudioDeviceDeliverRecordedDataBlock deliver = delegate.deliverRecordedData;
  OSStatus deliveryStatus = deliver(&actionFlags,
                                    &timestamp,
                                    0,
                                    frameCount,
                                    nil,
                                    NULL,
                                    renderBlock);
  if (deliveryStatus == noErr) {
    atomic_fetch_add(&_deliveredFrames, (uint_fast64_t)frameCount);
  } else {
    atomic_fetch_add(&_deliveryFailures, 1);
  }
}

- (NSDictionary<NSString*, id>*)backendInfo {
  return @{
    @"backend" : @"screen-capture-kit-external-adm",
    @"version" : @4,
    @"microphoneFree" : @YES,
    @"deliveryMode" : @"capture-clock-render-block",
    @"captureOwner" : @"unified-screen-stream",
    @"sampleRate" : @((NSInteger)FlutterRTCAudioSampleRate),
    @"channels" : @(FlutterRTCAudioChannels),
    @"sourceAttached" : @(self.isSystemAudioSourceAttached),
    @"capturedFrames" : @(atomic_load(&_capturedFrames)),
    @"deliveredFrames" : @(atomic_load(&_deliveredFrames)),
    @"conversionFailures" : @(atomic_load(&_conversionFailures)),
    @"deliveryFailures" : @(atomic_load(&_deliveryFailures)),
    @"timestampDiscontinuities" : @(atomic_load(&_timestampDiscontinuities)),
    @"frameDurationMs" : @10,
    @"prebufferMs" : @0,
    @"ringCapacityMs" : @0,
  };
}

@end

#endif
