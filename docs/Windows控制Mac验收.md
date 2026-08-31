# Windows 控制 Mac 验收

## 1. 范围

本轮只验证 Windows 作为控制端、Mac 作为被控端：

- Windows 物理键盘和系统输入法；
- Windows 原生无边框全屏；
- 全屏前后 WebRTC 会话、Renderer 和 Texture 保持；
- iPad 控制链路不受影响。

Windows 被控端采集和 `SendInput` 不在本轮范围内。

## 2. 构建

在 Windows PowerShell 执行：

```powershell
cd apps\client_flutter
flutter clean
flutter pub get
flutter analyze
flutter test
flutter build windows --debug
flutter run -d windows -v
```

若 C++ 编译失败，保留 Visual Studio/MSBuild 的第一条错误，不要只截取最后的
`Build process failed`。

## 3. 键盘验收

1. 连接 Mac 后在远程画面内单击一次，不打开远程键盘栏，依次输入英文、数字和符号。
2. 验证 Backspace、Delete、Enter、Tab、方向键和 F1～F12。
3. 验证按住按键产生重复输入，松开后立即停止。
4. 不打开“系统完整键盘”，切换微软拼音并直接在远程画面输入 `nihao`、选择“你好”；Mac 不应收到 `nihao`，选词提交后只出现一次“你好”。
5. 确认应用内不显示文本输入框，微软拼音候选窗口出现在最近一次远程点击位置附近且未超出窗口。
6. 在候选框中使用 Backspace、方向键、数字、空格和 Enter，候选操作应留在 Windows 本地，提交后才发送。
7. 连续输入100句中文，确认无重复、漏字、拉丁尾串；组合取消后Mac不出现残留拼音。
8. 直接验证`Ctrl+C/V/A/Z`和`Alt`/`Win`常用组合；文字输入与物理快捷键通道不能重复发送同一按键。
9. 使用Backspace、Delete、方向键移动远端光标后继续拼音，确认只影响远端当前位置，不产生本地历史差分误删。
10. 打开“系统完整键盘”，确认其显示为“Windows兼容文本输入”，第三方输入法仍可通过此入口发送。
11. 使用 Alt+Tab 离开并返回，再单击远程画面继续拼音；Mac 不应存在卡住的按键或残留组合态。

## 4. 鼠标验收

1. 使用 Windows 系统当前的双击速度，在 Mac 窗口标题栏、Finder 文件和文本单词上连续双击 30 次。
2. 每次第二个真实按下/抬起事件应携带 `clickCount=2`；不得延迟第一次单击，也不得额外伪造第三次点击。
3. 单击、右键、按住拖动和跨显示器切换后第一次点击继续正常。
4. 通过标准：30 次双击均被 Mac 识别，拖选不误触发双击；iPad 原有触控双击回归通过。
5. 在 Finder 按住左键框选多份文件，在文本编辑器按住左键跨行选字各 30 次；Windows 本地 IME 焦点变化不得使远端左键提前抬起。
6. 按住 `Ctrl` 单击 Finder 多个离散文件，Mac 应按 `Command` 语义多选；松开后不得残留 Command 状态。

## 5. 全屏验收

1. 记录连接后的画面、显示器名称和清晰度。
2. 进入全屏，确认 Windows 标题栏和应用导航消失，但连接和画面不中断。
3. 按 Esc 退出全屏。
4. 连续进入/退出 30 次；不得出现应用退出、黑屏、重连或画面尺寸永久异常。
5. 全屏期间切换清晰度和主副屏；结束后直接触控坐标仍与画面一致。
6. 断开远程连接时如果仍在全屏，应自动恢复普通窗口。

通过标准：

- `flutter run` 不再出现因全屏导致的 `Service protocol connection closed`；
- 全屏前后使用同一个会话和 Renderer，不创建新的 PeerConnection；
- 30 次全屏往返成功率 100%；
- 连续输入 10 分钟无重复、漏键或按键卡住。
- 微软拼音无需可见输入框即可提交中文，连续100句无拼音尾串、重复或误删。

## 6. iPad 回归

使用稳定版本相同的 Mac 被控端验证：

- iPad 直接触控和触控板模式；
- 系统完整键盘、快捷小键盘和拼音输入；
- iPad 原有沉浸式全屏；
- 主副屏往返和清晰度切换。

本轮 Windows 代码不应改变 iOS 原生 IME、触控手势或移动端全屏路由。
