# iOS 原型

`ios/` 是 SwiftUI 原型源码，不属于本次 HarmonyOS 0.6.8 安装包。默认未配置网关或凭据，使用者需输入自己的网关及密码。凭据保存在 Keychain，本地配置禁止发布。

```sh
cd ios
xcodegen generate
open HermesHarmony.xcodeproj
```

需要 Xcode 和 iOS 17+ SDK；模拟器构建不需要个人签名。设备签名在自己的 Xcode 环境配置。当前平台功能与 HarmonyOS 不完全一致，源码审查与编译不能替代真机测试。
