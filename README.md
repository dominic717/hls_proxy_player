# HLS Web Player

一个**通用 HLS 播放器** Flutter 应用，支持 Android / Android TV。

本仓库（`hub` 分支）是合规发布的通用版本，仅包含播放引擎，不包含任何站点定向抓取、私有加密破解、WAF 绕过或硬编码凭据。

## 功能

- 播放任意标准 HLS（`m3u8`）地址（用户输入的 URL）。
- 通过本地代理（`LocalProxy` + 最小 PASV FTP 客户端）播放**用户自有 NAS(FTP)** 上的分片内容，支持按集切换。
- 可选 AES-128 解密遵循 HLS 标准 `#EXT-X-KEY`（密钥随内容下发），不内置任何第三方静态密钥。
- 断点续播、历史记录、缓存记录等本地数据库能力。
- 遥控器（DPad）/ 触摸双兼容的播放器 UI，适配 Android TV。

## 合规说明

本项目仅用于播放用户**自行拥有合法权利**的内容。代码不含：

- 任何特定站点域名、UA/Referer 伪装、TLS 指纹伪造（如 Cronet 抗封栈）；
- DoH 换 IP 直连等反爬 / 抗封手段；
- 从第三方站点提取的静态加密密钥；
- 源码中硬编码的 NAS 账号密码（凭据保存在本机 `local_config.json`，**不进版本库**）。

## 使用

1. 在「设置」页填写你的 NAS / FTP 连接信息（主机、端口、用户名、密码、根目录）。
2. 首页输入 m3u8 地址可直接播放；或进入「内网 FTP 资源库」浏览 NAS 上的目录（需 `_map.txt` 索引）。
3. 播放器支持选集、倍速、全屏、断点续播。

## 构建

```bash
flutter pub get
# 手机
flutter build apk
# Android TV（按你的 productFlavors / 构建脚本而定）
flutter build apk --target-platform android-arm64
```

## 目录

- `lib/main.dart` — 应用入口、首页、播放页、设置页
- `lib/target_player.dart` — 通用播放器 UI（遥控/触摸双兼容）
- `lib/ftp_source.dart` — 最小 FTP 客户端与 NAS 目录解析
- `lib/local_proxy.dart` — 本地代理，把 FTP 分片暴露为 m3u8
- `lib/merger.dart` — 分片下载 + AES-128 解密 + 拼接
- `lib/http_fetch.dart` — 标准 HTTP 取流（内网自签证书按私有网段放行）

## License

[MIT](LICENSE)
