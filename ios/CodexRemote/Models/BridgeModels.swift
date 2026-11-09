import Foundation

indirect enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode([JSONValue].self) { self = .array(decoded) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .object(let v): try value.encode(v)
        }
    }
}

struct ServerInfo: Codable, Equatable, Sendable {
    let apiVersion: Int
    let serverId: String
    let codexVersion: String
    let features: [String: Bool]
}

struct Project: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let path: String
}

struct ModelOption: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let reasoning: [String]
}

struct Cursor: Codable, Equatable, Sendable {
    let epoch: String
    let seq: Int
}

struct Item: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let turnId: String
    let kind: String
    var text: String
    var data: JSONValue
}

struct Pending: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case command, file, permission, question, mcp }
    enum State: String, Codable, Sendable { case pending, resolved, unknown }
    let id: String
    let threadId: String
    let turnId: String
    let kind: Kind
    let prompt: String
    let options: JSONValue
    var state: State
}

struct ThreadSummary: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let projectId: String
    var title: String
    var status: String
    var activeTurnId: String?
    let parentId: String?
}

struct Snapshot: Codable, Equatable, Sendable {
    struct Policy: Codable, Equatable, Sendable {
        let approvalPolicy: String?
        let sandbox: String?
    }
    let cursor: Cursor
    let thread: ThreadSummary
    let items: [Item]
    let itemsCursor: String?
    let pending: [Pending]
    let policy: Policy
}

struct Envelope: Codable, Equatable, Sendable {
    let cursor: Cursor
    let threadId: String
    let type: String
    let data: JSONValue
}

struct Operation: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Sendable { case pending, accepted, failed, unknown }
    let id: String
    let state: State
    let result: JSONValue
    let message: String?
}

struct Command: Codable, Equatable, Identifiable, Sendable {
    enum Method: String, Codable, Sendable {
        case create = "task/create", input = "task/input", interrupt = "task/interrupt"
        case respond = "request/respond", rename = "thread/rename", archive = "thread/archive"
    }
    let id: String
    let method: Method
    let params: [String: JSONValue]
}

struct ThreadPage: Codable, Equatable, Sendable {
    let data: [ThreadSummary]
    let nextCursor: String?
}

struct ItemPage: Codable, Equatable, Sendable {
    let data: [Item]
    let nextCursor: String?
}
