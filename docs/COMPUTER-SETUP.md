# 电脑安装与语音配置

手机 0.6.8，电脑连接器 0.3.8。命令在电脑终端运行。连接器安装脚本和软件包统一从 GitHub 获取。

## 准备 Hermes

需要 Python 3.11+，并在电脑安装、配置 [Hermes Agent](https://hermes-agent.nousresearch.com/docs/getting-started/installation)，先确认文字对话可用。模型与语音提供方密钥由电脑上的 Hermes 管理。

```sh
python3 --version
hermes --version
```

Windows 使用 `py -3 --version`。

## 安装并配对

先部署或获取可信的 TLS 中继地址；将 `relay.example.com` 替换为自己的域名。软件分发由 GitHub 提供，运行时中继仍需单独配置。

macOS / Linux：

```sh
curl -fsSL https://github.com/topyang519/hermes-harmony/releases/latest/download/install.sh | sh -s -- --relay wss://relay.example.com
```

Windows PowerShell：

```powershell
Invoke-WebRequest https://github.com/topyang519/hermes-harmony/releases/latest/download/install.ps1 -OutFile install.ps1
.\install.ps1 -Relay wss://relay.example.com
```

macOS / Linux 安装器创建登录服务；不支持时以前台运行。Windows 以前台运行。脚本下载固定版本的 wheel 并校验 SHA256SUMS；更新已有安装可以省略中继参数，保留已有配对。手机打开「设置 → 连接电脑」，扫码或粘贴电脑终端显示的链接，再连接。

Windows 配置目录依赖用户账户 ACL 隔离；请把配置放在仅自己可访问的用户目录中，不要使用共享目录。macOS/Linux 配置文件使用 0600 权限。

电脑与手机可在不同网络。电脑应保持开机联网，Hermes 与连接器持续运行。配对链接含访问凭据，勿公开。

源码安装：

```sh
./bridge/install.sh --relay wss://relay.example.com
```

## 可选语音

文字功能可直接使用。语音需 FFmpeg、已启用的 STT 和 TTS 提供方。

```sh
# macOS（需 Homebrew）
brew install ffmpeg
# Ubuntu / Debian
sudo apt update
sudo apt install ffmpeg
```

Windows PowerShell：

```powershell
winget install --id Gyan.FFmpeg -e
```

运行 `ffmpeg -version` 后，使用 `hermes tools` 启用并配置 Speech-to-Text 与 Text-to-Speech。已有自定义 command/插件提供方时可沿用；必须在当前 Hermes profile 中启用并填好命令。安装依赖后重启 Hermes 和连接器，在手机「安装与语音指南」重新检查。

配置检查只确认启用状态、提供方配置和 FFmpeg 存在，不执行自定义命令、不验证云凭据/网络/额度。检查通过后仍需实际发起语音对话。手机首次录音需授予麦克风权限。

## 排查

- 未生成配对链接：检查 Python 版本、下载和 SHA-256 校验输出。
- 连接失败：确认中继 TLS、电脑联网及 Hermes/连接器服务状态。
- 语音未启用：补齐当前 profile 的 STT/TTS 与 FFmpeg，重新检查。
- 自定义命令不可用：在电脑验证脚本路径、依赖、权限与凭据。
- 更换中继：重新用 `--relay` / `-Relay` 安装，然后刷新手机配对链接。
