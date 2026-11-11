import XCTest
import UIKit
import UniformTypeIdentifiers
@testable import CodexRemote

final class AttachmentTests: XCTestCase {
    @MainActor
    func testExistingTextDraftAndAttachmentBytesSurviveReopenAndStayScoped() async throws {
        let f = fixture(), drafts = DraftStore(root: f.root.appendingPathComponent("drafts"))
        try drafts.write("升级前草稿：中文😀", serverID: f.server, threadID: "thread")
        let model = ComposerModel(serverID: f.server, threadID: "thread", drafts: drafts)
        try await model.importData(Data("附件😀".utf8), name: "中文 文件.txt", kind: .file)
        let reopened = ComposerModel(serverID: f.server, threadID: "thread", drafts: drafts)
        XCTAssertEqual(reopened.text, "升级前草稿：中文😀")
        XCTAssertEqual(reopened.attachments, model.attachments)
        let store = AttachmentDraftStore(root: drafts.root.appendingPathComponent("attachments"))
        let payload = try store.payload(for: XCTUnwrap(reopened.attachments.first), serverID: f.server, projectID: "project")
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(payload.base64)), Data("附件😀".utf8))
        XCTAssertTrue(ComposerModel(serverID: f.server, threadID: "other", drafts: drafts).attachments.isEmpty)
        XCTAssertTrue(ComposerModel(serverID: UUID(), threadID: "thread", drafts: drafts).attachments.isEmpty)
    }

    @MainActor
    func testImportLimitsAndRemovalDoNotDamageAnExistingDraft() async throws {
        let f = fixture(), model = f.model
        try await model.importData(Data([1]), name: "one.txt", kind: .file)
        let original = model.attachments
        for (data, name) in [(Data(), "empty.txt"), (Data([1]), "../outside.txt"), (Data(repeating: 1, count: 20 * 1024 * 1024 + 1), "large.bin")] {
            do { try await model.importData(data, name: name, kind: .file); XCTFail("Invalid import accepted") } catch { }
        }
        XCTAssertEqual(model.attachments, original)
        for index in 1..<10 { try await model.importData(Data([1]), name: "\(index).txt", kind: .file) }
        do { try await model.importData(Data([1]), name: "eleven.txt", kind: .file); XCTFail("Count limit ignored") } catch { }
        XCTAssertEqual(model.attachments.count, 10)
        try model.removeAttachment(try XCTUnwrap(original.first).id)
        XCTAssertEqual(model.attachments.count, 9)
    }

    @MainActor
    func testImageAddressesHaveExplicitKindsAndDoNotBecomeText() async throws {
        let f = fixture()
        try await f.model.addImageAddress("https://example.invalid/picture.png", serverPath: false)
        try await f.model.addImageAddress("C:\\project\\图片.png", serverPath: true)
        XCTAssertEqual(f.model.attachments.map(\.kind), [.imageURL, .serverImage])
        XCTAssertTrue(f.model.text.isEmpty)
        do { try await f.model.addImageAddress("file:///etc/private.png", serverPath: false); XCTFail("Local URL accepted") } catch { }
        do { try await f.model.addImageAddress("https://name:password@example.invalid/a.png", serverPath: false); XCTFail("Credentials accepted") } catch { }
    }

    @MainActor
    func testAttachmentOnlyInputUploadsThenSubmitsStableIDsForInputAndCreate() async throws {
        for create in [false, true] {
            let f = fixture()
            try await f.model.importData(Data("only attachment".utf8), name: "only.txt", kind: .file)
            let id = try XCTUnwrap(f.model.attachments.first).id.uuidString.lowercased()
            XCTAssertTrue(f.model.hasContent)
            let result = create
                ? await f.model.submitCreate(using: f.sender, projectID: "project", features: ["attachments": true])
                : await f.model.submitInput(using: f.sender, snapshot: snapshot(), mode: .start, features: ["attachments": true])
            XCTAssertEqual(result?.state, .accepted)
            let uploads = await f.transport.uploads, posts = await f.transport.posts
            XCTAssertEqual(uploads.count, 1); XCTAssertEqual(uploads[0].projectId, "project")
            XCTAssertEqual(posts.count, 1); XCTAssertEqual(posts[0].params["attachments"], .array([.string(id)]))
            XCTAssertEqual(posts[0].params["text"], .string(""))
            XCTAssertTrue(f.model.attachments.isEmpty)
        }
    }

    @MainActor
    func testUploadFailureKeepsTextAndBytesWithoutPostingACommand() async throws {
        let f = fixture(behavior: .uploadFailure)
        f.model.text = "保留输入"
        try await f.model.importData(Data("keep bytes".utf8), name: "keep.txt", kind: .file)
        let result = await f.model.submitInput(using: f.sender, snapshot: snapshot(), mode: .start, features: ["attachments": true])
        XCTAssertNil(result)
        let posts = await f.transport.posts; XCTAssertTrue(posts.isEmpty)
        let reopened = ComposerModel(serverID: f.server, threadID: "thread", drafts: DraftStore(root: f.root.appendingPathComponent("drafts")))
        XCTAssertEqual(reopened.text, "保留输入"); XCTAssertEqual(reopened.attachments.count, 1)
        XCTAssertNotNil(f.model.message)
    }

    @MainActor
    func testFailedOrUnknownCommandsKeepAttachmentDrafts() async throws {
        for behavior in [AttachmentTransport.Behavior.failed, .unknown] {
            let f = fixture(behavior: behavior)
            try await f.model.importData(Data([1]), name: "keep.txt", kind: .file)
            let result = await f.model.submitInput(using: f.sender, snapshot: snapshot(), mode: .start, features: ["attachments": true])
            XCTAssertEqual(result?.state, behavior == .failed ? .failed : .unknown)
            XCTAssertEqual(f.model.attachments.count, 1)
        }
    }

    @MainActor
    func testAcceptanceClearsSubmittedAttachmentsButKeepsLaterTextAndFiles() async throws {
        let f = fixture(behavior: .heldCommand)
        f.model.text = "first"
        try await f.model.importData(Data([1]), name: "first.txt", kind: .file)
        let submittedFile = try XCTUnwrap(f.model.previewURL(XCTUnwrap(f.model.attachments.first)))
        let sending = Task { await f.model.submitInput(using: f.sender, snapshot: snapshot(), mode: .start, features: ["attachments": true]) }
        let posted = await f.transport.waitForCommand(); XCTAssertTrue(posted)
        f.model.text = "later 中文😀"
        try await f.model.importData(Data([2]), name: "later.txt", kind: .file)
        await f.transport.releaseCommand(); _ = await sending.value
        XCTAssertEqual(f.model.text, "later 中文😀")
        XCTAssertEqual(f.model.attachments.map(\.name), ["later.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: submittedFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(f.model.previewURL(XCTUnwrap(f.model.attachments.first))).path))
    }

    @MainActor
    func testLeavingDuringUploadDoesNotSendToTheOldConversation() async throws {
        let f = fixture(behavior: .heldUpload)
        try await f.model.importData(Data([1]), name: "draft.txt", kind: .file)
        var current = true
        let sending = Task { await f.model.submitInput(using: f.sender, snapshot: snapshot(), mode: .start, features: ["attachments": true], stillCurrent: { current }) }
        let started = await f.transport.waitForUpload(); XCTAssertTrue(started)
        current = false; await f.transport.releaseUpload(); _ = await sending.value
        let posts = await f.transport.posts
        XCTAssertTrue(posts.isEmpty); XCTAssertEqual(f.model.attachments.count, 1)
    }

    @MainActor
    func testOldServerAndMismatchedReceiptCannotSubmitAttachmentInput() async throws {
        for supported in [false, true] {
            let f = fixture(behavior: .wrongReceipt)
            try await f.model.importData(Data([1]), name: "draft.txt", kind: .file)
            _ = await f.model.submitInput(using: f.sender, snapshot: snapshot(), mode: .start, features: ["attachments": supported])
            let posts = await f.transport.posts; XCTAssertTrue(posts.isEmpty)
            XCTAssertEqual(f.model.attachments.count, 1)
        }
    }

    @MainActor
    func testMissingAttachmentBytesDoNotClearTheExistingTextDraft() async throws {
        let f = fixture(); f.model.text = "keep original"
        try await f.model.importData(Data([1]), name: "missing.txt", kind: .file)
        let item = try XCTUnwrap(f.model.attachments.first), file = try XCTUnwrap(f.model.previewURL(item))
        XCTAssertTrue(file.path.hasPrefix(f.root.path + "/")); try FileManager.default.removeItem(at: file)
        let reopened = ComposerModel(serverID: f.server, threadID: "thread", drafts: DraftStore(root: f.root.appendingPathComponent("drafts")))
        XCTAssertEqual(reopened.text, "keep original"); XCTAssertFalse(reopened.writable)
        XCTAssertNotNil(reopened.storageMessage)
    }

    @MainActor
    func testCorruptAttachmentManifestIsPreservedAndBlocksSubmission() async throws {
        let f = fixture(); f.model.text = "retained"
        try await f.model.importData(Data([1]), name: "keep.txt", kind: .file)
        let files = FileManager.default.enumerator(at: f.root, includingPropertiesForKeys: nil)!.allObjects.compactMap { $0 as? URL }
        let manifest = try XCTUnwrap(files.first { $0.path.contains("/attachments/") && $0.pathExtension == "json" })
        let broken = Data("{broken".utf8); try broken.write(to: manifest)
        let reopened = ComposerModel(serverID: f.server, threadID: "thread", drafts: DraftStore(root: f.root.appendingPathComponent("drafts")))
        XCTAssertFalse(reopened.writable); XCTAssertEqual(reopened.text, "retained")
        XCTAssertEqual(try Data(contentsOf: manifest), broken)
    }

    @MainActor
    func testClipboardClassificationKeepsTextAndWebURLsAsNativeText() {
        XCTAssertFalse(AttachmentMediaImport.canImport(NSItemProvider(object: "copy text" as NSString)))
        XCTAssertFalse(AttachmentMediaImport.canImport(NSItemProvider(object: NSURL(string: "https://example.invalid")!)))
        let file = NSItemProvider(item: URL(fileURLWithPath: "/tmp/example.pdf") as NSURL, typeIdentifier: UTType.fileURL.identifier)
        XCTAssertTrue(AttachmentMediaImport.canImport(file))
        XCTAssertTrue(AttachmentMediaImport.canPasteType(UTType.png.identifier))
        XCTAssertTrue(AttachmentMediaImport.canPasteType(UTType.pdf.identifier))
        XCTAssertFalse(AttachmentMediaImport.canPasteType(UTType.utf8PlainText.identifier))
        XCTAssertFalse(AttachmentMediaImport.canPasteType(UTType.url.identifier))
    }

    @MainActor
    func testOversizedProviderFilesAndImagesNeverFallBackToWholeDataLoading() async throws {
        let f = fixture(), file = f.root.appendingPathComponent("oversized.bin")
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        try Data([1]).write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(AttachmentLimits.bytes + 1)); try handle.close()
        for type in [UTType.pdf.identifier, UTType.png.identifier] {
            let provider = BoundedAttachmentProvider(file: file, type: type)
            await AttachmentMediaImport.add([provider], to: f.model)
            XCTAssertEqual(provider.fileLoads, 1)
            XCTAssertEqual(provider.dataLoads, 0, "A rejected bounded read must not load the entire provider payload")
            XCTAssertTrue(f.model.attachments.isEmpty)
            XCTAssertTrue(f.model.message?.contains("20MB") == true)
        }
    }

    @MainActor
    func testRemovedAndAcceptedAttachmentsReclaimPhoneBytesButFailedDraftsKeepThem() async throws {
        for behavior in [AttachmentTransport.Behavior.accepted, .failed, .unknown] {
            let f = fixture(behavior: behavior)
            try await f.model.importData(Data([1]), name: "cleanup.txt", kind: .file)
            let file = try XCTUnwrap(f.model.previewURL(XCTUnwrap(f.model.attachments.first)))
            _ = await f.model.submitCreate(using: f.sender, projectID: "project", features: ["attachments": true])
            XCTAssertEqual(FileManager.default.fileExists(atPath: file.path), behavior != .accepted)
            if behavior != .accepted {
                try f.model.removeAttachment(try XCTUnwrap(f.model.attachments.first).id)
                XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            }
        }
    }

    @MainActor
    func testFailedManifestAppendDoesNotOrphanANewPhoneBlob() async throws {
        let f = fixture(), drafts = DraftStore(root: f.root.appendingPathComponent("drafts"))
        let stale = ComposerModel(serverID: f.server, threadID: "thread", drafts: drafts)
        for index in 0..<10 { try await f.model.importData(Data([1]), name: "\(index).txt", kind: .file) }
        let directory = f.root.appendingPathComponent("drafts/attachments/\(f.server.uuidString)/files")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 10)
        do { try await stale.importData(Data([2]), name: "rejected.txt", kind: .file); XCTFail("Stale model bypassed the manifest count") } catch { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 10)
        XCTAssertEqual(ComposerModel(serverID: f.server, threadID: "thread", drafts: drafts).attachments.count, 10)
    }

    @MainActor
    func testRemovingDuringAnUploadKeepsItsBytesUntilSubmissionFinishes() async throws {
        let f = fixture(behavior: .heldUpload), drafts = DraftStore(root: f.root.appendingPathComponent("drafts"))
        try await f.model.importData(Data([1]), name: "held.txt", kind: .file)
        let item = try XCTUnwrap(f.model.attachments.first), file = try XCTUnwrap(f.model.previewURL(item))
        let sending = Task { await f.model.submitInput(using: f.sender, snapshot: snapshot(), mode: .start, features: ["attachments": true]) }
        let uploading = await f.transport.waitForUpload(); XCTAssertTrue(uploading)
        let secondView = ComposerModel(serverID: f.server, threadID: "thread", drafts: drafts)
        try secondView.removeAttachment(item.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "An active upload owns a temporary read lease")
        await f.transport.releaseUpload(); _ = await sending.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    @MainActor
    private func fixture(behavior: AttachmentTransport.Behavior = .accepted) -> (root: URL, server: UUID, model: ComposerModel, transport: AttachmentTransport, sender: CommandSender) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), server = UUID()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let drafts = DraftStore(root: root.appendingPathComponent("drafts")), transport = AttachmentTransport(behavior: behavior)
        return (root, server, ComposerModel(serverID: server, threadID: "thread", drafts: drafts), transport,
                CommandSender(serverID: server, transport: transport, journal: OperationJournal(root: root.appendingPathComponent("operations"))))
    }
}

