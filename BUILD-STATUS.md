# 当前构建状态

手机 **0.6.8 / versionCode 39**，电脑连接器 **0.3.8**。

| 检查 | 结果 |
| --- | --- |
| Python 网关/连接器 | 99 个非 live 测试通过，1 个 live 测试未运行 |
| HarmonyOS 客户端生命周期 | 12 项通过 |
| HarmonyOS 7 / API 26 | release 未签名 HAP构建通过，debug=false |
| iOS 原型 | Release 模拟器构建通过，未使用个人签名 |
| 隐私 | 源码、HAP、wheel 和公开资产上传前单独扫描；公开使用全新提交历史 |

公开下载见 [GitHub Releases](https://github.com/topyang519/hermes-harmony/releases/latest)。公开 HAP需安装者使用自己的签名。真机语音、手势/网络切换和小艺平台注册调用尚需验收，Push Kit 未接入。构建仍有 SDK API弃用和设备能力警告。

审查问题、修复方案与检查范围见 docs/RELEASE-REVIEW.md。
