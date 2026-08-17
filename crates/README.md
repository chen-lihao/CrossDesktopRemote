# Rust workspace

该目录承载共享客户端核心：

- `client-ffi`：供 Flutter 与平台壳调用的稳定窄 C ABI。
- `session-core`：会话状态机与生命周期。
- `protocol`：协议类型与版本边界。
- `media-core`：媒体管线抽象，不承载 Flutter UI。
- `transfer-core`：文件传输、背压、校验和断点续传。
- `security-core`：设备身份、会话票据和密码学边界。

六个 crate 和根 Cargo workspace 已建立。2026-08-17 实测 `cargo fmt`、Clippy 和 workspace test 全部通过；`session-core` 与 `client-ffi` 已建立最小构建能力查询，`protocol` 已接入 Protobuf，另外三个 crate 已用帧元数据、传输限额和独立权限集合替换生成器示例。它们只定义模块边界，不代表媒体、文件或安全业务已经实现。

FFI 只允许传递小型标量、句柄和有明确所有权的数据，不允许逐帧传递 RGBA/YUV。当前最小 ABI 只暴露 ABI 版本、协议主版本和已编译特性位。

```bash
./scripts/build-rust-core.sh
CROSSDESKTOP_ANDROID_NDK_HOME=/path/to/android-ndk \
  ./scripts/build-rust-core-android.sh
```
