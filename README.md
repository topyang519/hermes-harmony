# 赫默狮 · Hermes Harmony

HarmonyOS 手机客户端与 Python 电脑连接器，让手机通过配对的电脑使用 Hermes Agent，支持文字对话、语音、任务进度、审批与会话管理。

当前发布：手机 **0.6.8 / versionCode 39**，连接器 **0.3.8**。HarmonyOS 7 / API 26 起；Python 3.11 起。`ios/` 为独立的 iOS 原型源码，不属于本次手机安装包。

## 安装电脑连接器

先在电脑安装并配置 [Hermes Agent](https://hermes-agent.nousresearch.com/docs/getting-started/installation)，确认文字对话可用。电脑连接器与手机需要连接同一个 TLS WebSocket 中继；将示例地址替换为部署的中继域名。

macOS / Linux：

```sh
curl -fsSL https://github.com/topyang519/hermes-harmony/releases/latest/download/install.sh | sh -s -- --relay wss://relay.example.com
```

Windows PowerShell：

```powershell
Invoke-WebRequest https://github.com/topyang519/hermes-harmony/releases/latest/download/install.ps1 -OutFile install.ps1
.\install.ps1 -Relay wss://relay.example.com
```

更新已有连接器可省略 relay 参数，沿用电脑上的配对配置。安装脚本与连接器 wheel 都由 GitHub Releases 提供，wheel 下载后校验发布的 SHA-256。安装成功后，在手机设置中扫码或粘贴电脑显示的配对链接。

## 下载手机客户端

从 [最新版本](https://github.com/topyang519/hermes-harmony/releases/latest) 获取 `Harmes-0.6.8-unsigned.hap`。公开包不含个人调试证书，需要使用自己的 HarmonyOS 签名配置后安装；源码构建见 [构建说明](docs/DEVECO-SETUP.md)。

## 项目结构

| 路径 | 内容 |
| --- | --- |
| `bridge/` | Python 网关、电脑连接器、WebSocket 中继及测试 |
| `deploy/` | GitHub 安装脚本、通用中继部署模板 |
| `ios/` | iOS 原型 |
| `docs/` | 安装、协议、架构与发布审查 |

手机与电脑各自出站连接中继；连接器在电脑 loopback 上运行网关，再访问本机 Hermes。已有直连网关也可使用。GitHub 负责软件分发，中继负责运行时连接；使用者自行配置中继。

## 文档

- [电脑安装与语音配置](docs/COMPUTER-SETUP.md)
- [中继部署与跨网络配对](docs/UNIVERSAL-PAIRING.md)
- [直连网关配置](docs/SETUP.md)
- [维护交接与架构](docs/HANDOFF.md)
- [v2 协议](docs/PROTOCOL.md)
- [小艺 A2A](docs/XIAOYI-A2A.md)
- [发布与隐私规则](docs/RELEASE.md)
- [本次代码审查与修复](docs/RELEASE-REVIEW.md)

## 隐私与边界

发布源码与安装包不包含聊天记录、录音、配对凭证、模型密钥、个人服务器地址、设备标识或个人签名材料。运行时配对与会话状态在用户设备本地生成，不能放入发布目录。配对链接授予电脑 Agent 访问能力，应仅交给可信设备。中继处理消息明文，须部署在可信环境并使用 TLS。

文字功能不依赖语音。语音需电脑启用 STT/TTS 并安装 FFmpeg；配置检查不验证云服务额度或实际可用性。Push Kit 尚未接入，应用空闲挂起或退出后的远程推送不保证送达。小艺扩展需使用自己的开发者账号完成平台注册；源码存在不代表已上线。

## 开发与验证

```sh
cd bridge
python3 -m venv .venv
.venv/bin/python -m pip install -e '.[dev]'
.venv/bin/python -m pytest
```

客户端生命周期检查：`node app/scripts/check-gateway-lifecycle.cjs`。源码导出与隐私扫描由 `tools/export-release-source.py` 和 `tools/check-release-privacy.py` 提供。构建及当前验证结果见 [BUILD-STATUS.md](BUILD-STATUS.md)。
