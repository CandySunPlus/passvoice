# PassVoice

PassVoice 在 macOS 上接收 AI Passport 的 BLE 语音，把音频送入 BlackHole 2ch。豆包输入法从 BlackHole 收音并在当前光标处提交文字。

## 菜单栏 App

双击 `dist/PassVoice.app` 启动 PassVoice。首次使用时，在菜单栏的波形图标下选择「选择 Passport」，然后选择设备。App 会记住所选设备，下次启动时自动连接。看到「已连接」后，聚焦输入框并单击 Passport 的 **UP** 开始说话，再单击一次结束。

- 在豆包的「语音输入」设置中，把麦克风选为 **BlackHole 2ch**，把「免按模式」设为**右 Option**，并在输入框使用豆包输入法。
- 在 Passport 与 Vokie 已连接时，先退出 Vokie。若 macOS 提示访问蓝牙，请允许 PassVoice。通过菜单里的「授权辅助功能」给 PassVoice 模拟语音快捷键的权限。
- 勾选「登录时启动」后，PassVoice 会在你下次登录 macOS 时打开。若菜单显示「待批准」，用「打开登录项设置」完成授权。再次点击开关可关闭。

菜单栏 App 需要 macOS 13 或更新版本。安装 Xcode Command Line Tools 后，可在仓库根目录重新构建。

```sh
./scripts/build-app
```

构建产物使用本机临时签名。若重建后系统重新要求辅助功能权限，在系统设置里授权新构建的 App。

## 命令行调试

1. 在运行 macOS 12 或更新版本的 Apple Silicon Mac 上安装 Xcode Command Line Tools、BlackHole 2ch 和豆包输入法。
2. 打开豆包输入法的「语音输入」设置，把「麦克风选择」设为 **BlackHole 2ch**，把「免按模式」快捷键设为**右 Option**。在用于验收的输入框里切到豆包输入法。
3. 退出 Vokie 以释放设备连接。唤醒 AI Passport，确保它运行支持 BLE V1 的固件。
4. 在 Terminal 运行下列命令。若系统提示蓝牙访问，允许本次使用的启动程序访问蓝牙。自动模式还需要在「系统设置 → 隐私与安全性 → 辅助功能」中授权启动它的终端。

```sh
swift build -c release
.build/release/passvoice --scan
```

扫描输出 UUID 后按 Ctrl-C。把下面的示例值替换成扫描结果。两个可执行文件 `passvoice` 和 `passport-helper` 需位于同一目录。

```sh
.build/release/passvoice --device 00000000-0000-0000-0000-000000000000
```

保持桥接进程运行，并等到 Passport 屏幕显示 **Ready**。聚焦输入框，按一下 Passport 的 **UP**，说话，再按一下 **UP**。桥接会等待末尾的音频帧和 BlackHole 播放完成，再发送结束快捷键。蓝牙断开时，桥接播放已排入队列的音频，随后让豆包结束已开始的语音输入，并等待设备重连。

按 Ctrl-C 停止桥接会断开 BLE，Passport 此时显示 **Offline**。重新运行连接命令，等设备显示 **Ready** 后即可继续录音。

## 验收

运行 `./scripts/test` 可验证握手、会话顺序、尾帧和重连逻辑。

- 对同一设备做两次 `UP → 说话 → UP`。检查文字是否出现在光标处，每次说话的首尾是否完整。
- 在录音过程中断开设备，连接恢复后再做一次完整语音输入。检查桥接日志是否再次出现 `Passport ready`。
- 使用 `--manual --verbose` 分开验证音频与快捷键。先用 Mac 的物理快捷键启动豆包语音，再按 UP 开始采集。说完按 UP，看到 `drained` 日志后，再用物理快捷键结束。日志会记录会话 ID 和音频帧序号。

## 协议与来源

桥接以固件 `0e354325` 为基线。Swift helper 在设备确认收到 `host_ready` 后通知菜单更新连接状态，IMA ADPCM 解码器从上游实现移植。[BLE V1 协议](https://github.com/CandySunPlus/vokie-ai-passport-firmware/blob/0e3543259f578f5d5678a58edecca5c8bb81e927/docs/ai-passport-ble-protocol.zh_CN.md) · [Swift helper](https://github.com/CandySunPlus/vokie-ai-passport-firmware/blob/0e3543259f578f5d5678a58edecca5c8bb81e927/vokie-plugin/helper/AiPassportHelper.swift) · [FoloToy MIT 许可](Sources/PassportHelper/LICENSE)
