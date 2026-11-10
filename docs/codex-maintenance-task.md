# Codex 本地定时维护

维护脚本已实现并通过测试。用户于2026-11-10选择暂不创建计划任务；目前没有可验证的真实续签成功记录。脚本检查并保障已配置的 Sideloadly daemon 存活，只有签名工具本身负责安装和续签。

在桌面端 Codex 的本地项目中使用以下提示词；执行时间和时区由本人指定后再配置到 Scheduled：

```text
在原生 Windows PowerShell 中仅运行以下固定脚本一次：
& 'D:\other\codex_app\.worktrees\native-ios-remote\scripts\windows\Check-AppRefresh.ps1' -ConfigPath 'C:\ProgramData\CodexRemote\Maintenance\runtime.json'

读取输出 JSON，报告 checkedAt、daemon、renewal、evidenceAt 及 message 的原意。
daemon=running/started 只表示进程状态，不等于已经续签。
renewal=waiting/unknown 时明确写“尚未确认续签”；needs_user 或命令失败时列出必要的人工动作。
不要修改 Apple 凭据、安全设置或签名参数，不卸载 App，不停止 Codex 任务，不循环重试，不自行运行其他签名命令。
```

先在普通本地对话运行一次并核对私有目录 `last-check.json`，再创建任务并手动运行一次，确认 Scheduled 最近运行与脚本时间吻合。若缺少本地 Scheduled 创建工具，使用桌面端界面完成配置；不能用云端 Pages 维护任务替代访问本机签名工具。

本地任务需要电脑开机且桌面 App 运行，模型运行可能占用账号用量。CLI 不提供 Scheduled 管理界面，网页版任务不能直接访问本机文件。依据 [OpenAI 官方 Scheduled 文档](https://learn.chatgpt.com/docs/automations?surface=app)，核对于 2026-11-10 UTC。

手机不在可发现的 USB/Wi-Fi 配对范围时，报告等待或未知；EasyTier 连通不证明签名配对可用。普通账号每次七天的限制仍然存在。
