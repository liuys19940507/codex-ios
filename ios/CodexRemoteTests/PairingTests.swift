import XCTest
@testable import CodexRemote

final class PairingTests: XCTestCase {
    @MainActor
    func testSavedPairingReconnectsWithoutPuttingTokenInConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ServerStore(url: root.appendingPathComponent("servers.json"))
        let credentials = CredentialStore(backend: MemoryKeychain())
        let transport = PairingTransport()
        let model = ConnectionModel(servers: store, credentials: credentials, makeTransport: { _, _ in transport })
        let saved = try await model.save(name: "Windows", address: "http://10.147.21.2:8391", token: "test-token", editingID: nil)
        XCTAssertEqual(model.info?.serverId, "test-server")
        XCTAssertEqual(model.status, .connected)
        XCTAssertFalse(try String(contentsOf: store.url, encoding: .utf8).contains("test-token"))
        let reopened = ConnectionModel(servers: store, credentials: credentials, makeTransport: { _, token in
            XCTAssertEqual(token, "test-token")
            return PairingTransport()
        })
        XCTAssertEqual(reopened.servers.map(\.id), [saved.id])
        await reopened.connect(serverID: saved.id)
        XCTAssertEqual(reopened.status, .connected)
        await model.disconnect()
        await reopened.disconnect()
    }

    @MainActor
    func testAddressChangeRequiresNewTokenBeforeSendingAnything() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ServerStore(url: root.appendingPathComponent("servers.json"))
        let server = try ServerConfiguration(name: "Windows", address: "http://10.147.21.2:8391")
        try store.save([server])
        let credentials = CredentialStore(backend: MemoryKeychain())
        try credentials.save(token: "test-token", serverID: server.id)
        var requests = 0
        let model = ConnectionModel(servers: store, credentials: credentials, makeTransport: { _, _ in
            requests += 1
            return PairingTransport()
        })
        do {
            _ = try await model.save(name: "Other", address: "https://other.example", token: "", editingID: server.id)
            XCTFail("A changed destination must not receive the previous token")
        } catch { }
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(try store.load(), [server])
        XCTAssertEqual(try credentials.load(serverID: server.id), "test-token")
    }

    @MainActor
    func testConfigurationWriteFailureRestoresPreviousCredential() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("servers.json")
        let server = try ServerConfiguration(name: "Windows", address: "http://10.147.21.2:8391")
        try ServerStore(url: url).save([server])
        let credentials = CredentialStore(backend: MemoryKeychain())
        try credentials.save(token: "previous-token", serverID: server.id)
        let store = ServerStore(url: url, write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        let model = ConnectionModel(servers: store, credentials: credentials)
        do {
            _ = try await model.save(name: "Changed", address: server.baseURL.absoluteString, token: "new-token", editingID: server.id)
            XCTFail("The failed write must be reported")
        } catch { }
        XCTAssertEqual(model.servers, [server])
        XCTAssertEqual(try credentials.load(serverID: server.id), "previous-token")
    }

    @MainActor
    func testLateConnectionCannotReplaceTheSelectedServer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ServerStore(url: root.appendingPathComponent("servers.json"))
        let first = try ServerConfiguration(name: "First", address: "https://first.example")
        let second = try ServerConfiguration(name: "Second", address: "https://second.example")
        try store.save([first, second])
        let credentials = CredentialStore(backend: MemoryKeychain())
        for server in [first, second] { try credentials.save(token: "test-token", serverID: server.id) }
        let delayed = PairingTransport(delayed: true)
        let model = ConnectionModel(servers: store, credentials: credentials, makeTransport: { server, _ in
            server.id == first.id ? delayed : PairingTransport()
        })
        let old = Task { await model.connect(serverID: first.id) }
        await delayed.waitUntilRequested()
        await model.connect(serverID: second.id)
        await delayed.finish()
        await old.value
        XCTAssertEqual(model.activeServerID, second.id)
        XCTAssertEqual(model.status, .connected)
        let closes = await delayed.closeCount
        XCTAssertGreaterThan(closes, 0)
        await model.disconnect()
    }

    @MainActor
    func testUnsupportedApiDoesNotBecomeConnected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ConnectionModel(servers: ServerStore(url: root.appendingPathComponent("servers.json")),
                                    credentials: CredentialStore(backend: MemoryKeychain()),
                                    makeTransport: { _, _ in PairingTransport(version: 2) })
        _ = try await model.save(name: "Windows", address: "http://10.147.21.2:8391", token: "test-token", editingID: nil)
        XCTAssertEqual(model.status, .failed)
        XCTAssertNil(model.info)
        XCTAssertNotNil(model.message)
    }
}

private actor PairingTransport: BridgeTransport {
    let delayed: Bool
    let version: Int
    var closeCount = 0
    private var requested = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var response: CheckedContinuation<ServerInfo, Never>?
    init(delayed: Bool = false, version: Int = 1) { self.delayed = delayed; self.version = version }
    func get<T: Decodable & Sendable>(_ path: String, as: T.Type) async throws -> T {
        let info: ServerInfo
        if delayed {
            info = await withCheckedContinuation { continuation in
                response = continuation; requested = true; waiter?.resume(); waiter = nil
            }
        } else { info = ServerInfo(apiVersion: version, serverId: "test-server", codexVersion: "0.167.0", features: [:]) }
        return info as! T
    }
    func waitUntilRequested() async {
        if !requested { await withCheckedContinuation { waiter = $0 } }
    }
    func finish() { response?.resume(returning: ServerInfo(apiVersion: version, serverId: "late-server", codexVersion: "0.167.0", features: [:])); response = nil }
    func command(_ command: Command) async throws -> CodexRemote.Operation { throw ConnectionError.invalidPath }
    nonisolated func events(after: Cursor?) -> AsyncThrowingStream<EventFrame, Error> { AsyncThrowingStream { $0.finish() } }
    func close() async { closeCount += 1 }
}
