# Windows 共享任务与手机桥接

运行环境为原生 Windows PowerShell、Node22.22.0和Codex CLI0.167.0。使用 npm 安装的原生 codex.exe；配置须填写完整绝对路径。不能把 WSL 的二进制交给此启动器。

先在 bridge 目录执行 `npm ci`。将以下配置另存到仓库外的私有目录；路径只是示例，应替换为实际目录。

```json
{
  "codexExe": "C:/path/to/codex.exe",
  "stateDir": "C:/ProgramData/CodexRemote/Bridge",
  "codexPort": 8390,
  "bridgeHost": "10.147.21.2",
  "bridgePort": 8391,
  "projects": [{"id": "codex_app", "name": "Codex iOS", "path": "D:/other/codex_app"}]
}
```

`bridgeHost` 必须是本机已经存在的 EasyTier 地址；地址消失会明确失败，不回退到所有网卡。运行目录会限制为当前 Windows 用户可读。`codex-token` 仅用于本机上游，`bridge-token` 用于手机，两者独立。不要把令牌写进 URL、项目配置或 Git。

从仓库根目录运行：

```powershell
.\scripts\windows\Start-CodexRemote.ps1 -ConfigPath C:\ProgramData\CodexRemote\Bridge\runtime.json -ProjectId codex_app
```

此入口复用或启动独立 app-server 和手机桥接，再进入原生远程 CLI。退出 CLI 或关闭 PowerShell 窗口不会停止它们。手机只控制同一共享 app-server 中的任务；普通入口已在其他进程中运行的任务不会被此脚本迁移。

启用自动项目发现时，在私有运行配置加入 `"discoverProjects": true`。桥接从同一 Codex 数据目录的已有会话中发现工作目录；手机可以选择全部项目或单一目录。关闭或省略此项时继续只允许 `projects` 中配置的根目录。该选项没有扫描整块磁盘，也不会合并 WSL 或另一个 `CODEX_HOME` 的账号数据。

共享启动器现在可以省略 `-ProjectId`，使用终端当前目录；也可传 `-ProjectPath`。静态模式下仍会检查目录属于已配置根目录。

```powershell
.\scripts\windows\Start-CodexRemote.ps1 -ConfigPath C:\ProgramData\CodexRemote\Bridge\runtime.json
```

本机经本人确认，PowerShell 的 `codex` 函数已改用 `Start-CodexDefault.ps1`，同时保留原 profile 备份。新开 PowerShell 即可使用；当前窗口可以执行 `. $PROFILE` 重新加载。日常 `codex`、`codex resume <会话ID>` 进入共享服务并保留当前目录。维护命令、显式指定的其他远程连接、`--no-daemon` 和备用 `CODEX_HOME` 继续按原生方式运行，桥接令牌只注入需要它的本机共享子进程。

手机进入会话会建立带 UUID 的订阅，工具栏刷新会重新同步历史并尝试连接；返回任务列表释放该订阅，不发送中断。如果独立 CLI 进程仍持有写入锁，手机只读显示历史，需退出电脑端那个独立会话后再刷新。共享 CLI 与手机可以同时连接。原生服务只会卸载空闲且没有其他订阅者的会话，运行中任务继续执行。

仅启动后台桥接，不新建模型任务：

```powershell
node bridge/node_modules/tsx/dist/cli.mjs bridge/scripts/bridge-control.ts --config C:/ProgramData/CodexRemote/Bridge/runtime.json
```

手机地址为 `http://10.147.21.2:8391`，令牌从私有运行目录的 `bridge-token` 在本机复制。先保持 EasyTier 已连接，再在 App 中“添加连接”。初次配置验证只读取 `/v1/info`，不会发送模型输入。运行和签名验证见 [live-attach](validation/live-attach.md) 与 [signing](validation/signing.md)。

防火墙命令需要管理员 PowerShell；安装脚本不自动执行。仅允许 EasyTier 网段连接本机虚拟地址：

```powershell
New-NetFirewallRule -Name CodexRemoteBridge-EasyTier -DisplayName 'Codex Remote bridge (EasyTier)' -Direction Inbound -Action Allow -Protocol TCP -LocalAddress 10.147.21.2 -LocalPort 8391 -RemoteAddress 10.147.21.0/24 -Profile Any
```

桥接断开上游后会让旧事件游标失效并重新连接。未知操作结果只查询回执和任务状态；不会重发输入或审批。停止或重启原生 app-server 可能影响任务，须先核对自有任务；停止桥接本身不停止 app-server。此版本尚未配置系统服务或登录启动，后续维护步骤另行记录。

### iOS HTTP address scope

Apple's current NSExceptionDomains documentation permits individual IP exceptions on iOS17+. This personal build permits plaintext HTTP only for10.147.21.2, carried by the encrypted EasyTier network; other endpoints keep normal ATS rules and trusted TLS validation. No global NSAllowsArbitraryLoads setting is enabled. Device HTTP/WS behavior is still verified separately during pairing.

References: https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsexceptiondomains and https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking
