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
| 真机 WebSocket 与任务同步 | PASS，2026-11-10 的9cba691：手机追加指令和批准一次命令，CLI 同一轮次执行；用户确认最终回复自动出现 |
| 杀进程重开后的配置 / Keychain 保留 | PASS，用户此前确认重开可连接；本次覆盖安装后原连接仍在且任务列表认证通过 |
| 具有已保存数据时的覆盖更新保留 | PASS，配置/Keychain在9cba691覆盖后保留；e3c5408/build3覆盖后中文/emoji草稿保留，后台和桥接重启后也保留 |
| 自动续签 | NOT RUN |

首次填写令牌后按钮禁用，是因为地址栏显示灰色示例但实际值为空；用户手动填写地址后连接成功。41687a9已预填个人部署地址并通过相关界面回归；连接按钮与编辑按钮现在具有独立点击区域。编辑器不回显已保存令牌，地址不变时留空会保留原令牌。

build2实际IPA SHA-256：`ddfaeed59cf4d6dadcdd152c13e93f234c401fa3ce900bc87c8c515b1070ea76`。云端模拟器及arm64打包：[run42586465419](https://github.com/liuys19940507/codex-ios/actions/runs/42586465419)。

已安装功能版本9cba691同为build2，IPA SHA-256：`3dca7818fe420604eb51b396670267775b8680b22f1b14b0fca4904abcd264e5`；[run42730023510](https://github.com/liuys19940507/codex-ios/actions/runs/42730023510)通过42项单元测试、5项界面测试和arm64打包。真机控制证据见[端到端记录](end-to-end.md)。
