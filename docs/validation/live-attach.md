# Shared CLI live attachment validation

Validated on Windows PowerShell, native Codex CLI **0.167.0**, Node **22.22.0**, 2026-11-08 UTC. These results concern an isolated, newly created project and our own app-server and CLI processes. No existing user task was stopped or migrated.

| Case | Result | Observation |
| --- | --- | --- |
| Late attachment to an active CLI turn | PASS | An independent authenticated RPC client read the exact CLI thread ID and in-progress turn ID; resuming rejoined them. |
| Pending approval created before attachment | PASS | `thread/resume` replayed `item/commandExecution/requestApproval`, retaining its original RPC ID and available decisions. |
| Approval from late client | PASS | The client accepted the exact captured command; one unique successful command completion arrived and the controlled marker contained `probe-ok`. |
| CLI exit preserves task | PASS | After terminating only the owned test CLI while approval was pending, the same shared task remained active, accepted approval, ran its 25-second command and completed. This tests abrupt CLI process exit; launcher/window-close checks are separate. |
| Duplicate response from another client | PASS | Another attached connection received the pending request; replying after resolution produced no second completion or marker modification during observation. |
| Disconnect and reconnect | PASS | A fresh connection retrieved the same completed turn. |
| User question / permission request / MCP elicitation | NOT RUN | Not triggered by this command probe. |
| Steer / interrupt | PASS | Follow-up W6 adapter probe steered the same active turn and observed that exact turn become interrupted. |
| Queue | Disabled | No validated queue adapter; client must retain a draft. |
| Rename / archive | PASS | W6 dispatcher renamed a controlled thread; archived thread was retrieved from the archived list. |
| iPhone / EasyTier task control | NOT RUN | First iOS26.5 installation and launch passed; authenticated bridge pairing remains pending W7/I2. |

The final live probe returned `passed: true` with `sameLiveTurn`, `lateApproval`, `cliExitPreservesTask`, `duplicateResponseIgnored` and `reconnectRestoresState` all true. Its synthetic contract tests passed 3/3; deliberately disabling fake-server approval replay made those assertions fail. Synthetic results are not the basis of the live conclusions above.

## Windows launcher follow-up

The implemented runtime started and reused the same owned native app-server instance, authenticated successfully, and restricted its capability-token file ACL to the current Windows user. Six runtime contract tests and two Pester 5.7.1 tests passed, including capture in an actual native process for Chinese, spaces, shell metacharacters, embedded quotes, an empty argument and trailing backslashes. Child credentials did not replace the parent environment.

A real PowerShell launcher connected a CLI and created a controlled thread. Its first 45-second sleep completed. A follow-up 60-second sleep turn was started by RPC in that same CLI-created thread. While the acknowledged turn was in progress, only the verified test PowerShell host and its CLI child tree were terminated. The separately started shared server remained healthy, and a new authenticated client retrieved the exact follow-up turn as completed with one successful command. This validates abrupt launcher-host closure; it does not yet validate the HTTP bridge or EasyTier.

The [staged implementation review](implementation-review.md) subsequently fixed three recovery defects with RED-to-GREEN regressions. The current suite is 21/21 Node tests plus 2/2 PowerShell tests; the earlier case counts above describe the tests at their original checkpoints.

One automated input attempt in the Codex TUI was not accepted during this session; a separate real native console diagnostic received input correctly through both direct and wrapped launch. The follow-up lifetime test therefore used RPC, as stated above. Broader TUI keyboard interaction remains a separate manual check.

## Protocol findings

- Initialize each connection and send `initialized` before application requests.
- Subscribe before resuming. Pending server requests can arrive **after** the resume response, including with `excludeTurns: true`; the response is not a pending-request replay barrier. The probe waits for its expected request with a deadline.
- Use `thread/read` for metadata and `thread/turns/list` for turn data. Full-history hydration is deprecated. Existing approvals are replayed as server requests, not a `pendingRequests` property of the response.
- Rejoin loaded threads with only their ID and pagination options. Do not override their approval or sandbox policy.
- Closing a transport does not establish whether a write succeeded. Observe server state; never blindly replay a write.

## Additional W4 gate: incomplete live-stream prefix

**FAIL for immediate complete streaming recovery.** A second connection joined after the third delta of a controlled 400-line response. Both paged full-item resume and legacy full-history resume omitted the message currently being streamed. In the full-history trial, the original client received 1,999 deltas and the late client 1,985. The canonical message had 13,199 characters; the late stream assembled only 13,101, with the same message ID. A further paged trial reproduced these counts.

**PASS for completed-message replacement.** In the further paged trial, the late client received the full `item/completed` message and it exactly matched the original client's canonical message. This supports explicitly showing a partial prefix until a complete item arrives; it does not make the original immediate-recovery requirement pass.

