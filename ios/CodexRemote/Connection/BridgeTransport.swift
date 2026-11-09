import Foundation

enum EventFrame: Sendable {
    case event(Envelope)
    case resyncRequired
}

protocol BridgeTransport: Sendable {
    func get<T: Decodable & Sendable>(_ path: String, as: T.Type) async throws -> T
    func command(_ command: Command) async throws -> Operation
    func events(after: Cursor?) -> AsyncThrowingStream<EventFrame, Error>
    func close() async
}
