# 真机签名与安装验证

此记录区分构建产物和实际设备结果，不包含 Apple ID、UDID、凭据或签名缓存。

| 字段 | 当前观测 |
| --- | --- |
| 构建提交 | `7f54032ec726e50ce2e0f043cdf1a97e63807ea5` |
| 云端真机打包 | PASS，[run 42573767525](https://github.com/liuys19940507/codex-ios/actions/runs/42573767525) 的 package job |
| 产物核对 | PASS：`Payload/CodexRemote.app/Info.plist`、`com.liuys.codexremote`、`iphoneos`、最低 `16.0`；云端验证 arm64 |
| IPA SHA-256 | `365b4028ff95e0cd8730667f7f752a89558f80c5243cb3e619f4a9c7f50e0080` |
| 观测日期 | 2026-11-09 UTC / 2026-11-08 America/Los_Angeles |
| iOS 版本 | 26.5，来自用户提供的安装界面 |
| 本地安装工具 | Sideloadly 0.72；Apple Mobile Device Service 正在运行 |
| 安装方式 | Windows Sideloadly、普通账号、首次 USB；Apple 验证由用户在本地工具完成 |
| 首次安装并打开 | PASS，用户确认已打开并看到“连接尚未配置”基础入口 |
| 覆盖安装 | NOT RUN |
| 配置 / Keychain / 中文草稿保留 | NOT RUN，后续功能尚未交付 |
| 真实重签 / 自动刷新 | NOT RUN |

本次真机验证的是基础入口。连接编辑页后续构建正在开发；远程控制和续签尚未通过真机验证。Sideloadly 当前启用自动 Bundle ID，签名后的实际 ID 尚未核对；覆盖安装须沿用同一账号及 Bundle 设置，并实测存储保留。参见[安装步骤](../signing-and-refresh.md)。
