# CrossDesktopRemote flutter_webrtc fork

This directory is a project-local fork of `flutter_webrtc 1.6.0` from
`pub.dev`. The upstream license and notices remain in `LICENSE` and `NOTICE`.

CrossDesktopRemote-specific macOS changes:

- request ScreenCaptureKit SDR output on macOS 15+;
- treat `SCDisplay.width/height` as point dimensions and request real capture
  pixels from `SCContentFilter.contentRect * pointPixelScale` on macOS 14+;
- request ScreenCaptureKit's best capture resolution for Retina and Sidecar,
  with a `CGDisplayPixelsWide/High` fallback on older macOS releases;
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
- expose in-place screen switching on the running track through
  `SCStream.updateConfiguration()` and `SCStream.updateContentFilter()`;
- suppress frame forwarding while the live ScreenCaptureKit configuration and
  filter are changing, then admit only consecutive `.complete` frames whose
  dimensions match the requested target;
- clear each switch canvas to video-range black before rendering the first
  target frames, preventing stale IOSurface regions from leaking across
  displays;
- adapt the unchanged macOS video source to each new width, height, and frame
  rate without rebuilding the sender, changing SSRC, or renegotiating SDP.
- expose capture-level target dimensions and frame-rate updates, so automatic
  quality adaptation reduces ScreenCaptureKit/GPU/encoder work instead of only
  scaling an already oversized RTP frame;
- prefer VideoToolbox-backed H.264 on macOS and wrap the encoder with a
  generation-based force-keyframe coordinator used by display-switch
  transactions;
- report ScreenCaptureKit `contentRect`, `contentScale`, `scaleFactor`, buffer
  dimensions, and capture generation without logging screen pixels.

CrossDesktopRemote-specific iOS renderer changes:

- render native decoder PixelBuffers through Core Image so their real pixel
  range and color attachments are honored;
- use Accelerate/vImage BT.709 video-range conversion for I420 fallback frames
  instead of the matrix-less default helper;
- emit privacy-safe decoder-output and Flutter-texture-input luma diagnostics;
- never move full video frames into Dart for diagnostics.

Do not patch `~/.pub-cache`. Upgrade by importing a reviewed upstream release
into this directory, reapplying the documented patch, and running every
platform build before changing the dependency lock file.
