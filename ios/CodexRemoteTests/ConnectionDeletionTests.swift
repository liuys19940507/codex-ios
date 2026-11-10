import XCTest
import Security
@testable import CodexRemote

final class ConnectionDeletionTests: XCTestCase {
    @MainActor
    func testDeletingActiveConnectionRemovesCredentialAndDisconnects() async throws {
        let f = try fixture()
        await f.model.connect(serverID: f.first.id)
        XCTAssertEqual(f.model.status, .connected)
        try await f.model.delete(serverID: f.first.id)
        XCTAssertEqual(f.model.servers.map(\.id), [f.other.id])
        XCTAssertEqual(try f.store.load().map(\.id), [f.other.id])
        XCTAssertNil(try f.credentials.load(serverID: f.first.id))
        XCTAssertEqual(try f.credentials.load(serverID: f.other.id), "other-token")
        XCTAssertNil(f.model.activeServerID)
        XCTAssertNil(f.model.transport)
        XCTAssertEqual(f.model.status, .disconnected)
        let closed = await f.transport.closed
        XCTAssertTrue(closed)
        XCTAssertEqual(try f.drafts.read(serverID: f.other.id, threadID: "thread"), "keep other draft")
    }

    @MainActor
    func testDeletePersistenceFailureRestoresCredentialAndActiveConnection() async throws {
        let f = try fixture()
        await f.model.connect(serverID: f.first.id)
        f.failure.failWrites = true
        do { try await f.model.delete(serverID: f.first.id); XCTFail("Expected storage failure") } catch { }
        XCTAssertEqual(f.model.servers.map(\.id), [f.first.id, f.other.id])
        XCTAssertEqual(try f.store.load().map(\.id), [f.first.id, f.other.id])
        XCTAssertEqual(try f.credentials.load(serverID: f.first.id), "first-token")
        XCTAssertEqual(f.model.status, .connected)
        let closed = await f.transport.closed
        XCTAssertFalse(closed)
    }

    @MainActor
    func testDeletingInactiveConnectionPreservesActiveWorkspaceAndKeychainFailureDoesNotLoseConfig() async throws {
        let f = try fixture()
        await f.model.connect(serverID: f.first.id)
        f.backend.failure = errSecInteractionNotAllowed
        do { try await f.model.delete(serverID: f.other.id); XCTFail("Expected Keychain failure") } catch { }
        XCTAssertEqual(f.model.servers.count, 2)
        XCTAssertEqual(try f.store.load().count, 2)
        f.backend.failure = nil
        try await f.model.delete(serverID: f.other.id)
        XCTAssertEqual(f.model.activeServerID, f.first.id)
        XCTAssertEqual(f.model.status, .connected)
        XCTAssertEqual(try f.credentials.load(serverID: f.first.id), "first-token")
        XCTAssertNil(try f.credentials.load(serverID: f.other.id))
        let closed = await f.transport.closed
        XCTAssertFalse(closed)
    }

    @MainActor
    func testDeletingConnectionInvalidatesItsInFlightHandshake() async throws {
        let f = try fixture()
        await f.transport.holdInfo()
        let connecting = Task { await f.model.connect(serverID: f.first.id) }
        let waiting = await f.transport.waitForHeldInfo()
        XCTAssertTrue(waiting)
        try await f.model.delete(serverID: f.first.id)
        await f.transport.releaseInfo()
        await connecting.value
        XCTAssertNil(f.model.activeServerID)
        XCTAssertNil(f.model.transport)
        XCTAssertNil(f.model.info)
        XCTAssertEqual(f.model.status, .disconnected)
        XCTAssertEqual(f.model.servers.map(\.id), [f.other.id])
    }

    @MainActor
    private func fixture() throws -> (model: ConnectionModel, first: ServerConfiguration, other: ServerConfiguration, credentials: CredentialStore, backend: MemoryKeychain, store: ServerStore, drafts: DraftStore, failure: DeletionFailure, transport: DeletionTransport) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let first = try ServerConfiguration(name: "First", address: "https://first.invalid"), other = try ServerConfiguration(name: "Other", address: "https://other.invalid")
        let failure = DeletionFailure(), backend = MemoryKeychain(), credentials = CredentialStore(backend: backend)
        let store = ServerStore(url: root.appendingPathComponent("servers.json"), write: { data, url in
            if failure.failWrites { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        try store.save([first, other]); try credentials.save(token: "first-token", serverID: first.id); try credentials.save(token: "other-token", serverID: other.id)
        let drafts = DraftStore(root: root.appendingPathComponent("drafts"))
        try drafts.write("keep other draft", serverID: other.id, threadID: "thread")
        let transport = DeletionTransport()
        return (ConnectionModel(servers: store, credentials: credentials, makeTransport: { _, _ in transport }), first, other, credentials, backend, store, drafts, failure, transport)
    }
}
private final class DeletionFailure { var failWrites = false }
private actor DeletionTransport: BridgeTransport {
    private(set) var closed = false
    private var hold = false
    private var pending: CheckedContinuation<ServerInfo, Never>?
    private let info = ServerInfo(apiVersion: 1, serverId: "fixture", codexVersion: "0.167.0", features: [:])
    func holdInfo() { hold = true }
    func waitForHeldInfo() async -> Bool {
        let until = Date().addingTimeInterval(3)
        while pending == nil && Date() < until { try? await Task.sleep(nanoseconds: 5_000_000) }
        return pending != nil
    }
    func releaseInfo() { pending?.resume(returning: info); pending = nil }
    func get<T: Decodable & Sendable>(_ path: String, as: T.Type) async throws -> T {
        if hold { hold = false; return await withCheckedContinuation { pending = $0 } as! T }
        return info as! T
    }
    func command(_ command: Command) async throws -> CodexRemote.Operation { throw ConnectionError.invalidPath }
    nonisolated func events(after: Cursor?) -> AsyncThrowingStream<EventFrame, Error> { AsyncThrowingStream { _ in } }
    func close() async { closed = true }
}
