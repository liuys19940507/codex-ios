# Codex iOS Remote

面向个人使用的原生 iOS 客户端项目，用于远程查看和操作 Windows PowerShell 中由共享 Codex app-server 承载的任务。

正在按已批准计划实现。Windows RPC 与专用启动器已通过测试，真实共享 CLI 的晚加入接管、已有审批和 CLI/PowerShell 退出后任务继续运行已验证。iOS 最小应用已通过模拟器测试并生成未签名真机 IPA；它目前只有入口界面，尚未安装到手机。

W4 实测发现上游无法立即恢复正在输出消息的前文；[恢复行为修订](docs/superpowers/specs/2026-11-08-live-stream-recovery-amendment.md)待确认，完整桥接和手机控制界面尚未完成。

## 方案方向

- 原生 iOS 客户端，建议采用 SwiftUI。
- Windows 共享 app-server、PowerShell 启动器与桥接程序。
- 通过 EasyTier 连接 iPhone 与 Windows 电脑。
- 使用普通 Apple 账号，云端 macOS 编译、Windows 本地签名安装。
- 首版关注已有任务接管、流式进度、追加指令、审批、提问及文件差异。
- 首版不包含锁屏远程提醒。

## 设计文档

[完整设计与待验证关卡](docs/superpowers/specs/2026-11-08-codex-ios-remote-design.md)

完整设计已确认，正在执行[实施计划与三个子计划](docs/superpowers/plans/2026-11-08-codex-ios-rollout.md)。

已验证的协议行为及未执行项见[真实接管报告](docs/validation/live-attach.md)。免费签名安装和续签仍需真机验证。

[普通账号安装步骤](docs/signing-and-refresh.md)和[签名验证记录](docs/validation/signing.md)已准备。iOS 构建保存在实施分支的 [Actions 产物](https://github.com/liuys19940507/codex-ios/actions)。

## 参考

功能参考 [hebo6/codex-android](https://github.com/hebo6/codex-android)。本项目为独立的非官方客户端项目，与 OpenAI 无关联或背书。
