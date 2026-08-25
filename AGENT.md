# CrossDesktopRemote Agent Guide

本文件规定在本仓库中工作的开发者和 AI Agent 必须遵守的项目边界。任何实现都应先满足正确性、安全和可验证性，再追求功能数量。

## 1. 开始工作前

按顺序完整阅读：

1. `README.md`
2. `实现方案.md`
3. `可行性分析.md`
4. `项目进展情况.md`
5. 本文件

先运行只读检查确认当前状态：

```bash
git status --short --branch
rg --files
```

仓库当前已完成 M0 工程基线，并进入 M1 Apple 与 M1B Windows 双向原型。开发态连接码已有 5 分钟 TTL、单次消费、每来源限流和客户端租约倒计时/自动轮换，验证后自动建立 WebRTC；Apple 链路的动态画布、输入、采集事务、色彩和自动画质已编码。Windows/macOS控制端已接入桌面直接IME；Windows被控端首轮已实现版本化原生握手、单主屏采集、显示器/DPI枚举、`SendInput`鼠标/扫描码/Unicode输入以及Windows DNS-SD发布/浏览，但新增原生代码仍待Windows + MSVC构建和Mac→Windows实机验证。Windows多显示器、UAC安全桌面和无人值守尚未开放。不得把Mac上的Dart/Apple构建通过表述为Windows原生能力已验收，也不得声称完整远控或生产安全已经完成。

## 2. 固定技术决策

- UI 使用 Flutter/Dart，不引入 Electron 作为客户端框架。
- 客户端共享核心使用 Rust。
- 控制平面使用 Java/Spring Boot，不引入 Go 服务端。
- 实时传输首版使用 WebRTC；传输接口必须允许未来增加 QUIC 实现。
- PostgreSQL 保存事务性业务数据；Redis 保存在线状态、短期票据、限流和跨实例信令路由。
- STUN/TURN 使用独立 coturn，不使用 Java 重写中继数据面。
- 平台原生适配使用 C/C++、Swift、Kotlin 以及必要的系统 API。
- 协议使用 Protobuf 并显式版本化。

除非用户明确修改技术决策，不能擅自切换 Electron、Go、纯 Web 视频渲染、VNC 核心协议或服务端视频转码路线。

## 3. 架构边界

### Flutter

- 负责页面、导航、状态、响应式布局、工具栏和可访问性。
- 不通过 MethodChannel/FFI 逐帧传输 RGBA/YUV 数据。
- 不用 Dart Canvas 重绘实时 2K/4K 视频。
- 不在 UI isolate 执行文件哈希、编解码、网络重传或大文件读写。
- 视频通过原生 Texture/Platform View 显示。
- M1 Apple 原型允许锁定使用 `flutter_webrtc 1.6.x` 缩短单人验证周期；它只能承载原生媒体/传输和小型控制消息，不改变视频帧不得进入 Dart 堆的规则。

### Rust Core

- 负责会话状态机、协议、权限、安全、文件传输、剪贴板、能力协商和传输抽象。
- 所有外部数据都必须有大小、版本、超时和错误边界。
- 跨平台逻辑优先放入 Rust，不在五个平台重复实现。
- FFI 暴露窄 C ABI；明确所有权、线程、回调和销毁顺序。

### 平台原生层

- 只处理屏幕、输入、剪贴板、文件选择、密钥存储、系统服务、硬件编解码和原生纹理。
- Windows：DXGI/Windows Graphics Capture、`SendInput`、Service/Session Worker。
- macOS/iOS：ScreenCaptureKit、VideoToolbox、Accessibility、Keychain。
- Linux：PipeWire/XDG Portal、X11、VA-API/NVENC 等。
- Android：MediaProjection、MediaCodec、AccessibilityService、Keystore。
- 高权限进程不解析不可信视频、图片、压缩包或复杂远端文件内容。

### Java 控制平面

- 负责身份、设备、会话授权、WebSocket 信令、策略和审计。
- 不采集、解密、转码或正常转发远程桌面视频。
- WebSocket 事件循环不得直接执行阻塞数据库/对象存储调用。
- 所有消息、发送队列、连接、租户和调用频率必须有限额。
- 在线心跳不逐条写 PostgreSQL；使用 Redis TTL/租约。
- coturn 凭据必须短期化，TURN 只能转发端到端加密数据。

## 4. 产品与平台边界

- 首版：PC 完整被控端 + 全平台控制端。
- Android 被控必须遵守每次捕获授权和前台提示。
- iOS/iPadOS 不得宣传通用系统输入或无人值守。
- Linux Wayland 能力按 Portal/桌面环境实际支持标注。
- 4K30/60 只能通过 capability 和硬件白名单开放。
- 不允许隐藏共享状态、绕过系统权限或实现无感监控。

## 5. 安全红线

