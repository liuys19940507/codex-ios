import Foundation

struct PinnedThreadStore {
    let url: URL
    private let write: (Data, URL) throws -> Void
    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CodexRemote/pinned-threads.json"),
         write: @escaping (Data, URL) throws -> Void = { data, target in try data.write(to: target, options: .atomic) }) {
        self.url = url; self.write = write
    }
    private func values() throws -> [String: [ThreadSummary]] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: [ThreadSummary]].self, from: Data(contentsOf: url))
    }
    func load(serverID: UUID) throws -> [ThreadSummary] { unique(try values()[serverID.uuidString] ?? []) }
    func save(_ threads: [ThreadSummary], serverID: UUID) throws {
        var all = try values(); all[serverID.uuidString] = unique(threads)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(JSONEncoder().encode(all), url)
    }
    private func unique(_ threads: [ThreadSummary]) -> [ThreadSummary] {
        var seen = Set<String>()
        return threads.filter { !$0.id.isEmpty && !$0.projectId.isEmpty && seen.insert($0.id).inserted }
    }
}
