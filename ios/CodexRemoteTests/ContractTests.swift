import XCTest
@testable import CodexRemote

final class ContractTests: XCTestCase {
    func testDecodesContractInfo() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "info", withExtension: "json"))
        let info = try JSONDecoder().decode(ServerInfo.self, from: Data(contentsOf: url))
        XCTAssertEqual(info.apiVersion, 1)
        XCTAssertEqual(info.codexVersion, "0.167.0")
        XCTAssertEqual(info.features["queue"], false)
    }

    func testUnknownJSONFieldsAreIgnored() throws {
        let data = Data(#"{"apiVersion":1,"serverId":"test","codexVersion":"0.167.0","features":{},"future":{"nested":true}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ServerInfo.self, from: data).serverId, "test")
    }

    func testSharedTaskFixturesPreserveCursorPartialOutputAndUnknownOutcome() throws {
        func data(_ name: String) throws -> Data {
            try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json")))
        }
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode([Project].self, from: data("projects")).first?.id, "fixture-project")
        XCTAssertEqual(try decoder.decode([ModelOption].self, from: data("models")).first?.reasoning, ["medium"])
        let page = try decoder.decode(ThreadPage.self, from: data("threads"))
        XCTAssertEqual(page.data.last?.parentId, page.data.first?.id)
        let snapshot = try decoder.decode(Snapshot.self, from: data("snapshot"))
        XCTAssertEqual(snapshot.pending.first?.kind, .command)
        XCTAssertTrue(snapshot.items[0].text.contains("\r\n"))
        let events = try decoder.decode([Envelope].self, from: data("events"))
        XCTAssertEqual(events.map(\.cursor.seq), [3, 4])
        XCTAssertNotEqual(events[0].threadId, snapshot.thread.id)
        let operations = try decoder.decode([CodexRemote.Operation].self, from: data("operations"))
        XCTAssertEqual(operations.map(\.state), [.unknown, .accepted])
        struct Failure: Decodable { let code: String; let message: String }
        XCTAssertEqual(try decoder.decode([Failure].self, from: data("errors")).first?.code, "request_expired")
    }
}
