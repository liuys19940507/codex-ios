import XCTest
import Security
@testable import CodexRemote

final class ConnectionTests: XCTestCase {
    func testRejectsUnsafeServerAddresses() throws {
        for address in ["file:///etc/passwd", "ftp://example.com", "http://user:pass@example.com", "https://example.com/?token=secret", "https://example.com/#token"] {
            XCTAssertThrowsError(try ServerConfiguration(name: "Test", address: address), address)
        }
        let server = try ServerConfiguration(name: "Windows", address: "http://10.147.21.2:8391/")
        XCTAssertEqual(server.baseURL.host, "10.147.21.2")
    }

    func testAuthenticationCannotEscapeConfiguredHost() throws {
        let server = try ServerConfiguration(name: "Windows", address: "http://10.147.21.2:8391")
        let request = try URLSessionTransport.makeRequest(server: server, token: "test-token", path: "/v1/info")
        XCTAssertEqual(request.url?.host, "10.147.21.2")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertFalse(request.url!.absoluteString.contains("test-token"))
        for path in ["https://other.example/v1/info", "//other.example/v1/info", "/other", "/v1/../secret"] {
            XCTAssertThrowsError(try URLSessionTransport.makeRequest(server: server, token: "test-token", path: path))
        }
    }

    func testCredentialNamespacesAreIndependent() throws {
        let credentials = CredentialStore(service: "com.liuys.codexremote.tests.\(UUID().uuidString)", backend: MemoryKeychain())
        let first = UUID(), other = UUID()
        defer { try? credentials.delete(serverID: first); try? credentials.delete(serverID: other) }
        try credentials.save(token: "test-token", serverID: first)
        try credentials.save(token: "other-token", serverID: other)
        XCTAssertEqual(try credentials.load(serverID: first), "test-token")
        XCTAssertEqual(try credentials.load(serverID: other), "other-token")
        try credentials.save(token: "updated", serverID: first)
        XCTAssertEqual(try credentials.load(serverID: first), "updated")
        try credentials.delete(serverID: first)
        XCTAssertNil(try credentials.load(serverID: first))
        XCTAssertEqual(try credentials.load(serverID: other), "other-token")
    }

    func testKeychainFailureIsReportedWithoutPlaintextFallback() throws {
        let backend = MemoryKeychain()
        backend.failure = errSecMissingEntitlement
        let store = CredentialStore(backend: backend)
        XCTAssertThrowsError(try store.save(token: "test-token", serverID: UUID()))
        XCTAssertTrue(backend.values.isEmpty)
    }
}

private final class MemoryKeychain: KeychainBackend {
    var values: [String: Data] = [:]
    var failure: OSStatus?
    private func key(_ query: [String: Any]) -> String {
        "\(query[kSecAttrService as String]!)|\(query[kSecAttrAccount as String]!)"
    }
    func update(_ query: [String: Any], values update: [String: Any]) -> OSStatus {
        if let failure { return failure }
        guard values[key(query)] != nil else { return errSecItemNotFound }
        values[key(query)] = update[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func add(_ fields: [String: Any]) -> OSStatus {
        if let failure { return failure }
        values[key(fields)] = fields[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func read(_ query: [String: Any]) -> (OSStatus, Data?) {
        if let failure { return (failure, nil) }
        guard let data = values[key(query)] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        if let failure { return failure }
        return values.removeValue(forKey: key(query)) == nil ? errSecItemNotFound : errSecSuccess
    }
}
