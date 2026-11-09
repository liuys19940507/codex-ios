import Foundation

enum SyncState: Equatable, Sendable {
    case disconnected, connecting, syncing, connected, failed
}

struct CursorStore {
    let url: URL
    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexRemote/cursors.json")) { self.url = url }
    private func all() throws -> [String: Cursor] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: Cursor].self, from: Data(contentsOf: url))
    }
    func load(serverID: UUID) throws -> Cursor? { try all()[serverID.uuidString] }
    func save(_ cursor: Cursor, serverID: UUID) throws {
        var values = try all()
        values[serverID.uuidString] = cursor
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(values).write(to: url, options: .atomic)
    }
}
