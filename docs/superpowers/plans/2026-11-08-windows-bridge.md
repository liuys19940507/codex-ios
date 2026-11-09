# Windows Shared Codex and Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 提供通过真实共享 Codex 验证的 Windows 桥接服务及安全保留参数原义的启动器。

**Architecture:** Codex 监听 loopback；CLI 和桥接是其两个客户端。桥接把上游协议映射为稳定的 HTTP/事件接口，在 SQLite 中保存投影及操作结果。

**Tech Stack:** Node.js 22.22.0、TypeScript、ws、tsx、node:test、node:sqlite；PowerShell 5.1+、Pester 5.x。依赖在 W1 安装时固定精确版本并提交 package-lock.json；node:sqlite 在此版本为 active development，限制在存储适配器内。

**Spec:** [设计第 3–7、9–10 节](../specs/2026-11-08-codex-ios-remote-design.md)

## Global Constraints

- Windows PowerShell、Codex CLI 0.167.0；不接管 WSL、终止旧任务或自动更改 Codex 权限。
- CLI 经专用启动器连接共享实例；桥接只经 EasyTier 地址接受手机连接，并要求令牌。
- 不提供独立通用 shell API，不做锁屏远程提醒。
- iOS 后台允许断线；任务在共享服务继续运行。
- 上游 WebSocket 为实验性接口，以锁定版本 schema 和 W2 实测为准。

## Review Focus

1. 晚加入时已有审批能获取且可处理：W2 真实接管，W6 过期请求测试。
2. 断线发生在上游已执行而响应未达时：W5 只记录 unknown，不自动重发。
3. 游标过期或桥接重启时：W4 明确 resync，W7 HTTP/WS 集成验证。
4. 中文、空格、分号、美元符号出现在路径/文本时：W3 验证进程参数数组原样传递。
5. 错误令牌、未配置项目及错误 thread/turn 组合：W6–W7 拒绝，不触发上游动作。

## 文件地图与跨计划契约

`bridge/src/protocol/` 负责上游 RPC 和按版本生成的 schema；`bridge/src/runtime/` 负责自有进程、配置和密钥；`bridge/src/state/` 负责投影与 SQLite；`bridge/src/api/` 负责手机 DTO、路由和校验；`scripts/windows/` 只做进程启动与维护入口。

在 `bridge/src/api/contracts.ts` 定义，之后导出真实 JSON 样例到 `contracts/fixtures/`，iOS 按同名字段解码：

```ts
type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
type Cursor = { epoch: string; seq: number };
type Item = { id: string; turnId: string; kind: string; text: string; data: Json };
type Pending = { id: string; threadId: string; turnId: string; kind: 'command'|'file'|'permission'|'question'|'mcp'; prompt: string; options: Json; state: 'pending'|'resolved'|'unknown' };
type ThreadSummary = { id: string; projectId: string; title: string; status: string; activeTurnId: string|null; parentId: string|null };
type Snapshot = { cursor: Cursor; thread: ThreadSummary; items: Item[]; itemsCursor: string|null; pending: Pending[]; policy: { approvalPolicy:string|null; sandbox:string|null } };
type Envelope = { cursor: Cursor; threadId: string; type: string; data: Json };
type Operation = { id: string; state: 'pending'|'accepted'|'failed'|'unknown'; result: Json; message: string|null };
type Command = { id: string; method: 'task/create'|'task/input'|'task/interrupt'|'request/respond'|'thread/rename'|'thread/archive'; params: { [key: string]: Json } };
```

`params` 是有校验的联合输入，不允许透传任意 RPC：create 使用 `{projectId,text,model?,reasoning?}`；input 使用 `{threadId,text,mode:'start'|'steer'|'queue',expectedTurnId?}`；interrupt 使用 `{threadId,turnId}`；respond 使用 `{requestId,threadId,turnId,response}`；rename 使用 `{threadId,title}`；archive 使用 `{threadId}`。项目 ID 映射配置中的绝对目录，手机不能直接指定任意 cwd。

HTTP 全部要求 `Authorization: Bearer <bridgeToken>`：`GET /v1/info` 返回 `{apiVersion:1,serverId,codexVersion,features}`；`/v1/projects` 返回 `{id,name,path}[]`；`/v1/models` 返回 `{id,name,reasoning:string[]}[]`；`/v1/threads?projectId&query&cursor` 返回 `{data:ThreadSummary[],nextCursor:string|null}`；`/v1/threads/:id/snapshot` 返回 Snapshot；`/v1/threads/:id/items?cursor` 返回 `{data:Item[],nextCursor:string|null}`；`POST /v1/commands` 返回 Operation；`GET /v1/operations/:id` 核对发送结果。

