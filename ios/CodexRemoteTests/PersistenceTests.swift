import XCTest
@testable import CodexRemote

final class PersistenceTests: XCTestCase {
    func testTokenIsNotInConfigFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("servers.json")
        let store = ServerStore(url: url)
        let server = try ServerConfiguration(name: "我的 Windows", address: "http://10.147.21.2:8391")
        try store.save([server])
        XCTAssertEqual(try store.load(), [server])
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(json.contains("token"))
        XCTAssertTrue(json.contains(server.id.uuidString))
    }

    func testAtomicConfigWriteSurvivesFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("servers.json")
        let original = try ServerConfiguration(name: "Original", address: "http://10.147.21.2:8391")
        try ServerStore(url: url).save([original])
        let broken = ServerStore(url: url, write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        XCTAssertThrowsError(try broken.save([]))
        XCTAssertEqual(try ServerStore(url: url).load(), [original])
    }

    func testCorruptConfigIsNotSilentlyReset() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("corrupt".utf8).write(to: url)
        XCTAssertThrowsError(try ServerStore(url: url).load())
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "corrupt")
    }
}
