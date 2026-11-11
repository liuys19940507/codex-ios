# Composer Attachments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement inline, task by task. Preserve the current runtime worktree and branch.

**Goal:** Add persistent image and file input to both iOS composers without changing text editing, operation idempotency or shared CLI ownership.

**Architecture:** A bounded authenticated upload store maps attachment UUIDs to durable server files or image locations. The iOS draft store keeps local bytes and metadata independently of the existing text format. A native UITextView adds explicit rich paste; PhotosUI and fileImporter add selectors.

**Tech Stack:** Swift5/SwiftUI/UIKit/PhotosUI/UniformTypeIdentifiers/QuickLook, iOS16+, Node22.22/TypeScript, native Codex0.167.0.

**Spec:** docs/superpowers/specs/2026-11-10-composer-attachments-design.md

## Global Constraints

- Maximum10 attachments,20MiB each; no new dependency or signing requirement.
- Keep build5 text drafts, connection/token persistence, pins, fixed editor height and all existing operation/ownership contracts.
- Uploads do not attach a thread or send input; file references stay available after acceptance and bridge restart.
- Only restart the identity-verified bridge worker; preserve native app-server and user CLIs.
- Preserve the approved runtime worktree. The user explicitly selected switching back to GitHub Actions after confirming simulator support; use standard macos-15 with Xcode26.3, retain screenshots/recordings/results and keep Codemagic only as a fallback.

## Review Focus

1. A lost upload acknowledgement must not duplicate or silently replace an attachment: UUID/content idempotency and restart tests.
2. A task/project/navigation change during upload must not send to a stale conversation: context guard and project-bound resolution tests.
3. Accepted input must preserve later text/attachment edits; failed/unknown input must retain durable bytes: ComposerModel race/restart tests.
4. Clipboard text/URLs must stay text; image/file paste must use explicit user gestures: native editor classification and UI tests.
5. Malformed base64, oversized files, traversal/reparse paths and missing local files must fail before a model turn: storage, HTTP and command tests.

### Task 1: Durable Windows uploads and native input mapping

**Files:** create bridge/src/api/uploads.ts, bridge/tests/uploads.test.ts; modify api/server.ts, api/validation.ts, api/commands.ts, main.ts and tests/commands.test.ts, main.test.ts, api tests as needed.

**Interfaces:** createAttachmentStore(root) exposes async save(value:unknown, project:RuntimeConfig.projects[number]) and async resolve(ids:string[], projectId:string) returning AttachmentResource[]. validateUpload checks the request contract. ApiContext.uploads.upload(value) authorizes the project and calls save. Commands consume optional uploads and attachments UUIDs; attachmentInput(text,resources) builds native text/image/localImage parts, including ordinary-file path references.

- [ ] Write tests for durable bytes/Unicode names, same-id retries and conflicts, restart resolution, missing/wrong-project IDs, image signatures, strict base64/size/count/traversal boundaries and server-image scope.
- [ ] Run focused Node tests; observe actual RED before implementation.
- [ ] Implement the store, authenticated bounded POST route and capability; extend create/start/steer validation/mapping. Resolve before task creation.
- [ ] Verify focused tests, full Node suite and typecheck. Verify actual native schema mapping without a user-thread mutation; commit.

### Task 2: Persistent iOS attachment drafts and submission

**Files:** create Composer/DraftAttachment.swift, Threads/AttachmentDraftStore.swift, CodexRemoteTests/AttachmentTests.swift; modify ComposerModel.swift, CommandSender.swift, BridgeTransport.swift, URLSessionTransport.swift and UITestWorkspaceTransport.swift.

**Interfaces:** DraftAttachment is Codable/Equatable/Sendable with UUID id, name, kind and optional location. AttachmentDraftStore owns per-server blobs/manifests and produces AttachmentUpload DTOs. BridgeTransport.uploadAttachment(AttachmentUpload) returns UploadedAttachment; CommandSender forwards it. ComposerModel exposes attachments, importing/uploading state, import/remove/location methods and hasContent. submitInput/submitCreate snapshot attachments and accept a stillCurrent closure checked after upload, before any command.

- [ ] Add meaningful unit tests for old text upgrade, per-server/thread isolation, binary persistence, limits, missing/corrupt files, attachment-only params, failed/unknown retention, accepted-only clearing and edits/navigation during a held upload.
- [ ] Run focused iOS test workflow and observe RED; do not implement before its actual failure.
- [ ] Implement DTO/store/transport and model integration; maintain existing journal handling and default unsupported transport behavior.
- [ ] Run focused and existing relevant tests; commit after actual results.

### Task 3: Native paste editor, pickers and previews

**Files:** create Composer/PasteTextView.swift, Composer/AttachmentControls.swift, CodexRemoteUITests/AttachmentUITests.swift; modify ComposerView.swift and test fixture launch options.

**Interfaces:** PasteTextView binds text/focus, font size and editability, and calls explicit image/file paste import handlers; it has fixed external height/internal scrolling and a keyboard-dismiss action. AttachmentControls consumes ComposerModel and project ID, imports PhotosPicker/fileImporter data and handles image URL/server path entry, preview and remove. Both conversation and NewTaskForm use it.

- [ ] Add native-paste and attachment UI tests plus fixture-only clipboard preparation. Observe the missing behavior RED. Preserve both existing fixed-height tests.
- [ ] Implement bounded imports, explicit paste discrimination, attachment strip/preview/removal and visible progress/failures in both composers. No automatic clipboard polling.
- [ ] Verify screenshots and UI behavior, including native text editing and largest Dynamic Type; commit.

### Task 4: Full verification, deployment and phone delivery

**Files:** ios/project.yml build6, validation notes; CI workflow only if needed for the selected provider.

- [ ] Run full Node/typecheck and the complete iOS unit/UI suite plus arm64 archive; no filtered workflow may publish a release.
- [ ] Obtain one fresh review of this new plan's range, fix material findings with RED→GREEN and preserve the two previously deferred Minor items.
- [ ] Independently verify exact source, full actual test count, SHA256, build6/iphoneos/arm64 and full dependency lock; inspect screenshots and publish a separate build6 IPA.
- [ ] Deploy only the owned bridge worker after identity/listener checks. Verify capability, upload bytes and small native attachment smoke in an owned test task; preserve service identity/CLI work.
- [ ] Obtain actual phone cover-install/data-retention, photo/image-paste/Files/attachment send checks; record results and push documentation.
