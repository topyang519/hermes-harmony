# 维护交接

最终版本：手机 0.6.8 / code 39，Python 连接器 0.3.8。公开发布以 GitHub Releases 为准。此文档只记录产品架构与操作方法，不保存任何个人部署或使用记录。

## 数据与连接

```text
HarmonyOS 手机 ── WSS ── 中继 ── WSS ── 电脑连接器
                                          │ loopback WebSocket
                                     本机 Python 网关
                                          │ loopback JSON-RPC
                                      Hermes Agent
```

电脑连接器管理的网关仅监听 `127.0.0.1:17691`；独立直连网关默认监听 `127.0.0.1:7691`。中继默认 loopback `8765`，由反向代理提供 TLS。Hermes 端口与凭据通过本机 discovery 获得。

连接器配置默认在 `~/.config/hermes-harmony/connection.json`，包含随机主机凭证、手机凭证和本地网关密码，权限应为 0600。状态保存在该目录下的 `state/`。手机凭据由 AssetStore 保存；iOS 使用 Keychain。配置、状态、日志和签名均不发布。

## 主要代码

| 文件 | 职责 |
| --- | --- |
| `bridge/src/hermes_harmony_bridge/connect.py` | 生成配对、安装服务、连接中继 |
| `relay.py` | 匹配主机与手机 WebSocket 并转发 |
| `server.py` | 认证、会话、审批、语音、重放、超时 |
| `hermes.py` / `discovery.py` | Hermes RPC 与本机连接发现 |
| `app/entry/src/main/ets/service/GatewayClient.ets` | 手机连接、生命周期、任务与会话恢复 |
| `EventStore.ets` | 会话视图状态与重放合并 |
| `Secrets.ets` | 手机安全存储 |
| `pages/SetupPage.ets` | GitHub 安装与语音指南 |

任务超时按无进展时间计算，默认 600 秒；硬上限 3600 秒。审批与澄清要求用户明确回应。恢复连接后补齐当前会话，用户操作不跨重连自动重放。

语音上行传 PCM，网关封装 WAV 后附件提交 Hermes；私有识别提示不替代用户语音消息。下行自动 TTS 返回 PCM，手机播放。文字默认可用，语音默认关闭，需配置检查通过。

## 发布维护

1. 修改源码并同步 AppScope、包元数据、握手、Agent Card 与 Python 版本。
2. 运行连接器测试、客户端生命周期检查和 HarmonyOS release 构建。
3. 使用清理后的源码导出；扫描源码、归档及安装包，排除本地配置和个人记录。
4. 上传 wheel、未签名 HAP、安装脚本、源码包和 SHA256SUMS 到 GitHub Release。
5. 通过 GitHub 安装命令验证下载与校验流程。

详细安装见 COMPUTER-SETUP.md，构建见 DEVECO-SETUP.md，发布规则见 RELEASE.md。公开未签名包由安装者使用自己的签名；个人调试签名只在本地保留。

## 已知限制

Push Kit 未接入；系统挂起/终止客户端后无法保证即时远程任务通知。小艺 A2A 需要开发者注册和真机验收。iOS 是原型，不纳入本次 HarmonyOS release。自动测试和编译不能替代语音、手势、网络切换及小艺的真机验收。
