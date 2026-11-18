# PassVoice

PassVoice 在 macOS 上接收 AI Passport 的 BLE 语音，把音频送入 BlackHole 2ch。豆包输入法从 BlackHole 收音并在当前光标处提交文字。

## 菜单栏 App

双击 `dist/PassVoice.app` 启动 PassVoice。首次使用时，在菜单栏的波形图标下选择「选择 Passport」，然后选择设备。App 会记住所选设备，下次启动时自动连接。看到「已连接」后，聚焦输入框并单击 Passport 的 **UP** 开始说话，再单击一次结束。

- 在豆包的「语音输入」设置中，把麦克风选为 **BlackHole 2ch**，把「免按模式」设为**右 Option**，并在输入框使用豆包输入法。
- 在 Passport 与 Vokie 已连接时，先退出 Vokie。若 macOS 提示访问蓝牙，请允许 PassVoice。通过菜单里的「授权辅助功能」给 PassVoice 模拟语音快捷键的权限。
- 若菜单显示「授权输入监控」，请允许 PassVoice 检查语音提交和后续编辑。PassVoice 不记录按键。暂存的回车需要确认豆包已在原输入框提交文字。删除上一段语音输入还需要确认这段文字在后续编辑中仍然保留。
- 勾选「登录时启动」后，PassVoice 会在你下次登录 macOS 时打开。若菜单显示「待批准」，用「打开登录项设置」完成授权。再次点击开关可关闭。

菜单栏 App 需要 macOS 13 或更新版本。安装 Xcode Command Line Tools 后，可在仓库根目录重新构建。

```sh
./scripts/build-app
```

构建产物使用本机临时签名。若重建后系统重新要求辅助功能权限，在系统设置里授权新构建的 App。

## Passport 按键设置

从菜单栏打开「按键设置…」。四个手势都可以选择「回车」「退格」「删除上一段语音输入」「不执行」，也可以点击「录入快捷键…」并按下所需组合键。修改立即生效，App 重启后保留，多台 Passport 共用同一套绑定。点击「恢复默认设置」重置四项。

| 按键 | 短按 | 长按（650 ms） |
| --- | --- | --- |
| DOWN | 回车 | 不执行 |
| OK | 退格 | 删除上一段语音输入 |

支持 BLE V1 的旧固件仍可连接，PassVoice 会处理设备已上报的手势。应用下面的补丁可启用 DOWN 长按及 UP 独占录音控制。录音期间按 DOWN 或 OK 会被忽略。

蓝牙音频处理完毕后可再次按 UP 录音。如果此前的语音仍可能在同一输入框提交，PassVoice 会继续录音，并停用这次的暂存回车和语音删除。系统合并的编辑或输入法组合文字如果无法确认语音范围，长按 OK 会保留整段文字。

## 构建配套固件

在 PassVoice 仓库根目录运行以下命令，用 ESP-IDF 5.5.3 构建并验证固件。

```sh
passvoice_repo=$PWD
git clone https://github.com/CandySunPlus/vokie-ai-passport-firmware.git ../vokie-ai-passport-firmware
cd ../vokie-ai-passport-firmware
git checkout --detach 0e3543259f578f5d5678a58edecca5c8bb81e927
git am "$passvoice_repo/firmware/0001-passvoice-up-only.patch" \
  "$passvoice_repo/firmware/0002-passvoice-down-hold.patch" \
  "$passvoice_repo/firmware/0003-passvoice-deliver-gestures-from-worker.patch" \
  "$passvoice_repo/firmware/0004-passvoice-resume-audio-link.patch"
. /path/to/esp-idf-v5.5.3/export.sh
./tools/validate.sh
```

固件保留空闲 20 秒后的 90–120 ms 低功耗 BLE 间隔。编辑按键唤醒后，若连接已满足空闲间隔，就不再重复请求更新；下次 UP 会恢复 15 ms 音频间隔，避免冗余更新阻塞后出现 `Slow BLE`。

验证通过后，可用 AI Passport 小程序安装生成的 `build/FoloToy-AI-Passport-full.bin`。 [固件安装与分区约定](https://github.com/CandySunPlus/vokie-ai-passport-firmware/blob/0e3543259f578f5d5678a58edecca5c8bb81e927/docs/development/engineering/ble-recovery-compatibility.zh_CN.md)

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

运行 `./scripts/test` 可验证按键绑定、文字确认与删除、握手、会话顺序、尾帧和重连逻辑。

- 连接后空闲至少 20 秒，短按 DOWN、OK 等编辑按键，再空闲至少 20 秒。按 UP 开始说话，检查没有出现 `Slow BLE`，再次按 UP 后文字正常提交。再空闲并重复一次，检查低功耗待机后仍可开始录音。
- 对同一设备做两次 `UP → 说话 → UP`。检查文字是否出现在光标处，每次说话的首尾是否完整。
- 空闲时短按 DOWN，检查是否收到一次回车。用 UP 停止较长的语音后立即短按 DOWN，检查是否先落字，再收到一次回车。在等待期间切换到另一个输入框，检查新输入框没有收到回车。
- 空闲时短按 OK，检查是否退格一次。长按 DOWN，检查默认不执行。分别修改四个手势的绑定，检查每次按压只执行对应动作一次。录音时重复四种手势，再按 UP 结束，检查录音完整且手势未执行。恢复默认设置后复查四种手势。
- 在同一个输入框先输入 A，再用 Passport 说 B。等 B 落地后手打 C，长按 OK，检查剩下 A 和 C。再次长按或切换到另一个输入框后长按，检查文字没有变化。
- 确认语音 B 落地后，手动删除 B 并重新打出相同文字。长按 OK，检查手打的 B 保留。
- 在录音过程中断开设备，连接恢复后再做一次完整语音输入。检查桥接日志是否再次出现 `Passport ready`。
- 使用 `--manual --verbose` 分开验证音频与快捷键。先用 Mac 的物理快捷键启动豆包语音，再按 UP 开始采集。说完按 UP，看到 `drained` 日志后，再用物理快捷键结束。日志会记录会话 ID 和音频帧序号。

## 协议与来源

桥接以固件 `0e354325` 为基线。Swift helper 在设备确认收到 `host_ready` 后通知菜单更新连接状态，IMA ADPCM 解码器从上游实现移植。[BLE V1 协议](https://github.com/CandySunPlus/vokie-ai-passport-firmware/blob/0e3543259f578f5d5678a58edecca5c8bb81e927/docs/ai-passport-ble-protocol.zh_CN.md) · [Swift helper](https://github.com/CandySunPlus/vokie-ai-passport-firmware/blob/0e3543259f578f5d5678a58edecca5c8bb81e927/vokie-plugin/helper/AiPassportHelper.swift) · [FoloToy MIT 许可](Sources/PassportHelper/LICENSE)
