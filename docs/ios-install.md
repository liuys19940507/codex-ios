# iPhone 安装与连接

此客户端供个人使用，连接 Windows 上的共享 Codex app-server。云端 macOS 生成 arm64 未签名 IPA，再由 Windows Sideloadly 用本人的普通 Apple 账号签名。

1. 在对应提交的 [iOS Actions](https://github.com/liuys19940507/codex-ios/actions) 下载 `CodexRemote-unsigned-<commit>`，解压并保留 `commit.txt` 和 SHA-256 文件。
2. USB 连接并解锁 iPhone，按手机提示信任电脑。打开 Sideloadly，点击左上角 IPA 图标选择真正的 `.ipa` 文件；左侧显示 `<none>` 表示尚未加载。
3. 使用原来的 Apple 账号和 Bundle ID 设置覆盖安装。不要卸载旧版。Apple 登录、验证码、开发者信任与开发者模式由本人在本地完成。
4. 保持手机和 Windows 的 EasyTier 连接，打开 App，连接已保存的 Windows。首次添加时，地址为 `http://10.147.21.2:8391`，配对令牌从 Windows 私有运行目录复制。
5. 在“任务”中刷新列表，打开共享 CLI 任务。新建任务只能选择 Windows 已配置的项目。原本由其他独立 Codex 进程运行的任务不会自动迁移到共享服务。

配置和操作标识按服务端隔离，令牌保存在系统 Keychain；草稿保存在手机本地。没有服务端确认的操作保留“结果尚未确认”，用“核对结果”读取回执，不自动重发。手动确认已核对并再次发送可能产生重复结果，先查看实际任务。

连接后，任务、连接、设置都从右上角“…”菜单进入，底部不再固定显示这三个入口。菜单中的“任务”返回列表；切换到连接或设置时会释放当前会话占用，草稿仍保存在手机。

“加载较早记录”每页最多读取50条原始记录，并显示实际新增数量。命令、处理中间输出等仍在“查看处理过程”中折叠；如果新读到的记录都属于同一轮处理过程，需要展开该卡片阅读。到达最早记录后不再继续显示加载按钮。

普通账号每次签名有效期仍为七天，开发者模式不延长有效期。无线刷新需要 Apple 的 Wi-Fi 配对，EasyTier 只承载 App 业务连接。具体签名步骤见[安装与刷新](signing-and-refresh.md)，实际设备结果见[签名记录](validation/signing.md)。
