import Foundation
import Security

protocol KeychainBackend {
    func update(_ query: [String: Any], values: [String: Any]) -> OSStatus
    func add(_ fields: [String: Any]) -> OSStatus
    func read(_ query: [String: Any]) -> (OSStatus, Data?)
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemKeychainBackend: KeychainBackend {
    func update(_ query: [String: Any], values: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, values as CFDictionary)
    }
    func add(_ fields: [String: Any]) -> OSStatus { SecItemAdd(fields as CFDictionary, nil) }
    func read(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

struct CredentialStore {
    let service: String
    private let backend: KeychainBackend
    init(service: String = "com.liuys.codexremote.credentials", backend: KeychainBackend = SystemKeychainBackend()) {
        self.service = service; self.backend = backend
    }

    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }

    func save(token: String, serverID: UUID) throws {
        guard !token.isEmpty else { throw ConnectionError.missingCredential }
        let data = Data(token.utf8)
        let status = backend.update(query(serverID), values: [kSecValueData as String: data])
        if status == errSecItemNotFound {
            var fields = query(serverID)
            fields[kSecValueData as String] = data
            fields[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(backend.add(fields))
        } else { try check(status) }
    }

    func load(serverID: UUID) throws -> String? {
        var fields = query(serverID)
        fields[kSecReturnData as String] = true
        fields[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = backend.read(fields)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result, let token = String(data: data, encoding: .utf8) else {
            throw ConnectionError.invalidResponse
        }
        return token
    }

    func delete(serverID: UUID) throws {
        let status = backend.delete(query(serverID))
        if status != errSecItemNotFound { try check(status) }
    }

    private func check(_ status: OSStatus) throws {
        if status != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
