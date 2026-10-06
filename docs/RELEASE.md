# GitHub 发布规则

手机版本 0.6.8 / code 39，连接器 0.3.8；版本标签 `v0.6.8`。软件仓库与安装分发均使用 GitHub。

## 资产

| 文件 | 用途 |
| --- | --- |
| `Harmes-0.6.8-unsigned.hap` | 不含个人签名的 HarmonyOS release 构建 |
| `hermes_harmony_bridge-0.3.8-py3-none-any.whl` | Python 电脑连接器/网关/中继 |
| `install.sh` / `install.ps1` | GitHub 下载与校验安装器 |
| `hermes-harmony-0.6.8-source.tar.gz` | 清理后的最终源码 |
| `SHA256SUMS` | 上述文件的 SHA-256 |

安装器下载当前固定版本的 wheel，并对照同一 release 的校验文件确认完整性。GitHub 安装脚本入口使用 `releases/latest/download/`，后续更新需同步脚本中的版本与文件名。首次安装需提供可信中继地址；GitHub 不承载实时 WebSocket 中继。

## 隐私检查

只导出版本控制的产品文件与必要模板。不得发布 `.secrets/`、`.env`、bridge.toml、connection.json、state/、logs/、缓存、聊天/录音/截图记录、个人服务器地址、绝对用户目录、签名证书、私钥、设备标识或 SDK 本地配置。

首次公开使用清理后的全新提交历史。不得推送含历史凭据或个人交接记录的旧分支/标签。提交作者使用项目通用身份，不带个人邮箱。发布资产在上传前单独检查其内容，不能只依据 .gitignore 判断。

个人调试签名只能留在本地；公开 HAP由安装者自行签名。每次发布保留当前版本的源码与必要产物，清理过时 wheel/HAP、临时预览、备份和构建缓存。用户运行数据不属于安装包清理范围。

本地开发仓库可以保留旧历史，公开仓库必须由 `tools/export-release-source.py` 导出的文件建立；不要给包含旧历史的工作目录添加公开推送远程。后续更新在已清理的公开仓库中提交。

标签工作流只生成连接器 wheel、两个安装器及其校验文件，作为待发布资产上传。加入手工构建的 HAP与源码归档后，发布负责人必须重新生成涵盖全部最终文件的 SHA256SUMS；本次发布采用这份完整校验清单。
