import Foundation

enum AttachmentKind: String, Codable, Sendable { case image, file, imageURL, serverImage }

struct DraftAttachment: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let kind: AttachmentKind
    let location: String?
    var isLocal: Bool { kind == .image || kind == .file }
}

struct AttachmentUpload: Codable, Equatable, Sendable {
    let id: String
    let projectId: String
    let name: String
    let kind: AttachmentKind
    let base64: String?
    let location: String?
}

struct UploadedAttachment: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let kind: AttachmentKind
    let size: Int
}

enum AttachmentLimits {
    static let bytes = 20 * 1024 * 1024
    static let count = 10
    static func filename(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 512,
              name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ClientCommandError(message: "附件名称无效，请重新选择文件。")
        }
    }
    static func data(_ data: Data) throws {
        guard !data.isEmpty else { throw ClientCommandError(message: "不能添加空文件。") }
        guard data.count <= bytes else { throw ClientCommandError(message: "每个附件最多20MB，请选择较小的文件。") }
    }
    static func imageLocation(_ value: String, kind: AttachmentKind) throws {
        guard !value.isEmpty, value.utf8.count <= 32768,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ClientCommandError(message: "图片地址无效。")
        }
        if kind == .imageURL {
            guard let url = URLComponents(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.isEmpty == false, url.user == nil, url.password == nil else {
                throw ClientCommandError(message: "请输入不含账号密码的 HTTP/HTTPS 图片地址。")
            }
        } else {
            guard kind == .serverImage, value.range(of: "^[A-Za-z]:[\\\\/]|^\\\\\\\\|^/", options: .regularExpression) != nil else {
                throw ClientCommandError(message: "请输入电脑上的图片绝对路径，图片需位于当前项目内。")
            }
        }
    }
}
