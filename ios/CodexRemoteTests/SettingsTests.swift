import XCTest
@testable import CodexRemote

final class SettingsTests: XCTestCase {
    @MainActor
    func testModelSelectionIsValidatedAndScopedToServer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelSettingsStore(url: root.appendingPathComponent("settings.json")), transport = SettingsTransport()
        let server = UUID(), other = UUID()
        let settings = ModelSettings(serverID: server, transport: transport, store: store)
        await settings.load()
        try settings.select(modelID: "actual-id", reasoning: "high")
        XCTAssertEqual(settings.selection?.modelID, "actual-id")
        XCTAssertEqual(settings.selection?.reasoning, "high")
        XCTAssertThrowsError(try settings.select(modelID: "invented", reasoning: nil))
        XCTAssertThrowsError(try settings.select(modelID: "actual-id", reasoning: "invented"))
        let restored = ModelSettings(serverID: server, transport: transport, store: store)
        await restored.load()
        XCTAssertEqual(restored.selection?.reasoning, "high")
        let separate = ModelSettings(serverID: other, transport: transport, store: store)
        await separate.load()
        XCTAssertNil(separate.selection?.modelID)
        XCTAssertTrue(separate.canCreate)
        await transport.removeModel()
        await restored.load()
        XCTAssertFalse(restored.canCreate)
        XCTAssertNotNil(restored.message)
        try restored.select(modelID: nil, reasoning: nil)
        XCTAssertTrue(restored.canCreate)
    }
}

private actor SettingsTransport: BridgeTransport {
    private var models = [ModelOption(id: "actual-id", name: "Actual model", reasoning: ["medium", "high"])]
    func removeModel() { models = [] }
    func get<T: Decodable & Sendable>(_ path: String, as: T.Type) async throws -> T { models as! T }
    func command(_ command: Command) async throws -> CodexRemote.Operation { throw ConnectionError.invalidPath }
    nonisolated func events(after: Cursor?) -> AsyncThrowingStream<EventFrame, Error> { AsyncThrowingStream { _ in } }
    func close() async { }
}
