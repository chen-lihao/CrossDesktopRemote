# Protocol definitions

该目录是跨语言协议的唯一源文件位置。`crossdesktop.v1` 已定义公共上下文、设备、能力、会话、信令、远程输入/显示器、剪贴板、文件传输和错误码的最小契约。

剪贴板采用“格式清单 → 按需请求 → 分块响应”，连接建立时不会自动同步历史内容。文件传输的元数据与文件块分离；WebRTC 单条消息上限为 16 KiB，逻辑恢复块默认 256 KiB。新能力通过 `ClientCapabilities.clipboard` 和 `ClientCapabilities.transfer` 显式声明；旧客户端缺少字段时按“不支持剪贴板/文件传输”降级，不影响屏幕和输入会话。

生成代码必须由统一命令产生，禁止手写生成后的 Dart、Rust、Java 类：

```bash
CROSSDESKTOP_FLUTTER_BIN=/path/to/flutter/bin ./scripts/generate-proto.sh
```

依赖工具：

```bash
brew install bufbuild/buf/buf
/Volumes/zhiti-1T/Library/flutter/bin/dart pub global activate protoc_plugin
```

Java 与 Dart 输出位于各工程的 `build/generated`，不提交仓库；Rust 由 `prost-build` 在 Cargo `OUT_DIR` 中生成。兼容规则使用 Buf `STANDARD` lint 和 `FILE` breaking policy：字段编号不得复用，删除字段前必须先保留名称与编号，破坏性调整通过新的主版本包发布。
