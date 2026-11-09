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
}
