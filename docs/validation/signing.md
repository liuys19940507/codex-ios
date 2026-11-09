# 真机签名与安装验证

此记录区分构建产物和实际设备结果，不包含 Apple ID、UDID、凭据或签名缓存。

| 字段 | 当前观测 |
| --- | --- |
| 构建提交 | `582ac9000e56721379ba6d7f687e7cf66bfd8d6a`，build2 |
| 云端真机打包 | PASS，[run 42586465419](https://github.com/liuys19940507/codex-ios/actions/runs/42586465419) 的 package job |
| 产物核对 | PASS：`Payload/CodexRemote.app/Info.plist`、`com.liuys.codexremote`、`iphoneos`、最低 `16.0`；云端验证 arm64 |
| IPA SHA-256 | `ddfaeed59cf4d6dadcdd152c13e93f234c401fa3ce900bc87c8c515b1070ea76` |
| 观测日期 | 2026-11-09 UTC / America/Los_Angeles |
| iOS 版本 | 26.5，来自用户提供的安装界面 |
| 本地安装工具 | Sideloadly 0.72；Apple Mobile Device Service 正在运行 |
| 安装方式 | Windows Sideloadly、普通账号、首次 USB；Apple 验证由用户在本地工具完成 |
| 首次安装并打开 | PASS，用户确认已打开并看到“连接尚未配置”基础入口 |
| 第二个构建安装并打开 | PASS，用户确认填写地址和令牌后“已连接”；已有数据保留仍待验证 |
| 真机 Keychain 写入 / 读取 | PASS，保存连接后经系统SecItem读取令牌，真实认证通过 |
| 重开 / 更新后的配置、Keychain、中文草稿保留 | NOT RUN |
| 真实重签 / 自动刷新 | NOT RUN |

本次真机已验证连接配置和HTTP认证，详见[网络记录](ios-install-network.md)；实时任务控制和续签尚未通过真机验证。Sideloadly 当前启用自动 Bundle ID，签名后的实际 ID 尚未核对；覆盖安装须沿用同一账号及 Bundle 设置，并实测存储保留。参见[安装步骤](../signing-and-refresh.md)。
