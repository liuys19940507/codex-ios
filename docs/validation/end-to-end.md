# 端到端验证记录

观测日期：2026-11-10 UTC。Windows 原生 PowerShell5.1、Node22.22.0、Codex0.167.0；iPhone iOS26.5；Sideloadly0.72；普通 Apple 账号。此记录不包含账号、设备标识或令牌。

| 检查 | 结果与证据 |
| --- | --- |
| 原生共享 CLI 接管与退出后继续 | PASS，见[真实接管记录](live-attach.md)，同一个 app-server 承载任务，关闭 CLI/PowerShell 不结束任务 |
| Windows 运行时与 API | PASS，当前私有 EasyTier 地址监听8391，认证 `/v1/info` 返回 API1/Codex0.167.0；共享原生服务器独立监听loopback8390 |
| 手机覆盖更新与配对保留 | PASS，9cba691覆盖安装后用户确认原 Windows 连接保留，直接进入任务列表 |
| 手机追加正在运行的 CLI 轮次 | PASS，原 thread/turn 中新增用户文字 `结束时请包含 PHONE_STEER_OK_20261110`，原轮次完成后的回复包含该标记 |
| 手机处理原 CLI 命令审批 | PASS，批准一次打印标记并等待45秒的命令，原命令执行一次，退出码0；电脑没有代发输入或审批 |
| 手机自动实时显示最终回复 | PASS，用户确认未手动刷新便出现两个标记的最终回复 |
| 晚加入部分输出与结束补齐 | PASS，按已接受的[行为修订](../superpowers/specs/2026-11-08-live-stream-recovery-amendment.md)实测；取消且没有完整结束消息时保留不完整提示 |
| 原生问题与文件审批适配 | PASS，独立受控0.167.0探针验证问题回合及指定文件单次审批；手机问题/文件表单尚未分别实测 |
| 队列、权限扩展、MCP 确认能力 | Disabled，未通过各自原生路径验证的能力不启用，未知请求只读 |
| 原生双连接重复审批 | PASS，原生接管探针证实已解决请求不会再次执行；手机与 CLI 同时点击的场景未单独执行 |
| 输入超时/重连不重发 | PASS，Windows与iOS自动测试验证UUID持久化、只读核对与重复防护；不确定结果不冒充成功 |
| 大字体、长输出、CRLF diff、子任务返回草稿 | PASS，181616d的[云端测试](https://github.com/liuys19940507/codex-ios/actions/runs/42732288469)：46项单元测试和6项UI测试，含对应回归 |
| Windows干净依赖安装、单测、类型检查 | PASS，f23e4de的独立源码导出执行npm ci退出0、87/87测试通过、tsc退出0；导出避免替换运行中桥接的依赖 |
| Windows PowerShell完整测试 | PASS，Pester5.7.1，8/8通过，退出0 |
| iOS前后台恢复与模型设置 | 软件PASS，[920bdad/run42734680247](https://github.com/liuys19940507/codex-ios/actions/runs/42734680247)51项单元测试、6项UI测试及arm64打包通过；当前手机9cba691不包含此版本，真机后台恢复仍待验证 |
| 含中文/emoji草稿的覆盖更新 | NOT RUN，用户已留下“升级前草稿：中文😀”，等待build3覆盖后核对 |
| Windows桥接重启 | PASS，仅重启已验证归属的桥接，原生PID10052保持；原手机操作UUID回执仍accepted。手机build3恢复检查仍待执行 |
| 多项目同时运行的实际 CLI | PASS，第二个真实远程CLI工作目录为独立worktree，返回PROJECT_TWO_OK；两项目列表互不混入，快照projectId正确。临时项目配置已在finally恢复，当前仅保留原项目 |
| 实际签名续期/自动刷新 | NOT RUN，维护脚本返回daemon=running、renewal=unknown、evidenceAt=null，不把USB检测当作成功证据 |
| Codex定时维护 | 用户选择暂不创建；交付[固定提示词模板](../codex-maintenance-task.md) |

## 手机控制的同任务证据

- 手机构建：9cba691/build2；[云端run42730023510](https://github.com/liuys19940507/codex-ios/actions/runs/42730023510)，42项单元测试、5项UI测试及arm64打包通过。
- 由真实远程 CLI 创建的thread：`01a1c2f7-0c5d-7800-9c4c-c8396a392ec9`。
- 从创建、手机追加、审批到完成，turn始终为`01a1c2f7-0e08-7e61-b4b0-87b181ce776b`。
- 手机追加操作`CE620545-0A54-4A76-8582-44928426EA58`已确认，返回原turnId；审批操作`EB60B2A9-09BE-44AC-8321-1B895086E9F2`已确认，匹配原请求。
- 原命令条目`exec-aa20fda2-d3ab-4949-ab70-614f2cc43690`仅执行一次，输出`CODEX_PHONE_BRIDGE_20261110`，退出码0；随后原轮次completed、pending为空。
- 最终回复同时包含命令输出标记与手机追加标记。用户确认手机自动显示最终回复。

此结果证明手机控制共享 CLI 的真实任务。它不证明任意独立 Codex 进程可以无迁移接入，也不替代上表仍为NOT RUN的设备验证。
