# CrossDesktopRemote Flutter Client

该工程由 Flutter 3.47.0 stable 官方 CLI 生成，覆盖 Android、iOS、Linux、macOS 和 Windows。当前已建立设备、会话、设置三个入口和适配手机/平板/桌面的响应式导航壳层，并通过 Dart FFI 调用 Rust 最小 C ABI。

M1 原型已增加 `flutter_webrtc 1.6.x`：Mac 可以在“共享本机”和“控制其他设备”之间切换，iPad 作为移动控制端，通过 Java WebSocket 交换 WebRTC SDP/ICE，视频使用原生渲染视图，输入通过版本化 DataChannel 返回被控端。正确的临时连接码会自动授权本次会话；macOS 使用专用事件注入权限 API，并在返回应用后自动刷新状态。会话由应用壳层持有，页面切换不会断开；当前支持应用级消息提示、适应/填满、沉浸全屏、触控板/直接触控、可见软键盘、720p/1080p/2K/原画档位，以及使用 `replaceTrack()` 切换当前显示器。

2026-08-17 验证状态：

- `flutter pub get`：通过。
- `flutter analyze`：通过。
- `flutter test`：通过，16 个常规测试成功；设置 `CROSSDESKTOP_CORE_LIBRARY` 后另有 1 个真实 Rust 动态库 FFI 测试。
- `flutter build macos --debug`：通过。
- `flutter build ios --simulator --debug`：通过。
- `flutter build ios --debug`：通过物理设备 arm64 自动签名编译。
- 物理 iPad 自动签名、安装和启动：通过。
- `flutter doctor`：Android SDK 36.0.0、Xcode 26.6、CocoaPods 1.17.0 均通过。
- `flutter build apk --debug`：通过；Debug APK 包含 Android 三个 Rust ABI。本机使用用户级 Settings 仓库镜像适配国内网络，该配置不属于项目运行时依赖。

尚未完成新版双设备权限弹窗、触控/键盘、动态清晰度、多块物理显示器、热插拔和 30 分钟稳定性验收，也未完成 Windows/Linux 原生构建、Android 真机 FFI，以及 macOS Rust 动态库在应用包内的自动嵌入和签名。

完整工具链状态见仓库根目录 `docs/工程搭建.md`。视频帧不得进入 Dart 堆；当前 WebRTC 画面由插件的 Apple 原生视频视图承载。