- 临时辅助码不能单独作为端到端媒体密钥。
- 无人值守不使用云端可逆永久密码作为默认认证。
- 会话 Offer/Answer、权限、有效期、随机数和 DTLS fingerprint 必须绑定设备身份。
- 文件传输必须防路径穿越、符号链接越界、磁盘占满和校验失败。
- 日志不得记录具体按键、剪贴板正文、屏幕帧、文件块、密码、token 或私钥。
- 截图、录像、剪贴板和文件方向必须是独立权限。
- 高权限 Agent 与用户进程使用经过身份验证的本机 IPC。
- 安装包、自动更新清单和高权限二进制必须签名。
- 新依赖必须检查许可证、维护状态和供应链风险，并更新 SBOM。

## 6. 性能规则

- MVP 基线是 1080p60；局域网输入到画面 P95 ≤ 60ms。
- 采集、编码、网络、解码和渲染分别打点，不用一个模糊“延迟”数字。
- 视频队列必须有界，默认保留最新帧，禁止累积旧帧提高延迟。
- 目标路径：GPU capture surface → GPU 预处理 → 硬编 → WebRTC → 硬解 → GPU texture。
- 输入/控制优先级高于音频、视频和文件。
- 文件传输不能挤占实时控制；必须支持背压和限速。
- 任何 2K/4K 优化都不能以破坏 1080p60 稳定性为代价。

## 7. 代码与目录规则

目标目录边界：

- `apps/client_flutter`：Flutter UI。
- `crates/*`：Rust 共享核心。
- `platform/*`：平台原生适配。
- `services/control-plane-java`：Java 控制平面。
- `proto`：唯一协议源文件。
- `infra`：coturn、可观测性和部署。
- `tests`：互操作、网络与性能实验。

规则：

- 搜索文件和文本优先使用 `rg`/`rg --files`。
- 修改文件使用小而可审阅的补丁，避免无关格式化。
- 不覆盖用户的既有改动；遇到冲突先说明。
- 生成代码与构建产物不得手工编辑，必须由工具重新生成。
- Flutter、Rust 和 Spring Boot 骨架分别通过 `scripts/bootstrap-flutter.sh`、`scripts/bootstrap-rust.sh`、`scripts/bootstrap-spring.sh` 生成；不得手写替代框架生成物。
- 协议变更必须说明兼容性、版本和旧客户端行为。
- `proto/` 是跨语言协议唯一来源；不得手工修改 `build/generated` 下的 Java/Dart/Rust 生成物。
- 本机全量门禁优先运行 `scripts/check-all.sh`；只改文档时至少运行 `git diff --check`。
- 架构决策变化同步修改两份方案、README 和进展日志。

## 8. 测试与完成定义

每次变更应按风险选择验证：

- Dart/Flutter：format、analyze、unit/widget test、目标平台 build。
- Rust：fmt、clippy、unit/integration test，协议和文件解析增加 fuzz/property test。
- Java：format/checkstyle、unit/integration test、数据库迁移、WebSocket 压测。
- Native：目标系统编译、权限、热插拔、设备重置和内存/线程检查。
- 局域网发现：业务层仅依赖 `LanDiscoveryService`；平台层使用 DNS-SD/mDNS 系统 API，不允许子网扫描或在 TXT 中发布凭据。
- 协议：新旧版本互操作、大小限制、错误输入和超时。
- 性能：记录硬件、OS、驱动、网络、内容、码率和各阶段指标。

若命令或工程尚不存在，明确写“未建立/未运行”，不能用计划命令冒充验证结果。

完成一个任务至少需要：

1. 代码或文档已落盘。
2. 相关验证已运行并记录结果；无法运行时说明原因。
3. `项目进展情况.md` 已更新。
4. 没有引入未说明的安全、许可或平台范围变化。

## 9. Git 规则

- 默认分支使用 `main`。
- 未经用户明确要求，不执行 `git commit` 或 `git push`。
- 提交前先展示变更摘要、测试结果和将被提交的文件。
- commit message 使用简洁英文。
- 未经明确许可，不执行 `git rebase`、`git reset --hard`、强制推送或改写历史。
- 不删除文件、目录或 Git 历史，除非用户明确批准。
- 不把 `.env`、密钥、token、证书、私钥、录屏或真实用户数据提交到 Git。
- 不提交编译产物、依赖缓存、日志、崩溃转储或性能测试原始敏感数据。
- 每次工作结束运行：

```bash
git status --short --branch
git diff --check
```

## 10. 进展记录

- 每个工作日更新 `项目进展情况.md`。
- 开始时记录计划，结束时记录完成、验证、阻塞和下一步。
- 完成项附相关文件、命令或 commit hash。
- 没有验证的事项不能标记 `[x]`。
- 新风险加入风险表，解决后保留历史并标记关闭。

## 11. 沟通方式

- 默认中文回复；代码、命令、变量名和路径保持英文。
- 结论先行，简洁直接，不以恭维开头。
- 发现方案不可行、性能口径错误或安全风险时直接指出。
- 不为了表现进度而伪造构建、测试、性能或平台支持结果。

## 12. 上下文管理

上下文达到70%左右时应进行上下文自动压缩
