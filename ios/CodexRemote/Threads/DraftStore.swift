import Foundation
import CryptoKit

struct DraftStore {
    let root: URL
    private struct Entry: Codable { let threadID: String; let text: String }
    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexRemote/drafts")) { self.root = root }
    private func path(serverID: UUID, threadID: String) -> URL {
        let name = SHA256.hash(data: Data(threadID.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(serverID.uuidString, isDirectory: true).appendingPathComponent(name + ".json")
    }
    func read(serverID: UUID, threadID: String) throws -> String {
        let url = path(serverID: serverID, threadID: threadID)
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: url))
        guard entry.threadID == threadID else { throw ConnectionError.invalidResponse }
        return entry.text
    }
    func write(_ text: String, serverID: UUID, threadID: String) throws {
        let url = path(serverID: serverID, threadID: threadID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Entry(threadID: threadID, text: text)).write(to: url, options: .atomic)
    }
}

func mergeHistory(older: [Item], current: [Item]) -> [Item] {
    let currentByID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    var ids = Set<String>(), result: [Item] = []
    for item in older + current where ids.insert(item.id).inserted { result.append(currentByID[item.id] ?? item) }
    return result
}
