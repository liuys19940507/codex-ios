# History pagination and overflow navigation

The user reports that 源潜-上下板机项目 cannot load earlier records and requests moving Tasks, Connections and Settings from the fixed bottom tabs into a top-right ellipsis menu. Their earlier direct implementation/inline execution instruction still applies. Continue SwiftUI/iOS16+, native Windows Codex0.167.0 and GitHub Actions. Preserve build6 and its pending phone attachment acceptance; carry that device check into the next cover installation.

## Observed cause

Read-only probes found the requested thread, with17 turns and over1660 cached items. The native turns catalog reported no earlier turn. Thirty-three local history pages returned unique items; subsequent upstream pages returned50/50 duplicates. Sync incorrectly treats resume.itemsBackwardsCursor (a hydration starting position near the newest items) as continuation after initialTurnsPage. The page's own nextCursor is the correct indication of remaining turns. Diagnostics retain counts, IDs and timings only, not conversation text or credentials. One cold request timed out; subsequent requests returned in roughly70–190ms. Do not claim that every phone symptom has been reproduced: a concise symptom question remains pending.

## History behavior

Use the initial turns page's continuation, not the separate item hydration cursor. When that turns page has no continuation, local cached pages must end with no further cursor. For a partial turns page, fetch older turns via thread/turns/list, one full turn per native request. Return at most50 items to the phone; cache overflow as older history. Mark internal turn continuations with a private encoded prefix; preserve the existing opaque external cursor/string API and legacy item-cursor path.

Include the oldest visible item anchor in new upstream cursors. Serve already-cached predecessors before making another native request. Merge fetched history with a fresh snapshot so live items, policy and thread state win over old data. Advance the stored continuation only if it still matches the boundary fetched; concurrent readers cannot regress it. Local continuation uses the current stored boundary. Skip empty native turn pages up to a bounded request budget, reject repeated native continuations, and preserve retryable failures.

Show the actual number of newly added records after loading, including an explicit earliest-record message when exhausted. A manual history load should reveal an earlier row if one was added; preserve fixed editor height, drafts and live-follow behavior.

## Navigation behavior

Remove TabView and the persistent bottom bar. Use one NavigationStack with a type-erased NavigationPath so existing string-valued thread/child links keep working. Add a rightmost ellipsis menu to the task list, conversation, Connections and Settings. Its entries are 任务, 连接, 设置. Tasks returns to the task list; the other entries replace the current route with the selected section. Existing refresh, interrupt and newest-output actions remain available. Modal editors keep their current close/cancel controls.

A WorkspaceNavigator owns the path and routes menu selections. Before finishing a section switch, leave the selected conversation with its exact attachment UUID. Return-to-root/back handling also releases it. Durable text/attachment drafts remain untouched; a delayed release must not affect a later attachment. The disconnected pairing screen retains its current behavior.

## Verification and delivery

Write regression tests first for the terminal hydration cursor, genuine older-turn continuation, pages larger than50, concurrent readers/live changes and empty pages. Add iOS navigation/release and history feedback tests, plus UI menu and draft-retention checks. Run focused RED evidence, complete Node/typecheck and iOS suites, one fresh review of this new range, then a full arm64 build7. Independently verify source/tests/hash/build/platform/lock and screenshots. If backend code changes, restart only the identity-verified bridge worker; never stop native app-server or user CLI tasks. Repeat the targeted live pagination probe after deployment. Obtain actual phone earlier-history/menu/retained-draft checks with the new package.