The [proposed behavior amendment](../superpowers/specs/2026-11-08-live-stream-recovery-amendment.md) is awaiting confirmation. W4 storage/sync and subsequent product-control work remain gated. The synchronous RPC response boundary itself passed its regression test; it cannot recover text absent from the upstream snapshot.

Reproduce using `bridge/scripts/probe-snapshot-race.ts` against an idle isolated thread. Create `probe-stream.json` in its temporary project containing `{"threadId":"<test-thread>","allowTestTurn":true}`. Supply `--url`, `--token-file`, `--project`, `--thread` and `--mode paged` or `--mode full`. The probe starts one text-generation turn, records counts without message bodies or tokens, and returns exit code 1 when immediate prefix recovery fails. It is intentionally excluded from automatic tests and never runs against a user thread by default.

## Reproduction

Start an authenticated loopback `codex app-server` in a separate process and connect an actual `codex --remote` CLI. In a new empty project, request only a command writing `probe-ok` to `marker.txt` then waiting 25 seconds, with read-only sandbox and on-request approval. Capture the CLI thread/turn, its PID, and the exact pending approval command before closing that controlled CLI.

Store a local `probe-cli.json` in that temporary project with `threadId`, `turnId`, `cliPid`, and `command`. It is evidence for a controlled test, not a product configuration. The probe refuses to approve a different command or project and requires the recorded CLI to have exited. Keep the capability token outside tracked files.

```powershell
cd bridge
npx tsx scripts/probe-live-attach.ts --url ws://127.0.0.1:18390 --token-file <local-token-file> --project <temporary-project>
```

The probe sends an approval for the exact recorded command. Run it only against the isolated test. It does not create tasks or stop any process itself. Unobserved cases remain NOT RUN, and failed core checks return exit code 1.


## 已确认修订后的同步实现验证

用户已确认“部分输出，消息结束后补齐”的修订。2026-11-09 UTC，使用原生 Codex 0.167.0、独立临时项目和自有 loopback app-server，对新 SQLite/同步适配器执行真实测试：

- 同一个 thread/turn 中途接入：PASS。
- 接入后收到部分输出并标记 prefixComplete=false：PASS。
- 原客户端观察到 900 个增量；完整助手消息为 6,599 个字符。
- 新同步适配器收到结束事件后，按同一个 item ID 替换为完整内容，逐字符与原客户端一致：PASS。
- 受控回合完成后才关闭两个测试客户端并停止本次自有 app-server。

这验证了已批准的修订行为，不表示未完成消息此前的前文能立即恢复，也不表示已完成 iPhone 控制或真机安装。取消且没有完整结束内容时继续显示不完整提示。

## W6 business adapter follow-up

The real dispatcher on native0.167.0 passed steering, interruption, rename, archive and single-use command approval. The controlled approval wrote only marker.txt inside the isolated probe project; no existing user task was changed. The archive verification initially filtered only appServer sources, but this host classified the controlled thread as vscode; read-only verification using the full supported source set found the archived thread. This was a probe-filter error, and product queries already use that full set.

The probe found and fixed a real subscription bug: thread/started is a global announcement, so it cannot mark an independent client as subscribed. A regression first failed with zero resume calls, then passed after readiness was restricted to the snapshot/resume barrier. New threads without a first turn can lack a persisted rollout; the live attachment probe therefore joins an already streaming task, matching the takeover use case. Empty pre-turn hydration is not claimed as verified.

File approvals, questions, requested permission subsets and typed MCP forms have protocol/schema tests. Their real native request-generation paths remain untriggered; URL/verification/openai-form MCP flows remain read-only. Queue is disabled. Shared JSON fixtures are synthetic, contain no credentials, and are decoded by both Node and Swift tests.

## W7 authenticated EasyTier entry

On2026-11-09, the actual PowerShell launcher reused native Codex0.167.0 and started/reused the detached bridge at10.147.21.2:8391. The native --help exit check returned0 without creating a model task; the independent app-server remained running. Existing W3 tests cover task survival, while this check covers the new bridge startup integration.

From the Aliyun node10.147.21.1, an unauthenticated HTTP request returned401; the bearer-authenticated /v1/info returned apiVersion1 and codexVersion0.167.0 with the expected persistent serverId. Credentials were transferred in a temporary root-only curl config and then cleared on both machines. The bridge listens only on the Windows EasyTier address, with a Node-specific inbound TCP8391 rule limited to10.147.21.0/24. The phone was not connected during this check; real iOS HTTP/WS pairing remains pending.

An initial worker launched through the tsx CLI exited after its short-lived startup parent. The production worker now imports the pinned TypeScript loader directly into the detached Node process; a real process regression verifies that the returned PID is the server's PID. The actual worker then remained available after parent exit and passed the cloud-to-Windows check. No existing user process was stopped; only the owned diagnostic bridge was restarted, and the shared app-server was preserved.
