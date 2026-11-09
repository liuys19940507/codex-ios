# Codex iOS Remote

面向个人使用的原生 iOS 客户端项目，用于远程查看和操作 Windows PowerShell 中由共享 Codex app-server 承载的任务。

目前处于设计阶段，尚无可安装的 App 或已实现的桥接服务。

## 方案方向

- 原生 iOS 客户端，建议采用 SwiftUI。
- Windows 共享 app-server、PowerShell 启动器与桥接程序。
- 通过 EasyTier 连接 iPhone 与 Windows 电脑。
- 使用普通 Apple 账号，云端 macOS 编译、Windows 本地签名安装。
- 首版关注已有任务接管、流式进度、追加指令、审批、提问及文件差异。
- 首版不包含锁屏远程提醒。

## 设计文档

[完整设计与待验证关卡](docs/superpowers/specs/2026-11-08-codex-ios-remote-design.md)

完整设计已确认。[实施计划与三个子计划](docs/superpowers/plans/2026-11-08-codex-ios-rollout.md)已整理，产品实现尚未开始。

已有任务的实时接管、双端审批同步、免费签名安装和续签流程均需按文档验证，不能把接口存在视为已验证可用。

## 参考

功能参考 [hebo6/codex-android](https://github.com/hebo6/codex-android)。本项目为独立的非官方客户端项目，与 OpenAI 无关联或背书。
