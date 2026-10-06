# 小艺 A2A 扩展

0.6.8 通过 `HermesAgentAbility` 和 Agent Card 暴露配对电脑的 Hermes Agent。需要 HarmonyOS 7 / API 26，并先在手机完成配对。扩展复用手机安全存储中的连接，不生成第二套凭据。

## 开发者注册

使用自己的 Huawei 开发者账号注册应用与终端 A2A 服务。bundle 为 `ai.hermes.harmes`、module 为 `entry`、service 为 `HermesAgentAbility`。Agent Card 产品名称为「赫默狮」，Card ID 是产品静态标识；平台账号的应用 ID、Agent ID、签名和设备 profile 不包含在公开源码中。平台测试和发布需按开发者控制台要求完成；本项目不宣称已通过平台上线验收。

## 行为

- 独立小艺上下文对应独立 Hermes 会话，任务串行并以请求 ID 关联。
- 使用支持 correlation/cancel 协议的连接器（本次为 0.3.8），要求 Hermes 返回持久化用户消息 ID；不能关联时明确失败。
- 审批和单问题澄清交给手机会话卡片，必须用户明确选择。扩展不会自动批准电脑操作。
- 取消只有电脑确认中断后才报告成功；无法确认时明确提示检查电脑。
- 任务保持进度更新与会话恢复；实际等待期限见 `GatewayClient.ets` 与网关配置。

GitHub 上的 release 构建、自动测试与本机配对不等于完成小艺真机调用验收。注册、签名、权限及端到端测试由安装者在自己的开发环境完成。
