import Foundation
import Security

struct CredentialStore {
    let service: String
    init(service: String = "com.liuys.codexremote.credentials") { self.service = service }

    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }

    func save(token: String, serverID: UUID) throws {
        guard !token.isEmpty else { throw ConnectionError.missingCredential }
        let data = Data(token.utf8)
        let status = SecItemUpdate(query(serverID) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var fields = query(serverID)
            fields[kSecValueData as String] = data
            fields[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(fields as CFDictionary, nil))
        } else { try check(status) }
    }

    func load(serverID: UUID) throws -> String? {
        var fields = query(serverID)
        fields[kSecReturnData as String] = true
        fields[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(fields as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw ConnectionError.invalidResponse
        }
        return token
    }

    func delete(serverID: UUID) throws {
        let status = SecItemDelete(query(serverID) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func check(_ status: OSStatus) throws {
        if status != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