`WS /v1/events?epoch&after` 通过握手 header 认证，发送所有已观察会话的 Envelope；过期游标发送 `{type:'resync_required'}` 后结束该连接，手机重新读取快照。规范化事件类型为 `thread/upsert`（data 为 ThreadSummary）、`item/upsert`（Item）、`item/delta`（`{id,turnId,text}`）、`pending/upsert`（Pending）、`pending/resolved`（`{id}`）；未知类型为 `activity/unknown`（Item）。手机在过滤 threadId 之前推进全局游标。输入限制为 1 MiB JSON、64 KiB UTF-8 文本，历史每页 50 个 item。事件最多保留最近 10,000 条；桥接启动或上游重连需要全量重建时生成新 epoch；所有时间字符串使用 UTC ISO 8601。

错误统一 `{code,message}`：未认证 401、未知项目/会话 404、过期 turn/请求 409、字段无效 400、请求过大 413、上游暂不可用 503。令牌不出现在 URL、日志和 DTO 中。尚未取得上游确认的操作不得显示 accepted。

### W1: 可独立连接和分类消息的 RPC 客户端

**Files:** Create `bridge/package.json`, `bridge/package-lock.json`, `bridge/tsconfig.json`, `bridge/src/protocol/rpc-client.ts`, `bridge/src/protocol/generated/`, `bridge/tests/rpc-client.test.ts`, `bridge/tests/support/fake-server.ts`, `bridge/src/api/contracts.ts`。

**Interfaces:** Produces `connectRpc(url:string,token:string):Promise<RpcClient>`；RpcClient 提供 `request(method:string,params:Json):Promise<Json>`、`respond(id:string|number,result:Json):void`、`onEvent(handler:(msg:Json)=>void):()=>void`、`close():Promise<void>`。原始服务端请求 ID 与桥接 Pending.id 分开保存。

- [ ] 编写 `handshake_once`、`out_of_order_responses`、`server_request_with_id_is_not_response`、`overload_retry_reads_only` 测试；关键断言 `assert.deepEqual(handshake, ['initialize','initialized'])`、`assert.equal(serverRequests.length,1)`、`assert.equal(writeSends,1)`，并核对逆序响应仍匹配原请求。
- [ ] 在 `bridge/` 用 `npx tsx --test tests/rpc-client.test.ts` 验证测试因实现缺失而 FAIL；测试设施与 package 配置包含在此交付，不单列空脚手架任务。
- [ ] 从本机 0.167.0 执行 `codex app-server generate-ts --experimental --out src/protocol/generated`，记录版本；用 ws 实现 RpcClient 和上述类型；未知事件保留诊断类型而不崩溃，不记录正文/凭据。
- [ ] 同一命令必须 PASS；`npx tsc --noEmit` 必须成功。npm test 配置为 `tsx --test tests/*.test.ts`，之后所有 bridge 测试在 bridge 目录执行。
- [ ] 提交：`git add bridge; git commit -m "feat: add versioned Codex RPC client"`。

### W2: 真实 CLI 与晚加入客户端验证关卡

**Files:** Create `bridge/tests/integration/live-attach.test.ts`, `bridge/scripts/probe-live-attach.ts`, `docs/validation/live-attach.md`；Modify RPC 适配器中经实测确认的订阅方法。

**Interfaces:** Consumes RpcClient；Produces `probeLiveAttach(options:{url:string;tokenFile:string;projectDir:string}):Promise<{passed:boolean;checks:Record<string,boolean>;notes:string[]}>`。报告不保存令牌和用户项目正文。

- [ ] 编写 `late_attach_same_live_turn`、`late_approval_can_be_resolved`、`cli_exit_preserves_task`：关键断言 `assert.equal(a.threadId,b.threadId)`、`assert.equal(a.turnId,b.turnId)`、`assert.equal(executionCount,1)`、`assert.equal(taskContinuedAfterCliExit,true)`。任一端处理后另一端不能重复处理；未执行 case 标记 NOT RUN，不能 PASS。
- [ ] 先对假服务运行测试，刻意关闭请求重放验证测试能 FAIL；假服务不得用于最终可行性结论。
- [ ] 在隔离临时项目启动带认证的 loopback app-server，手动原生 `codex --remote` 发起受控长任务；按 0.167.0 schema 实现探针。把审批、用户问题、steer、interrupt、queue、重复响应和断线恢复逐项记入报告。
- [ ] 执行 `npx tsx scripts/probe-live-attach.ts --url <loopback> --token-file <local-file> --project <temporary-project>` 并记录真实 CLI 操作。核心同任务、晚审批、CLI 退出持续运行三项必须 PASS；否则停止 W3 后的产品控制功能并返回架构修订。
- [ ] 提交脚本、受控集成测试和脱敏报告，提交信息 `test: verify shared CLI live attachment`。不提交临时令牌/运行目录。

### W3: 可复用且不依赖 CLI 窗口存活的共享服务

