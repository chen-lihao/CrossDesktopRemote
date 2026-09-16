# CrossDesktopRemote flutter_webrtc fork

This directory is a project-local fork of `flutter_webrtc 1.6.0` from
`pub.dev`. The upstream license and notices remain in `LICENSE` and `NOTICE`.

CrossDesktopRemote-specific macOS changes:

- request ScreenCaptureKit SDR output on macOS 15+;
- treat `SCDisplay.width/height` as point dimensions and request real capture
  pixels from `SCContentFilter.contentRect * pointPixelScale` on macOS 14+;
- request ScreenCaptureKit's best capture resolution for Retina and Sidecar,
  with a `CGDisplayPixelsWide/High` fallback on older macOS releases;
- derive the active pixel region from ScreenCaptureKit `contentRect *
  scaleFactor` metadata instead of assuming that the outer IOSurface is fully
  occupied;
- keep the zero-copy path when active content fills the buffer, otherwise crop
  every valid metadata-defined region and aspect-fill the canonical full-frame
  NV12 canvas before encoding; only the small alignment excess may be cropped,
  so the encoder never receives an internally letterboxed desktop;
- disable ScreenCaptureKit's extra aspect-preserving transform for full-display
  capture on macOS 14+, because the target canvas already comes from the
  selected display geometry;
- preserve the raw ScreenCaptureKit metadata for diagnosis instead of
  relabelling samples;
- pass native SDR/BT.709/video-range NV12 frames directly to WebRTC, and use
  Core Image on Metal only when HDR/range/color metadata requires real pixel
  conversion into Rec.709 video-range NV12 (`420v`);
- attach BT.709 primaries, transfer function, and matrix only after the pixel
  conversion succeeds;
- emit privacy-safe raw-capture and encoder-input luma histograms once per
  stream;
- emit a privacy-safe first-frame notification containing only source ID and
  frame dimensions, so display switching can prove that the requested
  ScreenCaptureKit source is live before committing the WebRTC transaction;
- switch displays with an Active/Pending/Retired ScreenCaptureKit transaction:
  construct a target-bound `SCStream`, promote its first usable post-barrier
  pixel buffer into the existing WebRTC source, and retain the untouched
  previous stream until the controller commits or rolls back;
- keep the RTC track, sender, transceiver, MID, SSRC, and data channels stable
  while the short-lived capture streams overlap;
- retain at most one encoder-ready frame for Active and Retired so rollback is
  immediate even when a static desktop temporarily produces only idle frames;
- reserve `SCStream.updateConfiguration()` for quality/FPS changes on the same
  display; do not use `updateContentFilter()` for Sidecar/main-display changes,
  because WindowServer can acknowledge it while continuing the old surface;
- serialize format updates against display transactions and attach a separate
  format epoch; asynchronous callbacks may update shared geometry only when
  stream identity, source ID, capture generation, and format epoch still match;
- return the applied source ID, capture generation, dimensions, and frame rate
  from each in-place switch/format operation instead of a boolean-only result;
- forward the active stream while a target stream warms, then admit only the
  promoted stream and ignore retained rollback-stream callbacks;
- reject queued pre-switch frames with a generation-local `displayTime`
  barrier; accept usable `.started`, `.complete`, and `.idle` samples, while
  treating missing or aspect-mismatched content metadata as advisory and
  immediately falling back to the full canonical buffer;
- aggregate privacy-safe frame-gate rejection counters for stale timestamps,
  wrong buffer dimensions, missing metadata, aspect mismatch, and failed GPU
  normalization;
- include Pending usable/accepted/stale/geometry/content-aspect/metadata-fallback
  counters, last raw dimensions, expected canonical dimensions, and elapsed
  time in warm-up failures; use an `SCStreamDelegate` error as an immediate
  failure and retain a 5-second maximum Sidecar warm-up window;
- clear each switch canvas to video-range black before rendering the first
  target frames, preventing stale IOSurface regions from leaking across
  displays;
- preconfigure `RTCVideoSource` output width, height, and frame rate before
  forwarding target frames, without rebuilding the sender, changing SSRC, or
  renegotiating SDP;
- keep capture-level target dimensions and frame-rate updates available for a
  future session restart, but keep the active session on one stable capture
  envelope; automatic and manual quality changes adjust only sender bitrate,
  frame-rate and resolution scale, avoiding `SCStream` reconfiguration races
  with display transactions;
- prefer VideoToolbox-backed H.264 on macOS and wrap the encoder with a
  generation-based force-keyframe coordinator used by display-switch
  transactions;
- report ScreenCaptureKit `contentRect`, `contentScale`, `scaleFactor`, buffer
  dimensions, and capture generation without logging screen pixels.
- promote a target-bound stream after its first usable post-barrier frame with
  the exact requested Buffer dimensions; use matching `contentRect` metadata
  for crop/scale, but immediately fall back to the canonical full Buffer when
  Sidecar keeps stale descriptive metadata or a static desktop emits no second
  frame.

CrossDesktopRemote-specific iOS renderer changes:

- render native decoder PixelBuffers through Core Image so their real pixel
  range and color attachments are honored;
- use Accelerate/vImage BT.709 video-range conversion for I420 fallback frames
  instead of the matrix-less default helper;
- emit privacy-safe decoder-output and Flutter-texture-input luma diagnostics;
- never move full video frames into Dart for diagnostics.

CrossDesktopRemote-specific cross-platform renderer binding changes:

- pass the real receiver video track ID from `RTCPeerConnection.onTrack` to
  every Texture binding; never use `"0"` or a track index as a sentinel ID;
- validate that the renderer, media stream, and requested video track exist
  before attaching a native video sink;
- return the actual bound track ID to Dart on success and a structured platform
  error on failure instead of acknowledging an unbound Texture;
- update Dart `srcObject` only after native binding succeeds, so presentation
  state cannot diverge from the native renderer;
- apply the same exact/default-track contract to Windows/Linux C++, Darwin,
  Android, and Web implementations;
- keep presentation repair non-destructive: a healthy Texture may be rebound to
  the same exact track for validation but must not be cleared first.

CrossDesktopRemote-specific desktop system-audio changes:

- expose a session-scoped system-output capture API that remains independent of
  display video tracks and never moves PCM through Dart;
- capture macOS system output with ScreenCaptureKit and feed it into the pinned
  WebRTC binary's external AudioDeviceModule instead of routing it through
  `AVAudioEngine.inputNode` or requesting microphone access;
- normalize ScreenCaptureKit batches to 48 kHz signed 16-bit stereo PCM and
  deliver them with the ScreenCaptureKit presentation clock; let WebRTC's
  FineAudioBuffer produce codec-sized 10 ms blocks instead of introducing a
  second timer, prebuffer or synthetic silence clock;
- keep the external audio device full duplex: its output side pulls WebRTC
  playout through the default macOS AudioUnit, preserving remote audio when a
  Mac acts as the controller;
- publish a versioned, microphone-free runtime backend contract before capture
  starts and fail closed rather than silently falling back to microphone input;
- expose privacy-safe counters for captured, delivered, timestamp-discontinuous,
  conversion-failed and delivery-failed frames;
- configure iOS controller playout as full-band `playback/default` with
  `mixWithOthers`, reference-count it across Flutter views, and notify other
  applications when the final remote session releases the audio session.

Do not patch `~/.pub-cache`. Upgrade by importing a reviewed upstream release
into this directory, reapplying the documented patch, and running every
platform build before changing the dependency lock file.
