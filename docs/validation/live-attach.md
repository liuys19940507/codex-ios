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
| Steer / interrupt / queue | NOT RUN | Must be separately proven before enabling these capabilities. |
| iPhone / EasyTier / signing | NOT RUN | This is loopback protocol validation only. |

The final live probe returned `passed: true` with `sameLiveTurn`, `lateApproval`, `cliExitPreservesTask`, `duplicateResponseIgnored` and `reconnectRestoresState` all true. Its synthetic contract tests passed 3/3; deliberately disabling fake-server approval replay made those assertions fail. Synthetic results are not the basis of the live conclusions above.

## Windows launcher follow-up

The implemented runtime started and reused the same owned native app-server instance, authenticated successfully, and restricted its capability-token file ACL to the current Windows user. Six runtime contract tests and two Pester 5.7.1 tests passed, including capture in an actual native process for Chinese, spaces, shell metacharacters, embedded quotes, an empty argument and trailing backslashes. Child credentials did not replace the parent environment.

A real PowerShell launcher connected a CLI and created a controlled thread. Its first 45-second sleep completed. A follow-up 60-second sleep turn was started by RPC in that same CLI-created thread. While the acknowledged turn was in progress, only the verified test PowerShell host and its CLI child tree were terminated. The separately started shared server remained healthy, and a new authenticated client retrieved the exact follow-up turn as completed with one successful command. This validates abrupt launcher-host closure; it does not yet validate the HTTP bridge or EasyTier.

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
