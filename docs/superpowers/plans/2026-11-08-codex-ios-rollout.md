# Codex iOS Remote Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付能接入 Windows 共享 Codex CLI 任务的个人原生 iOS 客户端。

**Architecture:** CLI 与桥接连接同一 app-server；iOS 经 EasyTier 连接桥接，使用快照和事件游标同步。先通过实时接管与真机签名验证，再完成首版功能。按下面三个子计划顺序实施，每部分都可独立验收。

**Tech Stack:** Codex CLI 0.167.0；Windows PowerShell 5.1+；Node.js 22.22.0、TypeScript；SwiftUI、iOS 16.0+；GitHub Actions macOS。

**Spec:** [用户已确认的完整设计](../specs/2026-11-08-codex-ios-remote-design.md)

## Global Constraints

- 个人自用，原生 iOS App；不采用 PWA。
- Windows 原生 PowerShell；CLI 基线 0.167.0；不参与或重启用户的独立旧任务。
- EasyTier；普通 Apple 账号，七天签名，云端编译、Windows 本地签名。
- 不做锁屏远程提醒，不集成 Bark 或其他通知客户端。
- 定时维护在 Codex 桌面端的本地定时任务中；未指定时间，不提前创建任务。

## Review Focus

1. CLI 已经等待审批时第二客户端加入：必须收到仍有效的请求；Windows W2 实测。
2. 写请求已发送但响应丢失：不能自动重发产生重复工作；Windows W5 故障注入。
3. 手机恢复时桥接游标已失效：重新取快照，不能拼接旧事件；Windows W4、iOS I3。
4. 中文、空格和 shell 元字符出现在项目路径/输入：保持参数原义；Windows W3。
5. 免费重签覆盖更新：服务器配置、Keychain 令牌和草稿保持；iOS I2、维护 M1 真机实测。

## 子计划与执行顺序

| 顺序 | 子计划 | 可独立验证的交付物 |
| --- | --- | --- |
| 1 | [Windows 共享任务与桥接](2026-11-08-windows-bridge.md) W1–W2 | 两个协议客户端与原生 CLI 的接管验证报告 |
| 2 | [iOS 与云端构建](2026-11-08-ios-client.md) I1；[安装维护](2026-11-08-install-maintenance.md) M1 的首次安装步骤 | 最小真机 IPA 与普通账号首次安装 |
| 3 | Windows W3–W7 | 有认证、可同步和可控制的桥接服务与 PowerShell 启动器 |
| 4 | iOS I2–I7；M1 的覆盖更新检查 | EasyTier 真机连接、数据保留与可实际操作已有任务的原生首版客户端 |
| 5 | 维护 M2–M3；iOS I8 | 实际续签证据、维护脚本、端到端验收与运行说明 |

- [ ] 在执行前建立隔离工作区，保留 main；按子计划完成独立提交，不创建一次性巨型提交。
- [ ] W2 出现实时接管/旧审批/退出 CLI 后任务中断问题时，停止后续控制功能，提交真实诊断并修订架构；不以读历史或另起任务替代。
- [ ] I2/M1 证明真机安装、EasyTier 连接后，再扩展完整 UI；手机信任、开发者模式和 Apple 验证由用户在设备/本地工具完成。
- [ ] 对真实 Codex 执行的验证使用隔离临时项目与现有 Windows 登录；使用可用模型，不硬编码账户未提供的型号。
- [ ] 产品验收以前，不将单测通过、模拟器通过或 IPA 文件存在描述成真实接管或续签成功。
- [ ] 每部分验证通过后提交并推送到已授权私有仓库；涉及用户设备、输入 Apple 验证和确定调度时间时，明确列出需要用户完成的动作。

## 首版覆盖核对

| 设计要求 | 实施任务 |
| --- | --- |
| 共享任务、晚加入、双端审批、CLI 退出任务继续 | W1–W3、W6、I5、I8 |
| 配置、认证、项目、模型与多服务端切换 | W3、W6–W7、I2、I4、I7 |
| 历史、草稿、流式过程、子任务及文件 diff | W4、W6、I3–I4、I6 |
| steer/queue/interrupt、幂等和冲突 | W5–W6、I5 |
| 断线恢复、后台挂起、版本不兼容 | W1、W4、W7、I3、I7–I8 |
| 云端编译、普通账号安装、覆盖更新和七天续签 | I1–I2、M1–M2 |
| Codex 调度、证据区分、安装诊断文档 | M2–M3、I8 |

后续功能仍按设计第 5 节划分；本次计划不加入图片上传、插件管理或远程锁屏推送。

## 执行选择

建议本次由主代理逐项执行（Native）：三个部分依赖同一协议与真机验证，顺序推进便于在早期失败时及时调整。子代理逐任务实现和独立审阅也是可选方式，但每项都会增加独立上下文与审阅开销。用户尚未选择执行方式。
