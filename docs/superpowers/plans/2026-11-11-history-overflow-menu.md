# History Pagination and Overflow Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use superpowers:executing-plans inline, task by task. Keep the existing runtime-owned isolated worktree and branch. One fresh review of this plan's range at the end; no implementer agents.

**Goal:** Make earlier-history pagination truthful and usable, and replace fixed bottom tabs with the requested top-right menu.

**Architecture:** Distinguish native turns-page continuation from item hydration starts, cache older turn overflow behind the existing50-item API, and keep live snapshot fields authoritative. A WorkspaceNavigator drives one NavigationStack and releases conversation ownership on section navigation.

**Tech Stack:** Swift5/SwiftUI/UIKit, iOS16+, Node22.22/TypeScript, Codex0.167.0, GitHub Actions macos-15/Xcode26.3.

**Spec:** docs/superpowers/specs/2026-11-11-history-overflow-menu-design.md

## Global Constraints

- Preserve existing server identity/tokens, all drafts/attachments/pins and the fixed editor.
- Keep every phone history page at most50 items. External cursors remain opaque strings and remain scoped to thread/epoch.
- Keep existing thread/child NavigationLink string values working; remove the bottom TabView.
- Menu entries are 任务, 连接, 设置, available at the top right of main screens.
- Use attachment UUID guards when leaving a task. Never stop native app-server or user CLIs.
- Preserve build6; deliver a separately verified build7. Previous physical attachment checks remain pending until real user evidence.

## Review Focus

1. A complete initial turns page with a non-null hydration cursor must not advertise phantom older records.
2. Older turns larger than50 items, empty turns and concurrent history requests must progress without duplicates or missing items.
3. Live output/metadata or a refreshed epoch during a history request must remain authoritative.
4. Menu navigation away from a conversation, rapid re-entry and child links must release only the old selection and preserve drafts.
5. The menu must remain reachable without a bottom bar at large text sizes, and disconnected connection deletion must still return to pairing.

### Task 1: Correct bridge history continuation

**Files:** bridge/src/state/sync.ts, bridge/src/api/queries.ts, new bridge/src/state/history-boundary.ts, bridge/tests/queries.test.ts.

**Interfaces:** history-boundary exports encodeTurnsBoundary(cursor:unknown):string|null and decodeTurnsBoundary(value:string):string|null. Sync stores a tagged initialTurnsPage.nextCursor. Queries preserve external cursors, add an anchor to upstream cursors, merge older full-turn items into the current snapshot, and return bounded pages.

- [ ] Add tests for terminal hydration cursors,75-item older turns across50-item pages, concurrent reader reuse/live snapshot updates, and empty-page continuation/repeated-cursor rejection.
- [ ] Run focused Node tests and observe the actual assertions fail.
- [ ] Implement the source distinction and anchored cached continuation. Fetch one older turn, merge with current items winning, update only the matching boundary, and cap empty-page traversal.
- [ ] Run focused tests, full Node suite and typecheck. Commit and retain actual RED/GREEN logs.

### Task 2: Top-right workspace menu and history feedback

**Files:** new ios/CodexRemote/App/WorkspaceNavigation.swift, Threads/ThreadListView.swift, Threads/ConversationView.swift, Sync/SessionStore.swift, new CodexRemoteTests/WorkspaceNavigationTests.swift and CodexRemoteUITests/WorkspaceNavigationUITests.swift, update LaunchTests.swift.

**Interfaces:** WorkspaceDestination:Hashable has tasks/connections/settings. WorkspaceNavigator(session:) owns @Published path:NavigationPath and async show(_:). A view modifier/environment callback supplies the ellipsis menu only inside the connected workspace. SessionStore.loadMoreHistory keeps its signature and publishes newly added record counts/exhaustion.

- [ ] Write tests for section-switch release, returning to the task list, retained drafts, history deduplication count and retry retention; add UI menu/no-tab-bar/navigation checks and update the existing deletion test.
- [ ] Commit tests and run the focused GitHub Actions diagnostic; observe actual RED before implementing the new navigation type.
- [ ] Implement the navigator/menu, replace TabView with one NavigationStack and wire connection/settings destinations. Keep existing thread destinations and root-back release behavior.
- [ ] Add successful history feedback and reveal an earlier timeline row on manual loading. Preserve generation guards and failure retry behavior.
- [ ] Verify focused/full iOS results and menu screenshots; bump build7.

### Task 3: Review, deploy and deliver

**Files:** ios/project.yml, docs/validation/history-overflow-menu.md and operational validation artifacts.

- [ ] Obtain one fresh review of this plan's BASE..final candidate; re-grade and fix material findings in one tested pass, without re-reviewing prior phases.
- [ ] Complete full Node/typecheck and full iOS tests/arm64 archive on the final source. No filtered job publishes an IPA.
- [ ] Identity-check and update only the bridge worker if needed. Repeat the live named-thread history probe through its actual endpoint and preserve native PID/start time.
- [ ] Independently verify exact source, full test statistics, SHA256, build7/iphoneos/arm64, full dependency lock and required screenshots; publish a separate stable IPA.
- [ ] Obtain user phone checks for earlier records, the ellipsis menu, original connection/Chinese draft and attachment input; record actual results and push final documentation.
