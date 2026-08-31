# Windows 被控端首轮验收

## 当前范围

本轮只开放 Windows 11 x64 的有人值守单主屏被控闭环：

- 复用仓库内 `flutter_webrtc` Windows Desktop Capture 发送主屏视频。
- Win32 原生层枚举显示器和 DPI，并用虚拟桌面坐标执行绝对鼠标输入。
- 鼠标、滚轮、右键、双击/拖动使用 `SendInput`。
- 物理键使用 USB HID Usage 对应的扫描码；Unicode 文本使用 `KEYEVENTF_UNICODE`。
- 原生协议握手失败时拒绝开始共享，避免只传画面但无法可靠释放输入状态。
- Windows 默认仍进入“控制其他设备”；需要用户主动切换到“共享本机”。
- Windows 等待连接时通过 DNS-SD 发布`_cdrremote._tcp.local`，控制端也可浏览同类型 Mac 服务；连接码不进入 TXT 记录，手动地址永久保留。

本轮暂不开放 Windows 多显示器切换、管理员/UAC 安全桌面控制和无人值守服务。普通权限进程受 UIPI 限制，无法向更高完整性进程注入输入，这是 Windows 的系统安全边界，不通过长期以管理员身份运行 Flutter 应用绕过。

## Windows 构建

在 Windows 11、Visual Studio 2022（使用 C++ 的桌面开发）和 Windows 11 SDK 环境执行：

```powershell
cd apps\client_flutter
flutter clean
flutter pub get
flutter analyze
flutter test
flutter build windows --debug
```

必须以 MSVC 首条编译或链接错误为准修复；macOS 上的 Apple 构建不能替代 Windows Runner 验证。

## 启动步骤

1. 在 Windows 本机启动 Java 信令服务，或填写局域网内可访问的 Java 信令地址。
2. 启动 Windows Debug 应用，切换到“共享本机”，点击“开始共享本机”。
3. 确认页面只公布一个主显示器，生成六位连接码。
4. 在 Mac 控制端输入 Windows 的局域网 WebSocket 地址与连接码。
5. 正确连接码应直接建立会话，不要求 Windows 再次确认。
6. 同网段下先确认 Mac“附近设备”能看到 Windows，再反向确认 Windows 能看到等待连接的 Mac；失败时仍可用手动地址连接。

## 首轮检查

- Windows 主屏以正确宽高比显示；适应/填满模式均无额外裁切或偏移。
- 直接触控/绝对鼠标九宫格中心误差不超过 3 个逻辑像素，边缘误差不超过 0.5%。
- 相对移动、左键、右键、双击、拖选、垂直和水平滚动正常。
- Mac端按住左键框选多份文件、跨行选择文字各30次，焦点/输入法变化不应提前释放Windows左键；按住`Command`点击时按Windows `Ctrl`语义多选。
- 英文、数字、符号、中文、退格、Enter、Tab、方向键、F1～F12 正常。
- Mac 控制端无需打开“全局键盘”文本框即可使用系统拼音；组合态只留在 Mac，选词后 Windows 仅收到一次已提交中文。
- `Ctrl+C/V/A`、`Alt+Tab`、`Win` 组合键完整且松开后无粘键。
- 主动断开、对端退出和应用关闭后，所有合成按键及鼠标按钮均被释放。
- 1080p30 连续运行 30 分钟，无黑屏、输入卡死和持续积帧。
- 对 CrossDesktopRemote 窗口连续执行最小化/恢复、最大化/还原、拖动改尺寸各 30 次；Flutter 子窗口不得进入永久 `0×0`，远端画面应在 800ms 左右自行推进，不依赖 Windows 本机移动鼠标。
- 若窗口重绘后编码帧仍未推进，应用应保留 PeerConnection、Sender 和 DataChannel，仅为当前显示器建立新采集轨道并在首批发送帧后释放旧轨道；失败时回滚旧轨道。
- 手动“刷新当前画面”在 Windows 不支持显式关键帧请求时应执行同一采集热重启，不刷新连接码、不重连信令。
- 尝试控制管理员窗口时显示能力受限提示；普通窗口继续可控。
- Windows↔Mac服务在5秒内出现，停止共享后5秒内移除；重复刷新、网络切换和应用退出无崩溃，手动地址不受发现失败影响。

## 进入下一阶段的条件

Windows Debug 原生构建通过且上述单屏闭环稳定后，才进入多显示器事务：建立目标采集流、目标首帧就绪、同一 Sender `replaceTrack()`、控制端提交几何、成功后释放旧流。画质调整只作用于 Sender，并在切屏事务期间采用 last-write-wins 延后应用。
