# Bootstrap scripts

| 脚本 | 作用 | 是否已在当前机器执行 |
| --- | --- | --- |
| `check-toolchains.sh` | 检查核心与生成工具 | 是 |
| `bootstrap-spring.sh` | 调用 Spring Initializr 生成控制平面 | 等价命令已执行，脚本用于复现 |
| `bootstrap-flutter.sh` | 调用 `flutter create` 生成五平台客户端 | 是；测试、macOS Debug 和 Android Debug APK 构建通过 |
| `bootstrap-rust.sh` | 调用 `cargo init` 生成核心 crate 与 workspace | 是；当前 workspace 共六个 crate，fmt/Clippy/test 通过 |
| `build-rust-core.sh` | 构建当前主机的 Rust C ABI 动态库 | 是，macOS dylib 与 Flutter FFI 测试通过 |
| `build-rust-core-android.sh` | 使用 cargo-ndk 构建 Android 三个 ABI 的 Rust 动态库 | 是，三个 `.so` 已打包进 Debug APK |
| `generate-proto.sh` | 生成 Java、Dart、Rust Protobuf v1 绑定 | 是，三语言检查通过 |
| `dev-up.sh` | 启动并等待 PostgreSQL、Redis、coturn 健康 | 是，三个服务健康 |
| `check-all.sh` | 执行 infra、Proto、Rust、Java、Flutter 基线验收 | 是，全流程通过 |

所有脚本都应从仓库内执行，并在目标工程已存在时停止或跳过，避免覆盖已有实现。

完整验收示例：

```bash
CROSSDESKTOP_FLUTTER_BIN=/path/to/flutter/bin \
CROSSDESKTOP_ANDROID_NDK_HOME=/path/to/android-ndk \
  ./scripts/check-all.sh
```
