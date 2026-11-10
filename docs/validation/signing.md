# 真机签名与安装验证

此记录区分构建产物和实际设备结果，不包含 Apple ID、UDID、凭据或签名缓存。

| 字段 | 当前观测 |
| --- | --- |
| 当前手机构建 | `e3c54088ed24be05806e4afcc29a5c7184c081b0`，build3 |
| 云端真机打包 | PASS，[run42737599302](https://github.com/liuys19940507/codex-ios/actions/runs/42737599302) 的 package job |
| 产物核对 | PASS：`Payload/CodexRemote.app/Info.plist`、`com.liuys.codexremote`、`iphoneos`、最低 `16.0`；云端验证 arm64 |
| IPA SHA-256 | `624bc604aee420ecbd0bb53226512e2107b26545953cbf818999882484f920df` |
| 观测日期 | 2026-11-10 UTC / America/Los_Angeles |
| iOS 版本 | 26.5，来自用户提供的安装界面 |
| 本地安装工具 | Sideloadly 0.72；Apple Mobile Device Service 正在运行 |
| 安装方式 | Windows Sideloadly、普通账号、首次 USB；Apple 验证由用户在本地工具完成 |
| 首次安装并打开 | PASS，用户确认已打开并看到“连接尚未配置”基础入口 |
| 功能版本覆盖安装并打开 | PASS，用户确认9cba691覆盖后原连接保留，直接进入任务列表并完成操作 |
| 真机 Keychain 写入 / 读取 | PASS，保存连接后经系统SecItem读取令牌，真实认证通过 |
| 重开 / 更新后的配置、Keychain 保留 | PASS，用户确认9cba691覆盖后原连接保留、直接进入任务列表并完成操作 |
| 中文/emoji草稿覆盖更新保留 | PASS，用户确认build3覆盖后中文/emoji草稿仍在，后台恢复后也保留 |
| 到期续签 / 自动刷新 | NOT RUN |

本次真机已验证配置/Keychain覆盖保留、HTTP认证、实时任务追加与命令审批，详见[网络记录](ios-install-network.md)和[端到端记录](end-to-end.md)。真实续签仍未验证。Sideloadly 当前启用自动 Bundle ID，签名后的实际 ID 尚未核对；覆盖安装沿用同一账号及 Bundle 设置。参见[安装步骤](../signing-and-refresh.md)。

前一连接版本582ac90的[run42586465419](https://github.com/liuys19940507/codex-ios/actions/runs/42586465419)及其SHA-256 `ddfaeed59cf4d6dadcdd152c13e93f234c401fa3ce900bc87c8c515b1070ea76`为历史检查点。功能版9cba691安装包SHA-256为`3dca7818fe420604eb51b396670267775b8680b22f1b14b0fca4904abcd264e5`。两次覆盖安装均沿用原账号及Bundle设置。
