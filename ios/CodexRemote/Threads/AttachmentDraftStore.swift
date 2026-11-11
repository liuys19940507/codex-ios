import Foundation
import CryptoKit

struct AttachmentDraftStore: Sendable {
    let root: URL
    private struct Entry: Codable { let threadID: String; let attachments: [DraftAttachment] }
    private func manifest(serverID: UUID, threadID: String) -> URL {
        let hash = SHA256.hash(data: Data(threadID.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(serverID.uuidString).appendingPathComponent("drafts").appendingPathComponent(hash + ".json")
    }
    func localURL(for attachment: DraftAttachment, serverID: UUID) throws -> URL {
        guard attachment.isLocal else { throw ConnectionError.invalidPath }
        try AttachmentLimits.filename(attachment.name)
        let ext = (attachment.name as NSString).pathExtension.lowercased()
        let suffix = ext.range(of: "^[a-z0-9]{1,10}$", options: .regularExpression) != nil ? ext : "bin"
        return root.appendingPathComponent(serverID.uuidString).appendingPathComponent("files")
            .appendingPathComponent(attachment.id.uuidString.lowercased() + "." + suffix)
    }
    func load(serverID: UUID, threadID: String) throws -> [DraftAttachment] {
        let url = manifest(serverID: serverID, threadID: threadID)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: url))
        guard entry.threadID == threadID else { throw ConnectionError.invalidResponse }
        try validate(entry.attachments, serverID: serverID)
        return entry.attachments
    }
    func write(_ attachments: [DraftAttachment], serverID: UUID, threadID: String) throws {
        try validate(attachments, serverID: serverID)
        let url = manifest(serverID: serverID, threadID: threadID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Entry(threadID: threadID, attachments: attachments)).write(to: url, options: .atomic)
    }
    func store(_ data: Data, name: String, kind: AttachmentKind, serverID: UUID) throws -> DraftAttachment {
        try AttachmentLimits.filename(name); try AttachmentLimits.data(data)
        guard kind == .image || kind == .file else { throw ConnectionError.invalidResponse }
        let attachment = DraftAttachment(id: UUID(), name: name, kind: kind, location: nil)
        let url = try localURL(for: attachment, serverID: serverID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return attachment
    }
    func payload(for attachment: DraftAttachment, serverID: UUID, projectID: String) throws -> AttachmentUpload {
        let data = attachment.isLocal ? try Self.readBounded(localURL(for: attachment, serverID: serverID)) : nil
        return AttachmentUpload(id: attachment.id.uuidString.lowercased(), projectId: projectID, name: attachment.name,
                                kind: attachment.kind, base64: data?.base64EncodedString(), location: attachment.location)
    }
    private func validate(_ attachments: [DraftAttachment], serverID: UUID) throws {
        guard attachments.count <= AttachmentLimits.count, Set(attachments.map(\.id)).count == attachments.count else { throw ConnectionError.invalidResponse }
        for attachment in attachments {
            try AttachmentLimits.filename(attachment.name)
            if attachment.isLocal {
                let url = try localURL(for: attachment, serverID: serverID)
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= AttachmentLimits.bytes else { throw ConnectionError.invalidResponse }
            } else { try AttachmentLimits.imageLocation(attachment.location ?? "", kind: attachment.kind) }
        }
    }
    static func readBounded(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw ConnectionError.invalidPath }
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard attributes.isRegularFile == true else { throw ClientCommandError(message: "请选择一个文件。") }
        if let size = attributes.fileSize, size > AttachmentLimits.bytes { throw ClientCommandError(message: "每个附件最多20MB。") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var result = Data()
        while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
            guard result.count + chunk.count <= AttachmentLimits.bytes else { throw ClientCommandError(message: "每个附件最多20MB。") }
            result.append(chunk)
        }
        try AttachmentLimits.data(result); return result
    }
}
