# 真机签名与安装验证

此记录区分构建产物和实际设备结果，不包含 Apple ID、UDID、凭据或签名缓存。

| 字段 | 当前观测 |
| --- | --- |
| 构建提交 | `1f00e6a0931548b7f356178591a55e8361da26f6` |
| 云端真机打包 | PASS，[run 42557234611](https://github.com/liuys19940507/codex-ios/actions/runs/42557234611) 的 package job |
| 产物核对 | PASS：`Payload/CodexRemote.app/Info.plist`、`com.liuys.codexremote`、`iphoneos`、最低 `16.0`；云端验证 arm64 |
| IPA SHA-256 | `849b40b8a07d24adb662527f0d57e81883bcc23b9e1e1da3ced92ef3de7d3fac` |
| 观测日期 | 2026-11-09 UTC / 2026-11-08 America/Los_Angeles |
| iOS 版本 | 未取得 |
| 本地安装工具 | 标准安装路径未发现 Sideloadly 或 Apple Mobile Device Support；非完整软件清单 |
| 安装方式 | 计划 Windows Sideloadly、普通账号、首次 USB |
| 首次安装并打开 | NOT RUN，等待手机连接和本人完成本地签名/信任 |
| 覆盖安装 | NOT RUN |
| 配置 / Keychain / 中文草稿保留 | NOT RUN，后续功能尚未交付 |
| 真实重签 / 自动刷新 | NOT RUN |

目前产物是最小原生入口，尚无完整远程控制界面。不能据此宣称手机控制功能或续签已完成。按[安装步骤](../signing-and-refresh.md)操作后再更新相应行。
