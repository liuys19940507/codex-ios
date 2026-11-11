import Foundation

enum EventFrame: Sendable {
    case event(Envelope)
    case resyncRequired
}

protocol BridgeTransport: Sendable {
    func get<T: Decodable & Sendable>(_ path: String, as: T.Type) async throws -> T
    func command(_ command: Command) async throws -> Operation
    func uploadAttachment(_ upload: AttachmentUpload) async throws -> UploadedAttachment
    func events(after: Cursor?) -> AsyncThrowingStream<EventFrame, Error>
    func close() async
    func cancelEvents() async
}

extension BridgeTransport {
    func cancelEvents() async { }
    func uploadAttachment(_ upload: AttachmentUpload) async throws -> UploadedAttachment {
        throw ClientCommandError(message: "当前服务不支持附件，请更新 Windows 桥接服务。")
    }
}
