# HarmonyOS 构建与签名

应用 bundle 为 `ai.hermes.harmes`，需要 HarmonyOS 7 / API 26 SDK、DevEco Studio 或 Huawei 命令行工具，以及 JDK 17。代码使用 AgentFrameworkKit API 26，不能降为 API 12。

## 构建

```sh
BUILD_MODE=release ./app/scripts/build-hap.sh
```

脚本从 `app/build-profile.json5.example` 创建本地配置，并寻找 ohpm/hvigorw。若工具未自动找到，可设置 `OHPM`、`HVIGORW`、`DEVECO_CLI_CLT_PATH` 或 `DEVECO_SDK_HOME`。本地 SDK 路径填写到被忽略的 `app/local.properties`。发布使用 release 构建：

```sh
cd app
hvigorw assembleHap --mode module -p product=default -p module=entry@default -p buildMode=release --no-daemon
```

公开发布只使用未签名 HAP，不携带开发者个人调试证书。不要上传 `build-profile.json5`、密钥、证书、设备签名 profile 或 debug 构建缓存。发布前检查编译包不含本机绝对路径及用户配置。

## 个人设备安装

在 DevEco Studio 中使用自己的开发者账号为 bundle 配置签名，构建后：

```sh
hdc list targets
hdc install app/entry/build/default/outputs/default/entry-default-signed.hap
hdc shell aa start -a EntryAbility -b ai.hermes.harmes
```

签名可安装的设备由你自己的 profile 决定。未签名 HAP不能直接安装，小艺平台能力另需注册及真机测试。
