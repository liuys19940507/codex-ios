# 普通 Apple 账号安装与续签

本项目的云端构建只生成未签名的真机 IPA。签名在 Windows 的 Sideloadly 中完成；Apple 登录和手机验证由本人在工具/设备上完成，仓库和 GitHub Actions 不需要 Apple 凭据。

## 首次安装

1. 从对应提交的 [iOS Actions 构建](https://github.com/liuys19940507/codex-ios/actions) 下载 `CodexRemote-unsigned-<commit>` 产物并解压。使用其中的 `CodexRemote-unsigned.ipa`，保留 `commit.txt` 便于核对版本。它是 iOS 16.0+、arm64 真机包，不能直接双击安装。
2. 从 [Sideloadly 官方网站](https://sideloadly.io/) 准备 Windows 64 位版本，并按官网要求准备 Apple 的 Windows 配对组件。当前官网要求网页版本的 iTunes/iCloud；已有 Microsoft Store 版本时，先核对官方兼容说明，再由本人决定处理现有软件。项目脚本不会卸载软件。
3. USB 连接并解锁 iPhone，在手机上确认信任电脑。确认 Sideloadly 的设备列表能看到手机。
4. 将 IPA 拖入 Sideloadly，使用普通 Apple 账号签名，按本地界面完成登录/验证码。保持应用标识 `com.liuys.codexremote`，不要每次生成新的自定义标识，开启该应用的自动刷新选项。
5. 按提示在手机的“设置 → 通用 → VPN 与设备管理”信任开发者。iOS 16+ 还需要在“设置 → 隐私与安全性 → 开发者模式”开启并按设备提示重启确认。参照 [Apple 开发者模式说明](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)。
6. 在手机实际打开 Codex Remote。最小版本应显示“连接尚未配置”；首次安装只有实际打开后才能记为通过。在[验证记录](validation/signing.md)记录构建提交、iOS 版本和结果。

## 覆盖更新与自动刷新

更新时使用同一个 Apple 账号和同一个 Bundle ID，直接覆盖安装，保留自动刷新选项。先检查配置、Keychain 凭据和中文草稿仍在；不要为了更新先卸载应用。官方的[更新与刷新说明](https://sideloadly.io/faq)解释了同账号/标识覆盖安装和自动刷新条件。

普通账号每次签名有效期为七天，开发者模式不会延长这个期限。自动刷新仍需要电脑和后台进程运行，且设备通过 USB 或已配置的 Wi-Fi 配对可被发现；EasyTier 的业务网络连接不等于 Apple 设备配对。

首次 USB 安装后，可在 iTunes 中启用该设备的 Wi-Fi 同步，再验证 Sideloadly 可以无线发现并刷新。长时间离开可配对的电脑超过签名有效期，应用可能无法打开，需要再次签名。后台进程存在不代表某次刷新已成功，应核对签名工具的结果和手机能否打开。

Codex 本地定时任务只检查并维护已有刷新后台进程，不模拟 Apple 登录或承诺续签成功。定时任务的执行时间和时区需另行指定；当前尚未创建。
