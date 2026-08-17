# Applications

- `client_flutter`：跨平台控制端与桌面 UI，已通过 `scripts/bootstrap-flutter.sh` 调用 Flutter CLI 生成。
- `admin_web`：可选企业管理控制台，技术栈尚未决策，当前不生成框架工程。

不要手写 Flutter 自动生成的 `android`、`ios`、`linux`、`macos`、`windows`、`pubspec.yaml` 等骨架文件。当前静态分析、Widget 测试和 macOS Debug 构建通过；Android APK 构建仍受 Gradle 仓库/网络影响。
