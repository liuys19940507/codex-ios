import XCTest
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
        let sending = Task { await f.model.submitInput(using: f.sender, snapshot: snapshot(), mode: .start, features: ["attachments": true]) }
        let posted = await f.transport.waitForCommand(); XCTAssertTrue(posted)
        f.model.text = "later 中文😀"
        try await f.model.importData(Data([2]), name: "later.txt", kind: .file)
        await f.transport.releaseCommand(); _ = await sending.value
        XCTAssertEqual(f.model.text, "later 中文😀")
        XCTAssertEqual(f.model.attachments.map(\.name), ["later.txt"])
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
    private func fixture(behavior: AttachmentTransport.Behavior = .accepted) -> (root: URL, server: UUID, model: ComposerModel, transport: AttachmentTransport, sender: CommandSender) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), server = UUID()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let drafts = DraftStore(root: root.appendingPathComponent("drafts")), transport = AttachmentTransport(behavior: behavior)
        return (root, server, ComposerModel(serverID: server, threadID: "thread", drafts: drafts), transport,
                CommandSender(serverID: server, transport: transport, journal: OperationJournal(root: root.appendingPathComponent("operations"))))
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
