# Personal Installation and Codex Maintenance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让普通 Apple 账号能够安装、覆盖更新并在可连接电脑时自动续签，维护检查由 Codex 桌面端调度。

**Architecture:** 云端只编译；Windows 本地 Sideloadly 负责 Apple 配对、签名和 refresh。维护脚本检查现有后台进程及可验证状态，Codex 定时任务调用脚本并记录结果，不冒充签名工具。

**Tech Stack:** Windows PowerShell 5.1+、Pester 5.x、Sideloadly、Codex 桌面端本地 Scheduled；消费 I1 的未签名 IPA、I2 的配置与 I4 的草稿。

**Spec:** [设计第 2、7–10 节](../specs/2026-11-08-codex-ios-remote-design.md)

## Global Constraints

- 普通 Apple 账号，每次签名七天；开发者模式不延长期限。
- Apple 凭据留在本地签名工具，仓库和 Actions 不保存密码、证书、设备令牌。
- 真实续签需要 USB 或已配置的 Wi-Fi 配对；EasyTier 连接不等于 Apple 设备发现可用。
- 使用稳定 Bundle ID `com.liuys.codexremote`，覆盖安装而非卸载。
- 调度在 Codex 桌面端，需电脑和桌面 App 运行；用户指定时间/时区以后才创建任务。

## Review Focus

1. 只有 IPA 文件、没有真机安装：M1 明确区分构建成功和安装成功。
2. 只看到后台进程，不存在签名结果：M2 返回 unknown/waiting，不能报 renewed。
3. 可执行文件路径不存在或被替换：M2 拒绝启动未配置路径，不搜索并执行任意同名程序。
4. 计划运行时手机不在家、Windows 未登录或 Apple 要求验证：M2/M3 记录待处理而非声称续签。
5. 覆盖更新和重签后数据丢失：M1 真实检查 Keychain/配置/草稿，不以进程退出码代替。

### M1: 普通账号的首次安装与覆盖更新关卡

**Files:** Create `docs/signing-and-refresh.md`, `docs/validation/signing.md`；Modify I2 的 `docs/validation/ios-install-network.md` 和 `.gitignore`（仅有必要时）。

**Interfaces:** Consumes `CodexRemote-unsigned.ipa`、固定 Bundle ID；Produces 用户本地已安装应用及脱敏报告，字段为 commit、iOS 版本、安装方式、首次安装/覆盖安装/数据保留/真实续签各自状态和观测时间，不记录 Apple ID/UDID/令牌。

- [ ] 下载 I1 的真实设备 IPA，检查 zip 布局和预期 Bundle ID；产物仍未签名，不尝试直接点击安装。不对文档写镜像单元测试。
- [ ] 核对本地已有 Sideloadly 与 Apple 配对组件；缺失时按其官方 Windows 指南准备。用户本人在工具和手机上完成 Apple 登录验证、信任及开发者模式；不在聊天或仓库收集凭据。
- [ ] 首次 USB 安装 I1 最小 App，实际打开并记录 PASS/FAIL。失败先定位打包/签名/设备兼容，不继续把完整 UI 开发当作安装验证。
- [ ] I2 可用后检查配置/Keychain 覆盖更新保留，I4 可用后补做中文草稿覆盖更新保留；都使用同 Bundle ID 且再次打开验证。真实执行一次重签/refresh 并检查结果，尚未完成时记 NOT RUN；先完成首次安装不等于这些后续检查已通过。
- [ ] 说明 Wi-Fi 配对、自动 refresh 与离开电脑超过七天的情况；提交脱敏文档 `docs: verify free-account device installation`。不将本地 IPA、凭据、签名缓存或截图中的账号信息提交。

### M2: 有证据边界的本地维护脚本

**Files:** Create `scripts/windows/Check-AppRefresh.ps1`, `scripts/windows/tests/Refresh.Tests.ps1`, `docs/maintenance-config.example.json`。

**Interfaces:** `Check-AppRefresh.ps1 -ConfigPath <absolute-json>` 输出单个 JSON：`{checkedAt:string,daemon:'running'|'started'|'missing',renewal:'confirmed'|'waiting'|'unknown'|'needs_user',message:string,evidenceAt:string|null}`。配置只含绝对 Sideloadly 后台 exe 路径、日志输出目录及已验证的证据读取配置；不含 Apple 密码。

- [ ] Pester 用 mock 测试 `RunningDaemonDoesNotProveRenewal`、`MissingConfiguredExeFailsClearly`、`StartsHiddenOnlyOnce`、`NoDeviceWaitsWithoutRetryLoop`、`OldEvidenceDoesNotConfirmNewRenewal`。关键断言 `$result.renewal | Should -Be 'unknown'`（仅有 daemon）、`Should -Invoke Start-Process -Times 0`（已运行），无新证据时不得 confirmed。
- [ ] `Invoke-Pester -CI -Path scripts/windows/tests/Refresh.Tests.ps1` 先 FAIL，且进程退出码非零。
- [ ] 实现固定路径/签名工具身份校验、当前用户后台进程检查和必要时 `Start-Process -WindowStyle Hidden`。已有 daemon 不重复启动，不终止签名进程、不执行猜测的续签 CLI；结果写入本地日志，只有经 M1 验证的明确新成功证据才能 confirmed，Apple 验证需本人操作时返回 needs_user。
- [ ] 同命令 PASS；在真实 Windows 会话运行脚本并对照 Sideloadly 观测。证据格式不可可靠读取时保留 unknown，只自动保障 daemon 存活；文档明确这个边界。
- [ ] 提交 `feat: check local signing maintenance without false success`。

### M3: Codex 桌面端的本地调度与维护说明

**Files:** Create `docs/codex-maintenance-task.md`；Modify README、signing-and-refresh 指南。

**Interfaces:** 消费 M2 已测试脚本；Produces 一个待用户指定时间/时区后配置的本地 Scheduled 任务，提示词固定执行绝对脚本路径，不进行自由式签名操作。

- [ ] 在普通本地 Codex 对话中先运行 M2，确认工作目录、PowerShell、配置路径和可用访问权限；报告 JSON 原始含义，不把 started 等同 confirmed。
- [ ] 保存可直接使用的任务提示词：运行 `Check-AppRefresh.ps1`，汇总 checkedAt/daemon/renewal，失败或 needs_user 才列出人工动作；不改凭据/安全策略、不卸载 App、不停止 Codex 任务。
- [ ] 向用户一次性确认执行时间与时区；取得明确时间后，在 Codex 桌面端创建本地任务，先手动 Run now 观察一次。未提供时间时仅交付模板，不能自行选定时间或把任务写成已创建。
- [ ] 检查 Scheduled 中的最近运行与脚本日志吻合；手机离线时结果应为 waiting/unknown，不能显示已续签。说明电脑/桌面 App 关闭期间无法保证执行，以及模型运行使用账号用量。
- [ ] 提交 `docs: add Codex scheduled maintenance workflow`；把实际创建状态、时间及首次运行结果写入本地进度记录，只有非敏感使用说明进入远程仓库。
