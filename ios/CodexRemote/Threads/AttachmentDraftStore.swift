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
        let access = AttachmentBlobAccess.shared
        access.lock.lock(); defer { access.lock.unlock() }
        let previous = try load(serverID: serverID, threadID: threadID)
        try validate(attachments, serverID: serverID)
        let url = manifest(serverID: serverID, threadID: threadID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Entry(threadID: threadID, attachments: attachments)).write(to: url, options: .atomic)
        let retained = Set(attachments.map(\.id))
        for item in previous where !retained.contains(item.id) {
            try? discardUnreferenced(item, serverID: serverID)
        }
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
    func discardUnreferenced(_ attachment: DraftAttachment, serverID: UUID) throws {
        guard attachment.isLocal else { return }
        let access = AttachmentBlobAccess.shared
        access.lock.lock(); defer { access.lock.unlock() }
        let url = try localURL(for: attachment, serverID: serverID)
        guard access.leases[url.path, default: 0] == 0 else { return }
        let directory = manifest(serverID: serverID, threadID: "").deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.path) {
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                // If any manifest cannot be read, preserve bytes rather than guess.
                let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: file))
                for item in entry.attachments where item.isLocal {
                    if try localURL(for: item, serverID: serverID) == url { return }
                }
            }
        }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    func lease(_ attachments: [DraftAttachment], serverID: UUID) throws -> AttachmentBlobLease {
        let items = attachments.filter(\.isLocal)
        let paths = try items.map { try localURL(for: $0, serverID: serverID).path }
        let access = AttachmentBlobAccess.shared
        access.lock.lock()
        for path in paths { access.leases[path, default: 0] += 1 }
        access.lock.unlock()
        return AttachmentBlobLease {
            access.lock.lock(); defer { access.lock.unlock() }
            for path in paths {
                let count = access.leases[path, default: 0] - 1
                if count > 0 { access.leases[path] = count } else { access.leases.removeValue(forKey: path) }
            }
            for item in items { try? self.discardUnreferenced(item, serverID: serverID) }
        }
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

private final class AttachmentBlobAccess: @unchecked Sendable {
    static let shared = AttachmentBlobAccess()
    let lock = NSRecursiveLock()
    var leases: [String: Int] = [:]
}

final class AttachmentBlobLease: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    init(_ action: @escaping @Sendable () -> Void) { self.action = action }
    func release() {
        lock.lock(); let pending = action; action = nil; lock.unlock()
        pending?()
    }
    deinit { release() }
}
