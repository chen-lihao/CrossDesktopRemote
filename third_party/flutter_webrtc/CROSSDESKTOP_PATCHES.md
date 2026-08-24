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
- adapt the unchanged macOS video source to each new width, height, and frame
  rate without rebuilding the sender, changing SSRC, or renegotiating SDP.

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
