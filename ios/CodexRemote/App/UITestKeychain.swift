#if DEBUG
import Foundation
import Security

final class UITestKeychain: KeychainBackend {
    private var values: [String: Data] = [:]
    private func key(_ query: [String: Any]) -> String { "\(query[kSecAttrService as String] ?? "")|\(query[kSecAttrAccount as String] ?? "")" }
    func update(_ query: [String: Any], values update: [String: Any]) -> OSStatus {
        guard values[key(query)] != nil else { return errSecItemNotFound }
        values[key(query)] = update[kSecValueData as String] as? Data; return errSecSuccess
    }
    func add(_ fields: [String: Any]) -> OSStatus { values[key(fields)] = fields[kSecValueData as String] as? Data; return errSecSuccess }
    func read(_ query: [String: Any]) -> (OSStatus, Data?) { if let value = values[key(query)] { return (errSecSuccess, value) }; return (errSecItemNotFound, nil) }
    func delete(_ query: [String: Any]) -> OSStatus { values[key(query)] = nil; return errSecSuccess }
}
#endif
