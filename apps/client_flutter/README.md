# CrossDesktopRemote Flutter Client

该工程由 Flutter 3.47.0 stable 官方 CLI 生成，覆盖 Android、iOS、Linux、macOS 和 Windows。当前已建立设备、会话、设置三个入口和适配手机/平板/桌面的响应式导航壳层，并通过 Dart FFI 调用 Rust 最小 C ABI。

2026-08-17 验证状态：

- `flutter pub get`：通过。
- `flutter analyze`：通过。
- `flutter test`：通过，3 个测试成功，包括移动/桌面布局与真实动态库 FFI。
- `flutter build macos --debug`：通过。
- `flutter build ios --simulator --debug`：通过。
- `flutter doctor`：Android SDK 36.0.0、Xcode 26.6、CocoaPods 1.17.0 均通过。
- `flutter build apk --debug`：通过；Debug APK 包含 Android 三个 Rust ABI。本机使用用户级 Settings 仓库镜像适配国内网络，该配置不属于项目运行时依赖。

尚未完成 Windows/Linux 原生构建、Android 真机 FFI 运行以及 macOS 动态库在应用包内的自动嵌入和签名。

完整工具链状态见仓库根目录 `docs/工程搭建.md`。视频帧不得进入 Dart 堆，后续会话画面必须通过原生 Texture 接入。