private final class BoundedAttachmentProvider: NSItemProvider, @unchecked Sendable {
    let file: URL
    private(set) var fileLoads = 0
    private(set) var dataLoads = 0
    init(file: URL, type: String) {
        self.file = file; super.init()
        registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { completion in completion(Data([1]), nil); return nil }
    }
    override func loadFileRepresentation(forTypeIdentifier typeIdentifier: String, completionHandler: @escaping (URL?, Error?) -> Void) -> Progress {
        fileLoads += 1; completionHandler(file, nil); return Progress(totalUnitCount: 1)
    }
    override func loadDataRepresentation(forTypeIdentifier typeIdentifier: String, completionHandler: @escaping (Data?, Error?) -> Void) -> Progress {
        dataLoads += 1; completionHandler(Data([1]), nil); return Progress(totalUnitCount: 1)
    }
}

private func snapshot() -> Snapshot {
    Snapshot(cursor: Cursor(epoch: "epoch", seq: 0), thread: ThreadSummary(id: "thread", projectId: "project", title: "Fixture", status: "idle", activeTurnId: nil, parentId: nil),
             items: [], itemsCursor: nil, pending: [], policy: Snapshot.Policy(approvalPolicy: nil, sandbox: nil))
}

private actor AttachmentTransport: BridgeTransport {
    enum Behavior { case accepted, failed, unknown, uploadFailure, heldUpload, heldCommand, wrongReceipt }
    let behavior: Behavior
    private(set) var uploads: [AttachmentUpload] = []
    private(set) var posts: [Command] = []
    private var uploadWait: CheckedContinuation<UploadedAttachment, Never>?
    private var commandWait: CheckedContinuation<CodexRemote.Operation, Never>?
    init(behavior: Behavior) { self.behavior = behavior }
    func uploadAttachment(_ upload: AttachmentUpload) async throws -> UploadedAttachment {
        uploads.append(upload)
        if behavior == .uploadFailure { throw URLError(.networkConnectionLost) }
        if behavior == .heldUpload { return await withCheckedContinuation { uploadWait = $0 } }
        return UploadedAttachment(id: behavior == .wrongReceipt ? UUID().uuidString : upload.id, name: upload.name, kind: upload.kind, size: upload.base64.flatMap { Data(base64Encoded: $0)?.count } ?? 0)
    }
    func command(_ command: Command) async throws -> CodexRemote.Operation {
        posts.append(command)
        if behavior == .heldCommand { return await withCheckedContinuation { commandWait = $0 } }
        return CodexRemote.Operation(id: command.id, state: behavior == .failed ? .failed : behavior == .unknown ? .unknown : .accepted, result: .null, message: nil)
    }
    func waitForUpload() async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while uploadWait == nil && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        return uploadWait != nil
    }
    func waitForCommand() async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while commandWait == nil && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        return commandWait != nil
    }
    func releaseUpload() {
        if let upload = uploads.first { uploadWait?.resume(returning: UploadedAttachment(id: upload.id, name: upload.name, kind: upload.kind, size: 1)) }
        uploadWait = nil
    }
    func releaseCommand() {
        if let command = posts.first { commandWait?.resume(returning: CodexRemote.Operation(id: command.id, state: .accepted, result: .null, message: nil)) }
        commandWait = nil
    }
    func get<T: Decodable & Sendable>(_ path: String, as: T.Type) async throws -> T { throw ConnectionError.invalidPath }
    nonisolated func events(after: Cursor?) -> AsyncThrowingStream<EventFrame, Error> { AsyncThrowingStream { $0.finish() } }
    func close() async { }
}
