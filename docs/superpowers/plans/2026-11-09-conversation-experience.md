# Conversation Experience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. User chose inline execution and waived further brainstorming/design approval with "直接做".

**Goal:** Reliable desktop/phone conversation handoff, all known projects and a readable native chat/task timeline.

**Architecture:** Extend the existing bridge API with idempotent subscription commands and optional read-only snapshot state. Track selected attachment identity independently of business-operation receipts. Discover project roots through native history with an opt-in runtime flag. Build pure presentation models under SwiftUI views; retain existing draft/sync/security paths.

**Tech Stack:** Codex0.167.0, Node22.22/TypeScript, Swift5/iOS16, SwiftUI, pinned MarkdownUI2.4.1 if its custom image handling/build compatibility passes inspection.

**Spec:** `docs/superpowers/specs/2026-11-09-conversation-experience.md`

## Global Constraints

- Native Windows PowerShell, personal single-user, EasyTier; ordinary Apple account.
- API1 backwards-compatible optional fields; never replay input/approval after uncertain outcome.
- Preserve token/Keychain/draft namespaces and shared native service. Do not terminate user CLI.
- Project discovery is native-session based and opt-in; static scoped mode stays default.
- No lock-screen push or scheduled renewal task. Do not execute reference repository code.

## Review Focus

- Late leave/reselect and pending attachment responses must not release a new screen (T1/T2 tests).
- An external CLI lock must retain history/draft and reject writes without automatic resubmission (T1/T2 tests).
- Same basenames, Windows path case and paginated projects must retain correct scope (T3 tests).
- Long/unfinished Markdown, terminal text, CRLF and Unicode must retain exact copied content (T4/T5 tests).
- Approvals, child navigation and reading older history must stay reachable through grouped activity and pinned composer (T5 UI tests).

### T1: Native subscription ownership and API

**Files:** bridge/src/state/sync.ts, api/{contracts,validation,commands,queries}.ts; bridge/tests/{sync,commands,queries}.test.ts.

**Interfaces:** `SyncService.attach(threadId,attachmentId):Promise<Snapshot>`, `release(threadId,attachmentId):Promise<Json>`; commands `thread/attach`, `thread/release` with UUID `attachmentId`; Snapshot optional `readOnlyReason:string`. Read snapshot cache only while subscribed; thread/closed invalidates readiness. A queued release verifies identity after inflight work; another/new attachment wins over stale release. Attach attempts resume at response barrier, falling back to read-only history only on exact native writer-lock conflict. Writes translate that conflict into a useful explicit rejection.

- [ ] Add failing tests: refresh rehydrates history, stale release ignored, release followed by snapshot reattaches loaded task, external writer fallback+write rejection, no interrupt/archive/stop calls.
- [ ] Run focused Node tests and observe RED, implement minimal state/API, rerun tests+typecheck GREEN, commit.

### T2: iOS conversation refresh and leave

**Files:** ios/CodexRemote/{Sync/SessionStore.swift,Sync/LifecycleController.swift,Threads/ThreadListView.swift,Threads/ConversationView.swift,Connection/*,Composer/*}; tests SyncTests.swift and conversation UI tests.

**Interfaces:** `SessionStore.refreshThread(_ id:String) async`, `leaveThread(_ id:String) async`, `canControl:Bool`; selected attachment UUID is stable across refresh/background and replaced on navigation. NavigationStack path changes own selection/release; ConversationView refresh is always present and preserves ComposerModel. Subscription commands do not enter business-command draft/retry logic. Do not unsubscribe solely because a sheet opens.

- [ ] Add failing tests for refresh/new history, leaving clears selection and sends exact release once, stale async leave vs new selection, external read-only disables input, background only restores subscriptions. Push Swift RED to macOS CI.
- [ ] Implement, add toolbar refresh/progress and read-only banner, run cloud tests GREEN, commit.

### T3: Discover and synchronize existing projects

**Files:** bridge/src/api/project-catalog.ts (new), runtime/config.ts, main.ts, state/store.ts, api/queries.ts, commands.ts; bridge/tests/project-catalog.test.ts (new), runtime/query tests; iOS ThreadListModel.swift/list.

**Interfaces:** optional RuntimeConfig.discoverProjects boolean; catalog refresh fetches paginated native thread/list for all sourceKinds, reconciles stable canonical absolute cwd roots into store and queries; static configured projects retained and configured IDs preferred on exact path. Project lists refresh before task lists and use correct directory labels.

- [ ] Add RED tests for two unrelated directories, nested roots, identical basenames, case/slash stability, pagination, malformed/non-absolute cwd and default static scope.
- [ ] Implement and run full Windows suite/typecheck; enable discovery in private local config only after real read-only verification. Commit.

### T4: Rich messages and inspectable code/output/diffs

**Files:** ios/CodexRemote/Activity/{ActivityView,RichMessageView,CodeOutputView,DiffView}.swift; new pure patch/presentation models; ios/project.yml; ActivityTests.swift.

**Interfaces:** raw Item.text retained; Markdown renderer/custom code block never transforms copy value and suppresses remote images; DiffDocument parses file/header/hunk lines into additions/deletions/partial markers with raw fallback.

- [ ] Add RED fixtures/tests for Markdown/code fencing, empty known items, reasoning summaries, multi-file patches, +++ inside hunk, CRLF, Unicode and truncated patches.
- [ ] Implement rich text/theme, language+copy/full viewer, terminal tail preview and file summaries; verify cloud unit/UI/device build and screenshots. Commit.

### T5: Turn activity timeline and persistent composer

**Files:** bridge/src/state/reducer.ts; ios/CodexRemote/Activity/ConversationTimeline.swift and ProcessView.swift (new); Threads/ConversationView.swift; Composer/ComposerView.swift; UITestWorkspaceTransport.swift; tests.

**Interfaces:** forward optional agent phase/duration; `ConversationTimeline.rows(items:[Item])` emits user/final messages and one process group per contiguous turn keyed by turnID. Pending requests stay outside collapsible process. Composer pinned in safeAreaInset with bounded multiline growth; new-task form remains usable. Follow bottom only when user near bottom, explicit latest button always available.

- [ ] Add RED tests for commentary/final/no-phase messages, same item IDs across pagination, empty metadata, pending forms and child navigation; add UI checks and screenshot attachments.
- [ ] Implement and verify tests/rendered simulator screenshots; update feature comparison and validation notes. Commit.

### T6: Verify, review and package

- [ ] Run Windows tests/typecheck/Pester and fresh macOS iOS unit/UI/device checks for final source. One fresh final reviewer for this new phase, resolve Important/Critical with tests; no repeated baseline review.
- [ ] Safely restart only the verified own bridge, verify native service and real project queries/handoff. Download exact CI artifact, verify hash, publish build4+ with install instructions and honest phone gates.
