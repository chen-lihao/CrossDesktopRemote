# CrossDesktopRemote Flutter Client

该工程由 Flutter 3.47.0 stable 官方 CLI 生成，覆盖 Android、iOS、Linux、macOS 和 Windows。当前已建立设备、会话、设置三个入口和适配手机/平板/桌面的响应式导航壳层，并通过 Dart FFI 调用 Rust 最小 C ABI。

M1 原型已增加项目内维护的 `flutter_webrtc 1.6.x` fork：macOS 与 Windows 可同时保持被控注册和控制会话，iPad 作为移动控制端，通过 Java WebSocket 交换 WebRTC SDP/ICE，视频使用原生 Texture，输入通过版本化 DataChannel 返回被控端。正确的临时连接码会自动授权本次会话；macOS 使用专用事件注入权限 API，并在返回应用后自动刷新状态。会话由应用壳层持有，页面切换和展示窗口关闭不会断开；当前支持应用级消息、适应/填满、全屏、触控板/直接触控、系统输入法、独立分辨率/帧率/码率策略、文本剪贴板、显式文件传输和单窗口多显示器切换。

远程视频展示使用明确的 `RemoteVideoBinding(stream, trackId, generation)`：会话从 `RTCPeerConnection.onTrack` 发布真实轨道身份，展示控制器在 Texture 挂载后请求原生层精确绑定；原生层只有在 Renderer、Stream 和目标 Track 都存在时才确认成功。绑定后 3 秒内未收到首帧和非零尺寸会进入可重试失败态，不会无限显示黑色加载页。“修复当前画面与控制”在 RTP 仍推进时仅验证绑定，不再先解绑 Texture。

2026-09-08 验证状态：

- `flutter pub get`：通过。
- `flutter analyze`：通过。
- `flutter test`：通过，225 项常规测试成功；1 项真实 Rust 动态库 FFI 测试因未设置 `CROSSDESKTOP_CORE_LIBRARY` 按设计跳过。
- `flutter build macos --debug`：通过。
- `flutter build ios --debug --no-codesign`：通过。
- 精确 Track 绑定、原生绑定失败、有界首帧和非破坏式修复 4 类回归测试：通过。
- `flutter build windows --debug` 及 Windows 打开/关闭、失败重试和修复物理验收：必须在 Windows 11 + MSVC 环境完成，macOS 构建不能替代。

尚未完成 Windows/Linux 最终原生构建、三端多显示器/热插拔和 30 分钟稳定性验收、Android 真机 FFI，以及 macOS Rust 动态库在应用包内的自动嵌入和签名。

完整工具链状态见仓库根目录 `docs/工程搭建.md`。视频帧不得进入 Dart 堆；当前 WebRTC 画面由各平台插件的原生 Texture 承载。
