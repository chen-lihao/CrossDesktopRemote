# CrossDesktopRemote Flutter Client

该工程由 Flutter 3.47.0 stable 官方 CLI 生成，覆盖 Android、iOS、Linux、macOS 和 Windows。当前已建立设备、会话、设置三个入口和适配手机/平板/桌面的响应式导航壳层，并通过 Dart FFI 调用 Rust 最小 C ABI。

M1 原型已增加项目内维护的 `flutter_webrtc 1.6.x` fork：macOS 与 Windows 可同时保持被控注册和控制会话，iPad 作为移动控制端，通过 Java WebSocket 交换 WebRTC SDP/ICE，视频使用原生 Texture，输入通过版本化 DataChannel 返回被控端。正确的临时连接码会自动授权本次会话；macOS 使用专用事件注入权限 API，并在返回应用后自动刷新状态。会话由应用壳层持有，页面切换和展示窗口关闭不会断开；当前支持应用级消息、适应/填满、全屏、触控板/直接触控、系统输入法、独立分辨率/帧率/码率策略、文本剪贴板、显式文件传输和单窗口多显示器切换。

远程视频展示使用明确的 `RemoteVideoBinding(stream, trackId, generation)`：会话从 `RTCPeerConnection.onTrack` 发布真实轨道身份，展示控制器在 Texture 挂载后请求原生层精确绑定；原生层只有在 Renderer、Stream 和目标 Track 都存在时才确认成功。绑定后 3 秒内未收到首帧和非零尺寸会进入可重试失败态，不会无限显示黑色加载页。“修复当前画面与控制”在 RTP 仍推进时仅验证绑定，不再先解绑 Texture。

macOS 可信设备身份使用 Secure Enclave 中的不可导出 P-256 密钥，密钥对象持久化在默认应用 Keychain access group，私钥不进入 Dart 或普通文件。默认 ad-hoc Debug 构建使用 `CDR_TRUSTED_IDENTITY_MODE=disabled`，仅保留动态连接码；要启用可信身份，复制 `macos/Runner/Configs/DeveloperSigning.xcconfig.example` 为本地 `DeveloperSigning.xcconfig` 并配置稳定 Personal Team/Apple Development 签名。`hardware` 模式会自动切换到专用 Keychain Sharing entitlement；共享 Xcode 工程不保存任何开发者 Team ID。首次使用新的 Bundle ID 时，须在 Xcode 中为 Runner 启用自动签名并构建一次，让 Xcode 创建 Apple Development 证书和 Mac App Development provisioning profile。旧式软件身份只作为迁移标记；身份更换会改变机器码，已有可信关系必须通过动态连接码重新建立。

iPadOS 同样只接受 Secure Enclave v3 身份，不回退到软件私钥。iOS Xcode 构建会通过 `scripts/embed-rust-core-ios.sh` 生成并链接目标架构的 Rust 静态库；首次构建前执行 `rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios`。模拟器只验证编译与 FFI 链接，可信身份必须在稳定签名的 iPad 真机验收。

2026-09-08 验证状态：

- `flutter pub get`：通过。
- `flutter analyze`：通过。
- `flutter test`：常规测试通过；真实 Rust 动态库 FFI 测试在设置 `CROSSDESKTOP_CORE_LIBRARY` 后执行。
- 默认 ad-hoc `flutter build macos --debug`：通过；Personal Team 硬件身份构建需先由本机 Xcode 完成证书与 provisioning profile 初始化。
- `flutter build ios --debug --no-codesign`：通过。
- 精确 Track 绑定、原生绑定失败、有界首帧和非破坏式修复 4 类回归测试：通过。
- `flutter build windows --debug` 及 Windows 打开/关闭、失败重试和修复物理验收：必须在 Windows 11 + MSVC 环境完成，macOS 构建不能替代。

尚未完成 Windows/Linux 最终原生构建、三端多显示器/热插拔和 30 分钟稳定性验收、Android 真机 FFI，以及 macOS Personal Team、iPad Secure Enclave 与 Windows TPM 的跨设备可信直连物理验收。

完整工具链状态见仓库根目录 `docs/工程搭建.md`。视频帧不得进入 Dart 堆；当前 WebRTC 画面由各平台插件的原生 Texture 承载。
