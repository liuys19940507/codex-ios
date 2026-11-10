# Codemagic iOS 构建

本项目使用个人 Codemagic 账号的 Mac mini M2 构建机，Xcode 固定为26.3，复用仓库中的模拟器测试及未签名 arm64 IPA 打包脚本。配置位于根目录 [codemagic.yaml](../codemagic.yaml)。GitHub iOS 工作流保留为手动备用，当前不再由推送触发。

## 首次接入

1. 使用已有 GitHub 账号登录 [Codemagic](https://codemagic.io/login)，选择 Personal account。
2. 在 Applications 添加私有仓库 `liuys19940507/codex-ios`，使用 YAML 配置。需要时只授权该仓库。
3. 点击 Start new build，选择分支 `feat/native-ios-remote`，工作流 `ios-verify-package`。配置目前在这个开发分支，不能选择旧的 main 分支构建新版。

目前采用手动或 API 启动构建；没有自动构建 webhook，避免每次推送重复消耗额度。个人 M2 免费额度和超额费率以 [Codemagic 当前规则](https://docs.codemagic.io/billing/pricing/) 为准；本配置不启用付费机型、团队订阅、Apple 签名或商店发布。

## 测试与产物

工作流先验证构建脚本的失败处理，再安装带 SHA256 校验的 XcodeGen2.46.0。随后运行所有 iOS 单元和 UI 测试，读取 xcresult 统计，要求通过数大于0、失败数为0且结果为 Passed。测试进程或结果校验失败时不会打包，诊断文件仍会收集。

通过测试后再生成 Release arm64 IPA，检查 Bundle ID 和 iphoneos 平台。可在构建页面下载：

- `CodexRemote-unsigned.ipa`：未签名真机安装包。
- `CodexRemote-unsigned.ipa.sha256`、`commit.txt`、`Package.resolved`：校验值、对应提交与依赖版本。
- `ios-test-summary.json`、测试/打包日志：真实执行结果。
- `CodexRemote-tests.zip`：完整 xcresult。
- `ios-screenshots.zip`：截图、失败诊断和测试录屏。

普通 Apple 账号仍在 Windows 的 Sideloadly 中签名安装，不需要把 Apple 密码或证书放进 Codemagic。构建成功后仍需核对提交和哈希，并完成手机覆盖安装验证；本地脚本检查不代表 iOS 云端测试通过。

## API 接入

自动启动与查询使用 Codemagic 官方 API。个人 API token 在左侧底部头像的 Account settings → API token；旧版页面为 Integrations → Codemagic API。应用设置与 Personal Account 的团队式设置页面不是这个入口。

本机令牌文件为 `C:\ProgramData\CodexRemote\CI\codemagic-token.txt`，目录权限限制为当前 Windows 用户、SYSTEM 和管理员。令牌只通过 `x-auth-token` 请求头发送给 Codemagic 官方 API，不写入源码、日志或 URL。没有令牌时也可在网页手动启动并下载结果。

参考：[YAML 配置](https://docs.codemagic.io/yaml-basic-configuration/yaml-getting-started/)、[API 认证](https://docs.codemagic.io/rest-api/codemagic-rest-api/)、[构建接口](https://docs.codemagic.io/rest-api/builds/)。

## 本机已接入状态

Codemagic 应用 ID 为 `6af2b0d8392f5c83a397ccfd`，归属于个人账号。私有仓库通过 Codemagic 生成的专用 SSH 密钥连接，GitHub Deploy key 标题为 `Codemagic Codex Remote read-only`，仅允许读取 `codex-ios`。需要停用访问时，可在 GitHub 仓库 Settings → Deploy keys 中删除该条密钥。Codemagic 保存私钥，本机不转交个人 GitHub PAT。

首次使用通用仓库URL的构建在拉取代码前失败，未运行测试。补齐SSH连接后，审查前 `2114d7f` 的[成功构建](https://codemagic.io/app/6af2b0d8392f5c83a397ccfd/build/6af2cc88ac1033465782ed43)通过78项并生成已核验的历史IPA。审查修订后新增测试总数82，最近构建81项通过、审批UI一项失败，禁止交付旧IPA替代修订版本。当前 `ios-diagnose-approval` 工作流只采集失败用例调用栈，不打包；正常打包入口拒绝设置了测试筛选参数的运行。当前验证与手机安装状态见[会话验证记录](validation/conversation-experience.md)。
