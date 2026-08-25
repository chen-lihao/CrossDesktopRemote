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
4. 打开“系统完整键盘”，确认底部出现“Windows 文字输入”且输入框获得光标，再切换微软拼音。
5. 输入 `nihao`并选择“你好”；组合期间标签应显示“微软拼音组合中”，Mac 不应收到 `nihao`，选词提交后只出现一次“你好”。
6. 保持系统键盘栏打开，在远程画面中单击后继续输入拼音；文本输入焦点不应被远程鼠标操作抢走。
7. 在候选框中使用 Backspace、方向键、空格和 Enter，候选操作应留在 Windows 本地，提交后才发送。
8. 切换到“快捷小键盘”后验证 `Ctrl+C/V/A/Z`；文字模式和物理快捷键模式不应同时抢占键盘事件。
9. 使用 Alt+Tab 离开并返回，重新激活相应键盘模式；Mac 不应存在卡住的按键。

## 4. 全屏验收

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

## 5. iPad 回归

使用稳定版本相同的 Mac 被控端验证：

- iPad 直接触控和触控板模式；
- 系统完整键盘、快捷小键盘和拼音输入；
- iPad 原有沉浸式全屏；
- 主副屏往返和清晰度切换。

本轮 Windows 代码不应改变 iOS 原生 IME、触控手势或移动端全屏路由。
