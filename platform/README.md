# Platform adapters

平台层仅承载系统 API、硬件媒体、高权限组件和原生纹理适配：

| 目录 | 首批适配范围 |
| --- | --- |
| `windows` | DXGI/Windows Graphics Capture、硬编、输入、Service/Session Worker |
| `macos` | ScreenCaptureKit、VideoToolbox、Accessibility、Keychain |
| `linux` | PipeWire/XDG Portal、X11、硬件编解码 |
| `android` | MediaProjection、MediaCodec、Keystore、受限输入 |
| `ios` | 控制端媒体显示、ReplayKit 只读共享、Keychain |

具体工程必须使用各平台官方工具创建，例如 CMake、Xcode、Gradle/Android Studio；当前只建立目录边界。
