# iPhone 连接验证

实际设备 iOS26.5，普通 Apple 账号通过 Windows Sideloadly 安装。此记录不包含账号、设备标识或令牌。

| 检查 | 结果 |
| --- | --- |
| 初始原生入口安装和打开 | PASS，用户确认看到“连接尚未配置” |
| 更新连接配置页 | PASS，提交582ac90的build2可打开并添加连接 |
| EasyTier 上的真实 HTTP | PASS，用户手动填入10.147.21.2:8391与配对令牌后确认“已连接”；该状态只在真实 /v1/info 校验apiVersion1后出现 |
| 真机 Keychain 写入及读取 | PASS，此保存流程先使用系统SecItem写入，再读取同一serverID令牌完成认证；无文件回退 |
| ATS 配置 | 仅为10.147.21.2设置HTTP例外；本次设备HTTP已成功 |
| 本地网络权限弹窗 | 未记录是否实际出现，不推断用户授权状态 |
| 真机 WebSocket 与任务同步 | NOT RUN，等待I3/I4连接界面接入 |
| 杀进程重开后的配置 / Keychain 保留 | NOT RUN |
| 具有已保存数据时的覆盖更新保留 | NOT RUN |
| 自动续签 | NOT RUN |

首次填写令牌后按钮禁用，是因为地址栏显示灰色示例但实际值为空；用户手动填写地址后连接成功。后续将预填此个人部署的地址并增加按钮启用回归，避免重复困惑。

build2实际IPA SHA-256：`ddfaeed59cf4d6dadcdd152c13e93f234c401fa3ce900bc87c8c515b1070ea76`。云端模拟器及arm64打包：[run42586465419](https://github.com/liuys19940507/codex-ios/actions/runs/42586465419)。
