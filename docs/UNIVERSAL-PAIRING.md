# 中继部署与跨网络配对

手机与电脑各自出站连接同一个 TLS WebSocket 中继，因此无需开放电脑公网入站端口。软件和安装脚本从 GitHub Releases 分发；中继只负责运行时通信。

## Docker 部署

需要指向服务器的域名和开放的 80/443 端口：

```sh
cd deploy
RELAY_DOMAIN=relay.example.com docker compose -f relay.compose.yml up -d --build
```

Caddy 自动提供 TLS。替换示例域名。部署前审核服务与网络设置，使用可信服务器；中继可接触消息内容，TLS 保护传输但并非端到端加密。

## systemd 与 Nginx

也可在服务器 Python 虚拟环境安装 `bridge/`，使用 `relay.systemd.service` 启动 loopback 的 8765 端口。`nginx-sslip-relay.conf` 是通用域名 TLS 模板，替换 `relay.example.com` 及证书路径；`nginx-relay.conf` 是 WebSocket/health 片段。代理不应记录包含配对密码的请求 URI。

健康检查为 `/healthz`；Nginx 模板另提供 `/hermes-harmony/healthz`。中继没有软件包下载目录，安装从 GitHub 获取。

## 电脑与手机

按 [COMPUTER-SETUP.md](COMPUTER-SETUP.md) 的 GitHub 命令安装并传入 `--relay wss://relay.example.com`。电脑随机生成相互独立的主机凭证和手机凭证，显示手机配对链接。手机扫码或粘贴链接即可连接。

连接器使用 loopback `17691` 访问其内部网关，再发现本机 Hermes。中继地址不写入公开软件默认值。已有配对可继续使用原中继；更新安装脚本不会删除本地用户配置。

## 运维

保持中继 TLS 证书有效；代理允许 WebSocket Upgrade，并设置足够的读取超时。勿记录或分享配对链接、请求查询串和消息内容。更换域名后用新 relay 参数重新配置，刷新手机链接。GitHub 安装分发与中继运维互相独立。
