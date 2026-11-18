# PassVoice

PassVoice 在 macOS 上接收 AI Passport 的 BLE 语音，把音频送入 BlackHole 2ch。豆包输入法从 BlackHole 收音并在当前光标处提交文字。

## 菜单栏 App

双击 `dist/PassVoice.app` 启动 PassVoice。首次使用时，点击菜单栏中带文字光标的声波图标，打开「选择 Passport」并选择设备。App 会记住所选设备，下次启动时自动连接。看到「已连接」后，聚焦输入框并单击 Passport 的 **UP** 开始说话，再单击一次结束。

- 在豆包的「语音输入」设置中，把麦克风选为 **BlackHole 2ch**，把「免按模式」设为**右 Option**，并在输入框使用豆包输入法。
- 在 Passport 与 Vokie 已连接时，先退出 Vokie。若 macOS 提示访问蓝牙，请允许 PassVoice。通过菜单里的「授权辅助功能」给 PassVoice 模拟语音快捷键的权限。
- 若菜单显示「授权输入监控」，请允许 PassVoice 检查语音提交和后续编辑。PassVoice 不记录按键。暂存的回车需要确认豆包已在原输入框提交文字。删除上一段语音输入还需要确认这段文字在后续编辑中仍然保留。
- 勾选「登录时启动」后，PassVoice 会在你下次登录 macOS 时打开。若菜单显示「待批准」，用「打开登录项设置」完成授权。再次点击开关可关闭。

菜单栏 App 需要 macOS 13 或更新版本。安装 Xcode Command Line Tools 后，可在仓库根目录重新构建。

```sh
./scripts/build-app
```

构建默认使用临时签名。要让本机更新沿用辅助功能和输入监控授权，在登录钥匙串配置代码签名身份，并把证书指纹或签名身份名称写入 `app/.local-signing-identity`。构建会用该身份签名 App 和蓝牙辅助进程。用 `PASSVOICE_SIGN_IDENTITY` 可为单次构建指定身份。首次从临时签名切换到固定签名后，在系统设置里重新授权一次。

## Passport 按键设置

从菜单栏打开「按键设置…」。四个手势都可以选择「回车」「退格」「删除上一段语音输入」「不执行」。点每行右侧的键盘图标录入快捷键，点右上角的回转箭头恢复默认设置。修改立即生效，App 重启后保留，多台 Passport 共用同一套绑定。

| 按键 | 短按 | 长按（650 ms） |
| --- | --- | --- |
| DOWN | 回车 | 不执行 |
| OK | 退格 | 删除上一段语音输入 |

支持 BLE V1 的旧固件仍可连接，PassVoice 会处理设备已上报的手势。安装配套固件后，录音中长按 OK 会取消本次语音；按 UP 正常确认后，长按 OK 仍按「按键设置」里的绑定执行，默认删除上一段语音输入。取消会立即停止播放缓冲音频，等豆包停止更新文字后，只移除能定位到本次语音的文字。

蓝牙音频处理完毕后可再次按 UP 录音。如果此前的语音仍可能在同一输入框提交，PassVoice 会继续录音，并停用这次的暂存回车和语音删除。录音时已显示的语音文字，通常要等输入法组合文字结束才能执行暂存回车和语音删除。Codex 输入框无法提供组合文字状态时，长按 OK 仍可删除能唯一定位的语音文字。PassVoice 会等原输入框确认已选中这段文字，再发送退格。编辑合并或范围无法确认时，长按 OK 会保留整段文字。

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
  "$passvoice_repo/firmware/0004-passvoice-resume-audio-link.patch" \
  "$passvoice_repo/firmware/0005-passvoice-wait-for-audio-link.patch" \
  "$passvoice_repo/firmware/0006-passvoice-status-screen.patch" \
  "$passvoice_repo/firmware/0007-passvoice-cancel-voice.patch"
. /path/to/esp-idf-v5.5.3/export.sh
./tools/validate.sh
```

固件保留空闲 20 秒后的 90–120 ms 低功耗 BLE 间隔。编辑按键唤醒后，若连接已满足空闲间隔，就不再重复请求更新；下次 UP 最多等待 3 秒恢复 15 ms 音频间隔，容纳 Mac 实测耗时 1531 ms 的连接更新，避免首次 UP 过早显示 `Slow BLE`。停止采集或断连会提前取消等待。

Passport 屏幕用大字显示连接和录音状态。按下实体键，PassVoice 图标右侧会显示 `VOICE`、`DOWN` 或 `OK`，细线指向相应的实体键。启动时短暂展示三键提示，平时只显示最近按下的一键。该提示在录音和收尾期间保持，空闲后淡出。

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
- 空闲时短按 OK，检查是否退格一次。长按 DOWN，检查默认不执行。分别修改四个手势的绑定，检查每次按压只执行对应动作一次。录音时试短按 OK、短按和长按 DOWN，再按 UP 结束，检查录音完整且手势未执行。恢复默认设置后复查四种手势。
- 在 Codex 和文本编辑中先手打 A，再按 UP 说 B，看到文字后直接长按 OK。检查只剩 A，设备回到 Ready，并且下一次语音可正常开始。
- 在同一个输入框先输入 A，再用 Passport 说 B。等 B 落地后手打 C，长按 OK，检查剩下 A 和 C。再次长按或切换到另一个输入框后长按，检查文字没有变化。
- 确认语音 B 落地后，手动删除 B 并重新打出相同文字。长按 OK，检查手打的 B 保留。
- 在录音过程中断开设备，连接恢复后再做一次完整语音输入。检查桥接日志是否再次出现 `Passport ready`。
- 使用 `--manual --verbose` 分开验证音频与快捷键。先用 Mac 的物理快捷键启动豆包语音，再按 UP 开始采集。说完按 UP，看到 `drained` 日志后，再用物理快捷键结束。日志会记录会话 ID 和音频帧序号。

## 协议与来源

桥接以固件 `0e354325` 为基线。Swift helper 在设备确认收到 `host_ready` 后通知菜单更新连接状态，IMA ADPCM 解码器从上游实现移植。[BLE V1 协议](https://github.com/CandySunPlus/vokie-ai-passport-firmware/blob/0e3543259f578f5d5678a58edecca5c8bb81e927/docs/ai-passport-ble-protocol.zh_CN.md) · [Swift helper](https://github.com/CandySunPlus/vokie-ai-passport-firmware/blob/0e3543259f578f5d5678a58edecca5c8bb81e927/vokie-plugin/helper/AiPassportHelper.swift) · [FoloToy MIT 许可](Sources/PassportHelper/LICENSE)
