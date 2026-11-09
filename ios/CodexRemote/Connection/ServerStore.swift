import Foundation

struct ServerStore {
    let url: URL
    private let write: (Data, URL) throws -> Void
    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CodexRemote/servers.json"),
         write: @escaping (Data, URL) throws -> Void = { data, target in try data.write(to: target, options: .atomic) }) {
        self.url = url
        self.write = write
    }
    func load() throws -> [ServerConfiguration] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ServerConfiguration].self, from: Data(contentsOf: url))
    }
    func save(_ servers: [ServerConfiguration]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(JSONEncoder().encode(servers), url)
    }
}
