#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>

#if TARGET_OS_OSX

// WebRTC-SDK 144.7559.09 ships the Objective-C external ADM implementation in
// its macOS binary and exposes RTCPeerConnectionFactory's audioDevice:
// initializer, but accidentally omits RTCAudioDevice.h from the macOS headers.
// Keep the exact public selector contract local and pinned to that binary.
typedef OSStatus (^RTCAudioDeviceGetPlayoutDataBlock)(
    AudioUnitRenderActionFlags* _Nonnull actionFlags,
    const AudioTimeStamp* _Nonnull timestamp,
    NSInteger inputBusNumber,
    UInt32 frameCount,
    AudioBufferList* _Nonnull outputData);

typedef OSStatus (^RTCAudioDeviceRenderRecordedDataBlock)(
    AudioUnitRenderActionFlags* _Nonnull actionFlags,
    const AudioTimeStamp* _Nonnull timestamp,
    NSInteger inputBusNumber,
    UInt32 frameCount,
    AudioBufferList* _Nonnull inputData,
    void* _Nullable renderContext);

typedef OSStatus (^RTCAudioDeviceDeliverRecordedDataBlock)(
    AudioUnitRenderActionFlags* _Nonnull actionFlags,
    const AudioTimeStamp* _Nonnull timestamp,
    NSInteger inputBusNumber,
    UInt32 frameCount,
    const AudioBufferList* _Nullable inputData,
    void* _Nullable renderContext,
    RTCAudioDeviceRenderRecordedDataBlock _Nullable renderBlock);

@protocol RTCAudioDeviceDelegate <NSObject>

@property(readonly, nonnull) RTCAudioDeviceDeliverRecordedDataBlock deliverRecordedData;
@property(readonly) double preferredInputSampleRate;
@property(readonly) NSTimeInterval preferredInputIOBufferDuration;
@property(readonly) double preferredOutputSampleRate;
@property(readonly) NSTimeInterval preferredOutputIOBufferDuration;
@property(readonly, nonnull) RTCAudioDeviceGetPlayoutDataBlock getPlayoutData;

- (void)notifyAudioInputParametersChange;
- (void)notifyAudioOutputParametersChange;
- (void)notifyAudioInputInterrupted;
- (void)notifyAudioOutputInterrupted;
- (void)dispatchAsync:(nonnull dispatch_block_t)block;
- (void)dispatchSync:(nonnull dispatch_block_t)block;

@end

@protocol RTCAudioDevice <NSObject>

@property(readonly) double deviceInputSampleRate;
@property(readonly) NSTimeInterval inputIOBufferDuration;
@property(readonly) NSInteger inputNumberOfChannels;
@property(readonly) NSTimeInterval inputLatency;
@property(readonly) double deviceOutputSampleRate;
@property(readonly) NSTimeInterval outputIOBufferDuration;
@property(readonly) NSInteger outputNumberOfChannels;
@property(readonly) NSTimeInterval outputLatency;
@property(readonly) BOOL isInitialized;
@property(readonly) BOOL isPlayoutInitialized;
@property(readonly) BOOL isPlaying;
@property(readonly) BOOL isRecordingInitialized;
@property(readonly) BOOL isRecording;

- (BOOL)initializeWithDelegate:(nonnull id<RTCAudioDeviceDelegate>)delegate;
- (BOOL)terminateDevice;
- (BOOL)initializePlayout;
- (BOOL)startPlayout;
- (BOOL)stopPlayout;
- (BOOL)initializeRecording;
- (BOOL)startRecording;
- (BOOL)stopRecording;

@end

/// Full-duplex, microphone-free WebRTC audio device for macOS.
///
/// The recording side accepts ScreenCaptureKit system-output samples. The
/// playout side renders ordinary remote WebRTC audio through the default macOS
/// output device, so installing this device cannot regress controller audio.
@interface FlutterRTCExternalAudioDevice : NSObject <RTCAudioDevice>

@property(nonatomic, readonly, getter=isSystemAudioSourceAttached) BOOL systemAudioSourceAttached;

- (void)attachSystemAudioSource;
- (void)detachSystemAudioSource;
- (void)consumeSystemAudioSampleBuffer:(nonnull CMSampleBufferRef)sampleBuffer;
- (nonnull NSDictionary<NSString*, id>*)backendInfo;

@end

#endif
