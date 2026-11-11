# iOS composer attachments

## Intent and authority

The user requested the Android reference's input features in the current iOS app after discussing text editing, image selection/address entry, clipboard images, and ordinary files. Include clipboard images and ordinary file imports even though the reference does not implement them. The user's earlier instruction to proceed directly still applies; use the existing native Swift/iOS and Windows bridge architecture and inline implementation.

## Behavior

- Both an existing conversation and the independent new-task form support native selection/copy/cut/paste of text.
- Pasting an image creates an attachment. A plus menu offers photo selection, Files selection and image address entry. File URLs or file data supplied by the clipboard become attachments when available from iOS; ordinary text and web URLs retain native text-paste behavior.
- Image addresses support HTTP(S), image data URLs and an existing image path inside the selected Windows project. A remote URL is passed to Codex, never fetched by the bridge. Local phone images are normalized to PNG/JPEG.
- Show attachment names, removal, image/file preview and uploading/error state. The conversation editor keeps build5's fixed height and internal scrolling, including Dynamic Type; attachments have a bounded scrolling strip above it.
- Text and attachments persist per connection and per conversation/new-task project. Cover installation keeps existing text-only drafts. Attachments alone are sendable. A failed upload or failed/unknown command retains the draft; accepted commands remove only submitted attachments and unchanged submitted text. Later edits survive.
- Uploading alone never sends a model instruction or acquires a thread writer. A navigation/background change during upload prevents subsequent automatic input submission and retains the draft.

## Builder defaults

Use at most10 attachments per submission, each at most20MiB. Import bounded data into Application Support; retain server files so historical references continue to work. Enforce limits before sending and at the authenticated server. No new third-party libraries or signing entitlements. No push-notification or renewal-schedule changes.

The pinned native schema has images and text but no general file input part. Uploaded images use native localImage, HTTP(S) images use native image, and ordinary files are saved on Windows with explicit filename/path references in the text input so Codex can read them with its existing tools. Do not claim native PDF/Word binary ingestion or execute uploaded files in the bridge.

## Contracts and boundaries

POST /v1/attachments accepts JSON {id,projectId,name,kind,base64?,location?}; kind is image, file, imageURL or serverImage. Return {id,name,kind,size}. UUID idempotency compares project and content; conflicting reuse returns409. Binary payloads are bounded, base64 is strict, stored names derive from UUIDs, and metadata is atomic/durable across bridge restart. Server-image paths must resolve to a regular image inside the selected project. Do not accept a client-selected destination path.

task/create and task/input gain optional attachments: UUID[]. Validate maximum/count/UUIDs and require nonempty text or attachments. Resolve all attachments against the authorized project before thread/start or turn submission. An unknown/wrong-project attachment fails without sending a turn. Native start/steer policy and the existing UUID operation journal remain intact. Advertise features.attachments only with the deployed implementation.

Swift BridgeTransport gains uploadAttachment with a default unsupported implementation for older fixtures/transports. ComposerModel imports/persists local attachments, snapshots a submission, uploads through CommandSender, checks current context after the upload, and submits only IDs through the existing operation journal. The native UITextView wrapper preserves normal text editing and receives images/files only on explicit paste; it does not poll or read the clipboard on app launch outside test fixtures.

## Verification

Test durable/idempotent storage, malformed/oversized input, project boundaries, failed atomic writes, authenticated HTTP routing and real native payloads. Test draft upgrade/isolation, attachment-only input, failed/unknown submission retention, accepted partial clearing, concurrent edits, navigation during upload and clipboard type discrimination. UI tests must exercise native text paste, image paste, attachment preview/remove/relaunch/send and fixed editor height, alongside all100 existing tests. Retain screenshots, archive an unsigned arm64 build6, verify its exact source/hash/build/lock, update only the owned bridge worker, and obtain actual phone photo/Files/clipboard checks.
