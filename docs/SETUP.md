# 独立直连网关

通常使用 [跨网络配对](UNIVERSAL-PAIRING.md)。独立网关保留给已有安装或局域网部署。

```sh
cd bridge
python3 -m venv .venv
.venv/bin/python -m pip install -e .
cp bridge.toml.example bridge.toml
```

生成强随机密码并在本地 `bridge.toml` 的 `app_password` 填入；该文件禁止提交：

```sh
python3 -c 'import secrets; print(secrets.token_urlsafe(32))'
.venv/bin/python -m hermes_harmony_bridge --config bridge.toml
```

默认 `127.0.0.1:7691` 只允许本机访问。需要局域网时显式修改 host 和防火墙；手机填写 `ws://电脑局域网地址:7691/v2/app`。跨公网使用 TLS 反向代理，填写 `wss://gateway.example.com/v2/app`，不得公开明文 WS。网关只持有本机 Hermes 凭据，不对外暴露 Hermes 本身。

如果使用 Cloudflare Access，请在手机高级设置填写自己的服务凭据并配置 Access 策略。Nginx/隧道日志不得记录带密码的 URL。`deploy/ai.hermes.harmony.bridge.plist.example` 为 macOS 本地服务模板，替换路径后使用。