**Files:** Create `bridge/src/runtime/config.ts`, `bridge/src/runtime/service.ts`, `bridge/tests/service.test.ts`, `scripts/windows/Start-CodexRemote.ps1`, `scripts/windows/Stop-CodexRemote.ps1`, `scripts/windows/tests/Launcher.Tests.ps1`。

**Interfaces:** Produces `ensureService(config:RuntimeConfig):Promise<ServiceInfo>`；RuntimeConfig `{codexExe:string,stateDir:string,codexPort:number,bridgeHost:string,bridgePort:number,projects:{id:string,name:string,path:string}[]}`；ServiceInfo `{instanceId:string,pid:number,codexUrl:string,bridgeUrl:string}`。默认端口 codex 8390、桥接 8391；stateDir 在当前用户 LocalAppData 下，令牌文件限当前用户可读。

- [ ] 编写 `reuse_owned_service`、`occupied_port_is_not_our_service`、`concurrent_launch_once`、`preserve_unicode_argument_boundaries`、`closing_cli_does_not_stop_server`；关键断言 `assert.equal(spawnCount,1)`、`assert.equal(unownedKillCount,0)`、`assert.deepEqual(capturedArgs,expectedArgs)`；`D:\项目 空格\a;&$b` 原样成为 cwd/参数。
- [ ] `npx tsx --test tests/service.test.ts` 应先 FAIL；PowerShell 假进程参数捕获测试也应先 FAIL。
- [ ] 实现明确配置的原生 codex.exe 路径检查与版本校验，以参数数组 spawn、互斥启动和实例健康标识管理自有进程；没有正确 exe 时明确提示配置，不能拼接 shell 命令或改 PATH。前台启动器使用 `& $CodexExe @CodexArgs`，只为子进程设置认证环境变量。后台启动采用隐藏窗口；显式 stop 先列出会受影响的自有任务，要求该次停止意图。
- [ ] Node 测试 PASS；`Invoke-Pester -CI -Path scripts/windows/tests/Launcher.Tests.ps1` PASS（失败必须有非零退出码）；另实测关闭 PowerShell CLI 窗口后 bridge/任务仍在运行。缺少 Pester 5.x 时只安装测试依赖，不改用户执行策略。
- [ ] 提交 `feat: add shared Windows Codex launcher`。

### W4: 一致快照、增量事件及 SQLite 恢复

**Files:** Create `bridge/src/state/store.ts`, `bridge/src/state/reducer.ts`, `bridge/src/state/sync.ts`, `bridge/tests/sync.test.ts`, `bridge/tests/fixtures/`。

**Interfaces:** Produces `openStore(file:string):Store`、`createSync(store:Store,rpc:RpcClient):SyncService`；SyncService 提供 `applyEvent(event:{connectionId:string,ordinal:number,message:Json}):Envelope|null`、`snapshot(threadId:string):Promise<Snapshot>`、`replay(cursor:Cursor):Envelope[]|'resync_required'`。适配器为每次上游连接生成 connectionId，并对接收帧递增 ordinal；用这对标识去重，不能用消息正文哈希。sync 订阅上游后缓冲事件，读取历史，再按 W2 捕获的真实快照边界串行归并；快照与游标在同一存储事务中产生。无法建立无重复无遗漏的快照边界时停止该关卡，而非猜测拼接。

- [ ] 测试 `snapshot_race_keeps_delta`、`duplicate_and_out_of_order_items`、`identical_text_distinct_frames_is_preserved`、`restart_changes_epoch`、`pruned_cursor_resyncs`、`corrupt_store_reports_error`。关键断言 `assert.equal(text,'haha')`（不同 ordinal 的两个 ha）、`assert.equal(sync.replay(oldCursor),'resync_required')`；同一 source ID 只处理一次，超过 10,000 条保留窗口要求重同步，SQLite 损坏不能默默清空任务。
- [ ] `npx tsx --test tests/sync.test.ts` 先 FAIL。
- [ ] 在 node:sqlite 适配器实现事务、游标和投影；持久化操作表与事件表分开。用 W2 脱敏协议样例测试命令、计划、diff、子代理和未知事件；数据库读写仅本地用户可访问。
- [ ] 同命令 PASS；`npx tsc --noEmit` 成功；回放同一脱敏流两次得到相同快照与文本。
- [ ] 提交 `feat: persist reconciled task snapshots and event cursors`。

### W5: 超时可核对、不会盲目重发的写操作

**Files:** Create `bridge/src/state/operations.ts`, `bridge/tests/operations.test.ts`。

**Interfaces:** Produces `executeOnce(command:Command,send:()=>Promise<Json>):Promise<Operation>`、`getOperation(id:string):Operation|null`。ID 为 UUID；重复 ID 必须核对 method/params 的稳定摘要，不同载荷返回 409。

