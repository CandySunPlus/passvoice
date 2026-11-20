# PassVoice

PassVoice 在 macOS 上接收 AI Passport 的 BLE 语音，把音频送入 BlackHole 2ch。豆包输入法从 BlackHole 收音，边说边在 PassVoice 的草稿窗口显示文字。确认后，PassVoice 把草稿粘贴到原输入框。

## 菜单栏 App

双击 `dist/PassVoice.app` 启动 PassVoice。首次使用时，点击菜单栏中带文字光标的声波图标，打开「选择 Passport」并选择设备。App 会记住所选设备，下次启动时自动连接。看到「已连接」后，聚焦输入框，单击 Passport 的 **UP** 开始说话，再单击一次把草稿写入原输入框。

- 在豆包的「语音输入」设置中，把麦克风选为 **BlackHole 2ch**，把「免按模式」设为**右 Option**，并在输入框使用豆包输入法。
- 在 Passport 与 Vokie 已连接时，先退出 Vokie。若 macOS 提示访问蓝牙，请允许 PassVoice。通过菜单里的「授权辅助功能」给 PassVoice 模拟语音快捷键的权限。
- 勾选「登录时启动」后，PassVoice 会在你下次登录 macOS 时打开。若菜单显示「待批准」，用「打开登录项设置」完成授权。再次点击开关可关闭。

菜单栏 App 需要 macOS 13 或更新版本。安装 Xcode Command Line Tools 后，可在仓库根目录重新构建。

```sh
./scripts/build-app
```

构建默认使用 `app/signing-identity` 中的证书指纹，为 App 和蓝牙辅助进程签名。换 Mac 时，将含对应证书和私钥的 `.p12` 导入登录钥匙串，再运行构建命令。可以用 `security find-identity -v -p codesigning` 核对指纹。脚本查不到该身份时，会在编译前提示导入。

如需覆盖默认身份，可在本机的 `app/.local-signing-identity` 中填写证书指纹或签名身份名称，也可以用 `PASSVOICE_SIGN_IDENTITY` 为单次构建指定身份。仅做临时构建时，运行 `PASSVOICE_SIGN_IDENTITY=- ./scripts/build-app`。首次从临时签名切换到固定签名后，在系统设置里重新授权一次。

## Passport 按键设置

从菜单栏打开「按键设置…」。四个手势都可以选择「回车」「退格」「撤销（⌘Z）」「不执行」。点每行右侧的键盘图标录入快捷键，点右上角的回转箭头恢复默认设置。修改立即生效，App 重启后保留，多台 Passport 共用同一套绑定。

| 按键 | 短按 | 长按（650 ms） |
| --- | --- | --- |
| DOWN | 回车 | 不执行 |
| OK | 退格 | 撤销（⌘Z） |

支持 BLE V1 的旧固件可以继续连接。使用配套固件时，录音中长按 OK 会停止音频播放、丢弃草稿，并让 Passport 回到 Ready。取消时，文字仍在草稿窗口里，因此原输入框中的文字和选区都保留。

第二次按 UP 确认草稿后，PassVoice 等豆包完成识别，再把文字粘贴到原输入框。如果无法恢复原焦点，本次粘贴会取消。粘贴时会将换行和制表符转换为空格，短按 DOWN 才发送回车。收尾期间按 DOWN 或长按 OK，对应的按键会在粘贴后送到原输入框。默认情况下，长按 OK 发送一次 ⌘Z，具体撤销哪一步由 App 决定。

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

### 构建界面预览固件

安装 CMake 并启动 Docker。将 `PASSVOICE_FIRMWARE_BASE` 指向已安装 `managed_components` 的固件检出目录（默认 `../passvoice-firmware-base`），然后运行：

```sh
./scripts/build-ui-prototypes --firmware
```

本地没有镜像时，Docker 会从 Docker Hub 拉取 `candysunplus/passvoice-idf:v5.5.3-esp32c3`（仅 `linux/arm64`），无需自行构建镜像。打包和校验通过后生成 `dist/ui-prototypes/PassVoice-UI-Preview-full.bin`。

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

保持桥接进程运行，并等到 Passport 屏幕显示 **Ready**。聚焦输入框，按一下 Passport 的 **UP**，说话，再按一下 **UP**。自动模式会在草稿窗口显示文字，等待末尾的音频帧和 BlackHole 播放完成，再确认粘贴。蓝牙断开会丢弃草稿。使用 `--manual` 时，断连后已排队的音频仍可继续播放。

按 Ctrl-C 停止桥接会断开 BLE，Passport 此时显示 **Offline**。重新运行连接命令，等设备显示 **Ready** 后即可继续录音。

## 验收

运行 `./scripts/test` 可验证按键绑定、草稿确认与取消、握手、会话顺序、尾帧和重连逻辑。

- 连接后空闲至少 20 秒，短按 DOWN、OK 等编辑按键，再空闲至少 20 秒。按 UP 开始说话，检查没有出现 `Slow BLE`，再次按 UP 后文字正常提交。再空闲并重复一次，检查低功耗待机后仍可开始录音。
- 对同一设备做两次 `UP → 说话 → UP`。检查文字是否出现在光标处，每次说话的首尾是否完整。
- 空闲时短按 DOWN，检查是否收到一次回车。用 UP 停止较长的语音后立即短按 DOWN，检查是否先落字，再收到一次回车。在等待期间切换到另一个输入框，检查新输入框没有收到回车。
- 空闲时短按 OK，检查是否退格一次。长按 DOWN，检查默认不执行。分别修改四个手势的绑定，检查每次按压只执行对应动作一次。录音时试短按 OK、短按和长按 DOWN，再按 UP 结束，检查录音完整且手势未执行。恢复默认设置后复查四种手势。
- 在文本编辑、Codex、飞书和 Ghostty 中分别手打 A，再按 UP 说 B。检查 B 只出现在草稿窗口。直接长按 OK 后，检查原输入框保留 A、草稿消失、设备回到 Ready，并且下一次语音可正常开始。
- 在同一个输入框先输入 A，再用 Passport 说 B 并按 UP 确认。长按 OK，检查结果与键盘按一次 ⌘Z 一致。在语音收尾时长按 OK 并切换焦点，检查撤销没有发到新的输入区域。
- 在录音过程中断开设备，连接恢复后再做一次完整语音输入。检查桥接日志是否再次出现 `Passport ready`。
- 使用 `--manual --verbose` 分开验证音频与快捷键。先用 Mac 的物理快捷键启动豆包语音，再按 UP 开始采集。说完按 UP，看到 `drained` 日志后，再用物理快捷键结束。日志会记录会话 ID 和音频帧序号。

## 协议与来源

桥接以固件 `0e354325` 为基线。Swift helper 在设备确认收到 `host_ready` 后通知菜单更新连接状态，IMA ADPCM 解码器从上游实现移植。[BLE V1 协议](https://github.com/CandySunPlus/vokie-ai-passport-firmware/blob/0e3543259f578f5d5678a58edecca5c8bb81e927/docs/ai-passport-ble-protocol.zh_CN.md) · [Swift helper](https://github.com/CandySunPlus/vokie-ai-passport-firmware/blob/0e3543259f578f5d5678a58edecca5c8bb81e927/vokie-plugin/helper/AiPassportHelper.swift) · [FoloToy MIT 许可](Sources/PassportHelper/LICENSE)
