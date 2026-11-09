# Native iOS Client and Cloud Build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付可由普通账号侧载、通过 EasyTier 操作共享 CLI 任务的 iOS 16.0+ 原生客户端。

**Architecture:** SwiftUI 展示状态，actor 管理网络和本地持久化；iOS 消费 Windows 子计划的 DTO 与快照/事件接口。XcodeGen 在云端 macOS 生成项目，模拟器测试与未签名真机产物分开构建。

**Tech Stack:** Swift 5 语言模式、SwiftUI、Foundation、Security、XCTest、URLSessionWebSocketTask；XcodeGen；GitHub Actions 的 macos-15 runner。XcodeGen 版本在 I1 验证后固定，不使用未经验证的最新 beta Xcode。

**Spec:** [设计第 3、5–9 节](../specs/2026-11-08-codex-ios-remote-design.md)；[Windows 契约](2026-11-08-windows-bridge.md#文件地图与跨计划契约)。完整 UI 依赖 W2 通过和 W7 接口可用；I1 的最小构建可先独立执行。

## Global Constraints

- 原生 SwiftUI，最低 iOS 16.0；个人自用；不改成 PWA。
- 通过已安装的 EasyTier 连接 Windows；配置多个服务端，但只保持一个活动连接。
- Keychain 保存令牌，文件保存普通配置与草稿；普通账号、Windows 本地签名，稳定 Bundle ID。
- 不申请 APNs、后台持续保活、VPN 或 App Group entitlement，不做锁屏远程提醒。
- 未获上游确认不标记发送成功，重连不能自动重发有副作用请求。

## Review Focus

1. 不同服务端同名 thread 与旧连接迟到事件：I2/I3 保持命名空间和连接代次隔离。
2. 游标失效与历史分页锚点重复：I3 重新快照、I4 去重不丢草稿。
3. 等待审批期间手机进入后台且 CLI 已处理：I5/I7 恢复后禁用旧请求。
4. 未知工具类型、超长 Unicode 输出和文件 diff：I6 可读展示且不中断整个会话。
5. 重签、覆盖更新、低系统版本和 ATS：I1/I2 单测与 M1 真机；不假定模拟器等同手机。

## 文件地图与接口

`ios/project.yml` 生成 `ios/CodexRemote.xcodeproj`，scheme `CodexRemote`，目标 `CodexRemote`、`CodexRemoteTests`、`CodexRemoteUITests`。Bundle ID 固定 `com.liuys.codexremote`，iOS 16.0，Swift 5.0 语言模式；应用显示名 `Codex Remote`，基础界面使用系统组件、动态字体与浅/深色适配。

源码放 `ios/CodexRemote/`：`Connection/` 管配置、凭据和 transport；`Sync/` 管快照/事件与状态；`Threads/` 管列表、历史和草稿；`Composer/` 管输入和审批；`Activity/` 管工具与 diff；`Settings/` 管模型及连接。共享 DTO 统一在 `Models/BridgeModels.swift`，字段与 Windows 契约一致，JSONValue 为 Codable/Sendable enum；不要直接解码完整上游 Codex schema。

测试使用 `contracts/fixtures/` 中真实 bridge DTO；I1 创建最小 fixture，W6 落地后以 bridge 校验过的样例替换并同时运行两端测试。公共响应模型补充 `ServerInfo {apiVersion,serverId,codexVersion,features}`、`Project {id,name,path}`、`ModelOption {id,name,reasoning}`、`ThreadPage {data,nextCursor}`、`ItemPage {data,nextCursor}`，与 Windows JSON 对应。

协议 `BridgeTransport: Sendable` 提供 `get<T:Decodable & Sendable>(_ path:String, as:T.Type) async throws -> T`、`command(_ command:Command) async throws -> Operation`、`events(after:Cursor?) -> AsyncThrowingStream<EventFrame,Error>`、`close() async`。EventFrame 为 `.event(Envelope)` 或 `.resyncRequired`。URLSessionTransport 使用 bearer header，明确拒绝不支持的 scheme 或带 URL 用户名/密码的地址。

当前只有 Windows 开发环境，iOS 红绿测试通过实施分支的路径限定 push CI 执行；可以提交测试红阶段到实施分支，最终仅整合通过的版本。workflow_dispatch 供工作流登记后手动重跑，不假定尚未注册到默认分支的新工作流可以直接 dispatch。所有 red/green 运行使用明确 commit，并保留 xcresult。

### I1: 可测试、可生成真机 IPA 的最小原生应用

**Files:** Create `ios/project.yml`, `ios/CodexRemote/App/CodexRemoteApp.swift`, `ios/CodexRemote/Models/BridgeModels.swift`, `ios/CodexRemote/Resources/Info.plist`, `ios/CodexRemoteTests/ContractTests.swift`, `ios/CodexRemoteUITests/LaunchTests.swift`, `scripts/ci/test-ios.sh`, `scripts/ci/package-ios.sh`, `.github/workflows/ios.yml`, `contracts/fixtures/info.json`；Modify `.gitignore`。

**Interfaces:** Produces scheme CodexRemote、跨端 Codable DTO、产物 `CodexRemote-unsigned.ipa`；项目生成使用 `xcodegen generate --spec ios/project.yml`，生成的 xcodeproj 忽略，project.yml 跟踪。

- [ ] 编写 `testDecodesContractInfo`、`testUnknownJSONFieldsAreIgnored`、`testAppLaunches`；关键断言 `XCTAssertEqual(info.apiVersion,1)`、`XCTAssertTrue(app.staticTexts["连接尚未配置"].exists)`。先通过实施分支 push 的 simulator job 观察缺少模型/入口导致 FAIL，不为这一任务单列空项目提交。
- [ ] 实现最小“连接尚未配置”入口和模型；引入无图片上传、无通知 entitlement 的 XcodeGen 项目。CI 中安装已验证版本 XcodeGen；GitHub Actions 本身固定完整提交 SHA，权限只读内容，不注入 Apple 凭据。
- [ ] `test-ios.sh` 从 simctl JSON 选择可用的 iOS runtime 和 iPhone 类型，创建名称 `CodexRemote-CI` 的临时模拟器；执行 `xcodebuild test -project ios/CodexRemote.xcodeproj -scheme CodexRemote -destination 'platform=iOS Simulator,name=CodexRemote-CI' CODE_SIGNING_ALLOWED=NO`。Expected: XCTest 全部 PASS，上传 xcresult，清理仅本次创建的模拟器。
- [ ] `package-ios.sh` 执行 Release、`-sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO` 的 archive，验证 archive 中 `CodexRemote.app` 的 Mach-O 含 arm64；复制进临时 `Payload/`，用 `ditto -c -k --keepParent Payload CodexRemote-unsigned.ipa` 打包。Expected: `unzip -l` 有 Payload/CodexRemote.app/Info.plist，缺失架构/目录时 FAIL，不能使用 simulator .app。CI 保留产物 14 天；push 仅匹配 ios、scripts/ci、contracts/fixtures 和此 workflow 文件，同时提供 workflow_dispatch；测试与产物明确对应 commit。
- [ ] 两个构建 job 成功后提交 `build: add unsigned iOS app and macOS CI`；仅有 IPA 不代表已安装，立即安排 M1 首次安装关卡。

### I2: 服务端配置、Keychain 与真实连接关卡

**Files:** Create `ios/CodexRemote/Connection/{ServerConfiguration,CredentialStore,ServerStore,URLSessionTransport,ServerEditorView}.swift`, `ios/CodexRemoteTests/{ConnectionTests,PersistenceTests}.swift`, `docs/validation/ios-install-network.md`。

**Interfaces:** `ServerConfiguration:Codable,Identifiable,Sendable {id:UUID,name:String,baseURL:URL}`；CredentialStore 提供 `save(token:String,serverID:UUID) throws`、`load(serverID:UUID) throws -> String?`、`delete(serverID:UUID) throws`；ServerStore 提供 `load() throws -> [ServerConfiguration]`、`save(_ servers:[ServerConfiguration]) throws`；URLSessionTransport 满足公共协议。

- [ ] 编写 `testTokenIsNotInConfigFile`、`testCredentialNamespacesAreIndependent`、`testAtomicConfigWriteSurvivesFailure`；关键断言 `XCTAssertFalse(configJSON.contains("test-token"))`、`XCTAssertEqual(try credentials.load(serverID:otherID),"other-token")`。补测认证 header host、错误地址；使用测试 adapter，不读取用户真凭据。
- [ ] 在 I1 simulator test job 先看到 ConnectionTests/PersistenceTests FAIL。
- [ ] 实现系统 Keychain（解锁后可用的本设备访问属性）及原子 JSON 写入；不设置自定义 Keychain access group。实现单个活动 URLSession 连接与可编辑配置。只启用真机验证确有必要的最小 ATS/本地网络权限；不全局关闭 ATS，不接受任意 TLS 证书。
- [ ] 测试 PASS 后，在已完成 W7 的 Windows 服务和 iPhone EasyTier 上填写地址/令牌，读取真实 `/v1/info`；记录系统版本、HTTP/WS、认证和权限结果。需要 WSS 时配置可信证书后重试；不能只靠模拟响应达标。
- [ ] 覆盖安装同 Bundle ID 的第二个构建，确认配置/Keychain 保留（与 M1 配合）；提交 `feat: add secure server pairing and transport`。

### I3: 手机端快照与事件状态机

**Files:** Create `ios/CodexRemote/Sync/{SessionStore,EventReducer,SyncState}.swift`, `ios/CodexRemoteTests/SyncTests.swift`。

**Interfaces:** `@MainActor final class SessionStore:ObservableObject` 提供 `connect(server:ServerConfiguration) async`、`selectThread(_ id:String) async`、`disconnect() async`；发布 snapshot、connectionState（disconnected/connecting/syncing/connected/failed）和 currentServerID。纯函数 `reduce(snapshot:Snapshot,event:Envelope) -> Snapshot`。

- [ ] 测试 `testDeltaAppliedOnce`、`testSequenceGapRequestsSnapshot`、`testOtherThreadAdvancesGlobalCursor`、`testEpochMismatchResyncs`、`testOldConnectionCannotMutateNewServer`、`testSnapshotDoesNotLoseConcurrentDelta`；关键断言 `XCTAssertEqual(snapshot.items.first?.text,"haha")`（不同 cursor 的相同片段）、`XCTAssertEqual(cursor.seq,lastReceivedSeq)`；同 cursor 重放不重复、旧连接无效，gap 时必须重新快照。
- [ ] simulator job 运行指定 SyncTests，先 FAIL。
- [ ] 实现连接 generation、快照/事件屏障、游标持久化及显式 resync；使用 Windows 契约明确的规范化事件类型，在过滤当前 thread 前推进全局游标。每次切服关闭旧流，待确认操作独立于会话缓存，不在重连路径自动提交。无当前快照时显示 syncing，不显示虚假的最新状态。
- [ ] 同一测试集 PASS；重放 W6 样例得到与 bridge 相同的 item ID、文本、当前 turn 和待处理请求。
- [ ] 提交 `feat: reconcile iOS snapshots and event streams`。

### I4: 项目会话、历史与草稿

**Files:** Create `ios/CodexRemote/Threads/{ThreadListModel,ThreadListView,ConversationView,DraftStore}.swift`, `ios/CodexRemoteTests/ThreadTests.swift`。

**Interfaces:** ThreadListModel 提供 `reload(projectID:String?,query:String) async`、`loadMore() async`；DraftStore 提供 `read(serverID:UUID,threadID:String) throws -> String`、`write(_ text:String,serverID:UUID,threadID:String) throws`。新任务草稿使用保留 threadID `__new__:<projectId>`。

- [ ] 编写 `testLatestSearchWins`、`testHistoryAnchorDeduplicates`、`testDraftNamespacesAndRestart`；关键断言 `XCTAssertEqual(resultQuery,latestQuery)`、`XCTAssertEqual(Set(itemIDs).count,itemIDs.count)`、`XCTAssertEqual(restoredDraft,"中文\n第二行")`。失败与空列表分别展示。
- [ ] ThreadTests 在 simulator job 先 FAIL。
- [ ] 实现项目过滤、搜索、历史分页和本地草稿，点击会话使用 I3 同步；提供新任务入口、重命名和归档 UI，实际副作用通过 I5 命令接口执行。未配置服务端时保留可进入的连接设置。
- [ ] 测试 PASS；UI test 验证搜索、进入会话和返回列表后草稿保留，动态字体最大档主要操作仍可用。
- [ ] 提交 `feat: browse projects and persist conversation drafts`。

### I5: 输入、中断、审批及不确定结果

**Files:** Create `ios/CodexRemote/Composer/{CommandSender,ComposerView,ApprovalView,QuestionView}.swift`, `ios/CodexRemoteTests/CommandTests.swift`；Modify ThreadListModel/ConversationView 的操作入口。

**Interfaces:** `CommandSender.submit(method:Command.Method,params:[String:JSONValue]) async -> Operation`、`reconcile(id:String) async -> Operation`；生成 UUID 后在本地持久化，查询 `/v1/operations/:id`。`Command.Method` 的 rawValue 与 Windows 联合类型完全一致。

- [ ] 编写 `testSteerPinsTurn`、`testTimeoutQueriesWithoutRepost`、`testResolvedApprovalIsDisabled`、`testUnsupportedQueueKeepsDraft`；关键断言 `XCTAssertEqual(postCount,1)`、`XCTAssertEqual(receipt.state,.unknown)`、`XCTAssertEqual(capturedExpectedTurnId,activeTurnId)`。补测请求选项约束与 create 部分成功后不重复建任务。
- [ ] CommandTests 在 simulator job 先 FAIL。
- [ ] 实现文本发送/新建/重命名/归档/中断及审批表单；无 queue 能力时保留原文并显示“草稿，尚未提交”。pending/unknown 状态保留可核对入口；不自动把 unknown 改成成功。权限和 MCP 确认采用请求提供的字段，未知请求只读展示。
- [ ] 测试 PASS；真实 CLI 发起任务后手机追加一次指令并处理一次审批，确认 CLI 同步；以 W2 同 thread/turn 标准记录结果。
- [ ] 提交 `feat: control shared tasks and reconcile approval decisions`。

### I6: 工具活动、差异及子代理

**Files:** Create `ios/CodexRemote/Activity/{ActivityView,DiffView,ChildThreadView}.swift`, `ios/CodexRemoteTests/ActivityTests.swift`。

**Interfaces:** `ActivityPresentation.make(item:Item) -> ActivityPresentation`（title/body/status/kind）；`DiffPresentation.parse(_ text:String) -> [DiffLine]`（text/kind，kind 为 context/add/remove/header）；子会话使用 ThreadSummary.parentId 导航，仍由 I3 加载。

- [ ] 编写 `testUnknownActivityIsReadable`、`testDiffPreservesContent`、`testChildNavigationKeepsParentDraft`；关键断言 `XCTAssertFalse(presentation.title.isEmpty)`、`XCTAssertEqual(diffLines.map(\.text),expectedLines)`、`XCTAssertEqual(restoredParentDraft,originalDraft)`。覆盖长 Unicode、CRLF/无末尾换行、累计 diff；不把推理缺失当错误。
- [ ] ActivityTests 在 simulator job 先 FAIL。
- [ ] 实现只读命令/输出/计划/推理摘要/工具卡片、按文件 diff 与子任务导航；使用惰性列表和按需展开，不将整段大型输出一次嵌入单个富文本。
- [ ] 测试 PASS；UI test 大字体和长输出下可滚动、可复制文本、返回父任务状态正确。
- [ ] 提交 `feat: review activity diffs and child tasks`。

### I7: 模型设置与前后台恢复

**Files:** Create `ios/CodexRemote/Settings/SettingsView.swift`, `ios/CodexRemote/Sync/LifecycleController.swift`, `ios/CodexRemoteTests/LifecycleTests.swift`；Modify CodexRemoteApp。

**Interfaces:** `LifecycleController.setActive(_ active:Bool) async`；设置只保存服务端返回的 model ID 和允许的 reasoning 字符串，用于下一次 create；当前线程权限以服务端返回为准。

- [ ] 编写 `testForegroundResyncsBeforeWrites`、`testStaleApprovalAfterBackground`、`testUnsupportedApiCannotWrite`；关键断言 `XCTAssertEqual(postCountOnForeground,0)`、`XCTAssertFalse(staleApprovalIsEnabled)`、`XCTAssertFalse(canWriteToUnsupportedAPI)`。补测切服模型隔离及 epoch 核对。
- [ ] LifecycleTests 在 simulator job 先 FAIL。
- [ ] 接入 scenePhase 与连接生命周期，退出后台允许断线；重新激活后同步，再开放写入。无支持模型时呈现真实错误，不伪造默认型号。设置页区分离线与服务端失败，并只读展示 Snapshot.policy，null 显示未能确认，不写入新的权限策略。
- [ ] 测试 PASS；真机后台/锁屏一段时间后再进入，确认 Windows 任务继续、数据恢复，无推送或后台保活要求。
- [ ] 提交 `feat: restore foreground sessions and server settings`。

### I8: 端到端验收与运行说明

**Files:** Create `docs/validation/end-to-end.md`, `docs/ios-install.md`, `docs/troubleshooting.md`；Modify README；必要的修复回到对应任务测试。

**Interfaces:** Consumes W1–W7、I1–I7、M1–M3；Produces 每项为 PASS/FAIL/NOT RUN 的真实验收报告，注明测试系统、Codex 版本与 commit。

- [ ] 先执行 W2 和 I5 的真实复现用例，再执行手机掉线/切后台、桥接重启、双端重复审批、多项目 CLI、覆盖更新与至少一次实际续签；无法完成的项目不得勾选 PASS。
- [ ] 在 Windows `npm ci`、`npm test`、`npx tsc --noEmit`（bridge 目录逐项检查退出码）及 Pester 5.x 的 `Invoke-Pester -CI -Path scripts/windows/tests` 全部通过，云端 simulator suite/Release archive 全部通过。
- [ ] 验收文档中同任务指令追加和审批至少各一次；核对无重复 turn、手机断开不影响服务、普通账号安装有效。Windows 休眠/断电与离开续签电脑的限制准确写入说明。
- [ ] 更新 README 为真实已验证能力，链接安装、诊断与维护指南；提交 `docs: record verified iOS remote control workflow`，交付可签名 IPA 和源码。
