# Codex iOS Remote

面向个人使用的原生 iOS 客户端项目，用于远程查看和操作 Windows PowerShell 中由共享 Codex app-server 承载的任务。

Windows 桥接与原生 SwiftUI 客户端已实现。真实 iPhone 已接入 PowerShell CLI 创建的运行中会话，在同一轮次追加指令、批准一次命令，并自动收到最终回复。覆盖安装后原连接与 Keychain 凭据保留。

项目列表、搜索、历史与草稿，新建/重命名/归档、发送/中断、审批/问题表单，以及工具输出、diff、子任务导航、模型设置和前后台恢复均有实现。云端模拟器与真机打包逐提交验证；仍需执行的设备关卡逐项记在[端到端记录](docs/validation/end-to-end.md)。

中途接入生成中的消息时，先标记部分输出，结束后用完整消息补齐；用户已接受并完成[恢复行为修订](docs/superpowers/specs/2026-11-08-live-stream-recovery-amendment.md)验证。Windows 配置及启动方式见[运行说明](docs/windows-setup.md)。

参考 Android 的[本轮改进](docs/android-reference.md)增加多项目发现、会话刷新与释放、按轮次折叠处理过程、Markdown/代码与文件差异视图和底部输入框。[验证记录](docs/validation/conversation-experience.md)区分自动检查、实际 Windows 验证和待执行的手机覆盖安装。

## 方案方向

- 原生 SwiftUI 客户端，最低 iOS16.0。
- Windows 共享 app-server、PowerShell 启动器与桥接程序。
- 通过 EasyTier 连接 iPhone 与 Windows 电脑。
- 使用普通 Apple 账号，云端 macOS 编译、Windows 本地签名安装。
- 首版关注已有任务接管、流式进度、追加指令、审批、提问及文件差异。
- 首版不包含锁屏远程提醒。

## 设计文档

[完整设计与待验证关卡](docs/superpowers/specs/2026-11-08-codex-ios-remote-design.md)

完整设计已确认，正在执行[实施计划与三个子计划](docs/superpowers/plans/2026-11-08-codex-ios-rollout.md)。

安装与日常操作见[iPhone 指南](docs/ios-install.md)；异常情况见[排查说明](docs/troubleshooting.md)。已验证的协议行为及未执行项见[真实接管报告](docs/validation/live-attach.md)。普通账号安装已通过，真实续签仍待验证。

[普通账号安装步骤](docs/signing-and-refresh.md)和[签名验证记录](docs/validation/signing.md)已准备。iOS 构建保存在实施分支的 [Actions 产物](https://github.com/liuys19940507/codex-ios/actions)。

已测试的[本地维护脚本与 Codex 提示词](docs/codex-maintenance-task.md)报告进程和签名证据。用户选择暂不创建定时任务。

## 参考

功能参考 [liuys19940507/codex-android](https://github.com/liuys19940507/codex-android)（源自 [hebo6/codex-android](https://github.com/hebo6/codex-android)）。本项目为独立的非官方客户端项目，与 OpenAI 无关联或背书。
