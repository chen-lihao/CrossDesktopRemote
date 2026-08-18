# CrossDesktopRemote flutter_webrtc fork

This directory is a project-local fork of `flutter_webrtc 1.6.0` from
`pub.dev`. The upstream license and notices remain in `LICENSE` and `NOTICE`.

CrossDesktopRemote-specific macOS changes:

- request ScreenCaptureKit SDR output on macOS 15+;
- use video-range NV12 (`420v`) instead of unlabelled full-range NV12;
- request an ITU-R BT.709 color space and YCbCr matrix;
- propagate BT.709 primaries, transfer function, and matrix attachments;
- emit one privacy-safe color-diagnostics notification per capture stream.

Do not patch `~/.pub-cache`. Upgrade by importing a reviewed upstream release
into this directory, reapplying the documented patch, and running every
platform build before changing the dependency lock file.