- [ ] 测试 `duplicate_id_calls_send_once`、`same_id_different_payload_conflicts`、`sent_without_response_is_unknown`、`restart_preserves_unknown`；关键断言 `assert.equal(sendCount,1)`、`assert.equal(receipt.state,'unknown')`、`assert.equal(restored.state,'unknown')`，同 ID 不同载荷状态码为 409。
- [ ] `npx tsx --test tests/operations.test.ts` 先 FAIL。
- [ ] 实现发送前持久化 pending，明确上游确认后 accepted，明确拒绝 failed，无法判定 unknown。重启时把未决 pending 转 unknown，不发送；核对查询只读，不新增任务。
- [ ] 同命令 PASS；用假上游在已接收请求后切断连接，确认不会第二次提交。
- [ ] 提交 `feat: reconcile uncertain operations without duplicate execution`。

### W6: 项目、会话和当前请求的业务映射

**Files:** Create `bridge/src/api/commands.ts`, `bridge/src/api/queries.ts`, `bridge/src/api/validation.ts`, `bridge/tests/commands.test.ts`, `bridge/tests/queries.test.ts`, `contracts/fixtures/{info,projects,models,threads,snapshot,events,operations,errors}.json`。

**Interfaces:** Produces `dispatch(command:Command):Promise<Operation>`、`queryThreads(input:{projectId?:string,query?:string,cursor?:string}):Promise<{data:ThreadSummary[],nextCursor:string|null}>`、`querySnapshot(threadId:string):Promise<Snapshot>`，以及契约中的 projects/models/items 查询；只调用 W2 确认的上游方法。

- [ ] 编写 `expired_approval_conflicts`、`unconfigured_project_is_rejected`、`history_is_read_only`、`unicode_input_byte_limit`、`policy_is_not_overridden`，并覆盖子会话与分页；关键断言 `assert.equal(expired.status,409)`、`assert.equal(unknownProject.status,404)`、`assert.equal(historyWriteCount,0)`、`assert.equal(Buffer.byteLength(acceptedText,'utf8')<=65536,true)`。queue 不支持时返回 capability 错误。
- [ ] `npx tsx --test tests/commands.test.ts tests/queries.test.ts` 先 FAIL。
- [ ] 实现命令与查询适配，schema 校验、会话权限沿用和 feature flags；create 部分失败保留已有 threadId 供核对，不能自动另建 thread。加载中的会话按 W2 已验证方式订阅；未加载历史仅只读，直到用户发送输入才 resume/start。Pending 维护原 RPC ID，只转发服务端提供的批准选项。Snapshot.policy 仅包含已知 approvalPolicy/sandbox；上游无法确认则填 null，不读取或暴露全量配置/凭据。导出上述固定 DTO 样例供 iOS 使用。
- [ ] 同命令 PASS；全部样例通过 bridge 校验；`npx tsc --noEmit` 成功。
- [ ] 提交 `feat: expose validated task and approval operations`。

### W7: EasyTier 认证入口和可运行的 bridge

**Files:** Create `bridge/src/api/server.ts`, `bridge/src/main.ts`, `bridge/tests/http.test.ts`, `bridge/tests/events.test.ts`, `.github/workflows/bridge.yml`, `docs/windows-setup.md`；Modify `README.md`。

**Interfaces:** Produces `startBridge(config:RuntimeConfig):Promise<{close():Promise<void>}>` 及本计划定义的 /v1 HTTP/WS 接口；info.features 明确包括 steer/queue/approvals/childThreads，值必须来自已验证适配能力。

- [ ] 测试 `unauthorized_upgrade`、`oversized_body`、`invalid_json`、`upstream_unavailable`、`slow_consumer_resyncs`；关键断言 `assert.equal(unauthorized.status,401)`、`assert.equal(oversized.status,413)`、`assert.equal(unavailable.status,503)`、`assert.equal(logs.includes(testToken),false)`。补测错误游标 resync、禁止任意 RPC、日志不含输入正文。
- [ ] `npx tsx --test tests/http.test.ts tests/events.test.ts` 先 FAIL。
- [ ] 使用 node:http 与 ws 实现认证入口、请求限制、串行事件广播和优雅退出；EasyTier 地址不存在时明确失败，不自动绑定 0.0.0.0。添加仅本机可读的运行配置样例、明确的防火墙命令说明（不默认执行）。CI 在 Windows 使用 Node 22.22.0、`npm ci`、`npm test`、`npx tsc --noEmit`，默认测试不发模型请求。
- [ ] 在 bridge 目录 `npm test` 与 `npx tsc --noEmit` 全部 PASS；PowerShell 启动器真实启动后，从另一 EasyTier 设备访问认证 `/v1/info` 并记录；未测试手机时注明等待 I2。
- [ ] 提交 `feat: serve authenticated bridge over EasyTier`；更新 live-attach 报告后再进入完整 iOS 控制功能。
