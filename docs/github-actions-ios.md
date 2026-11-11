# GitHub Actions iOS 构建

当前使用 [.github/workflows/ios.yml](../.github/workflows/ios.yml) 的标准 `macos-15` 机器，固定 Xcode26.3，运行 iOS 模拟器。仓库已公开。构建不会连接真实 iPhone，也不包含 Apple 签名；安装仍使用 Windows 上的 Sideloadly。

在 [Actions → iOS](https://github.com/liuys19940507/codex-ios/actions/workflows/ios.yml) 点击 Run workflow，选择 `feat/native-ios-remote` 分支。日常完整验证让 `only_testing` 留空。推送不自动启动 iOS 构建，同分支构建排队执行。

完整构建先运行所有单元/UI 测试，校验 xcresult 的实际结果和数量，全部通过后再归档 Release arm64 真机 IPA。下载页面中的两份产物：

- `ios-results-提交号`：测试统计、完整 xcresult、UI 截图及 Xcode 实际保留的录屏等附件。
- `CodexRemote-unsigned-提交号`：IPA、SHA256、对应提交号、完整依赖锁和测试统计。

产物保留7天。截图用于检查实际模拟器画面；这是自动测试记录，不能在 Actions 页面直接交互操作模拟器。完整 xcresult 可在 macOS 的 Xcode 中进一步检查。

诊断时可以填写 `only_testing`，例如 `CodexRemoteUITests/AttachmentUITests`。此时仅运行筛选的测试并保留诊断结果，成功也不会生成 IPA。完整构建与诊断构建不会同时发布安装包。

构建脚本仍沿用 `scripts/ci/codemagic-ios.sh` 这个文件名，它已作为两个 CI 平台共用的测试及打包入口；当前执行平台由工作流决定。
