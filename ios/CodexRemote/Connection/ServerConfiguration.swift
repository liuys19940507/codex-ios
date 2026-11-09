import Foundation

enum ConnectionError: LocalizedError {
    case invalidAddress, invalidPath, invalidResponse, missingCredential, incompatibleServer
    case server(Int, String)
    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "请输入不含账号、密码或查询参数的 HTTP/HTTPS 服务地址。"
        case .invalidPath: return "请求路径无效。"
        case .invalidResponse: return "服务端返回了无法识别的数据。"
        case .missingCredential: return "请填写配对令牌。"
        case .incompatibleServer: return "服务版本不兼容。"
        case .server(let status, let message): return "\(message)（\(status)）"
        }
    }
}

struct ServerConfiguration: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    let baseURL: URL

    init(id: UUID = UUID(), name: String, address: String) throws {
        guard let parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", let url = parts.url else {
            throw ConnectionError.invalidAddress
        }
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? host : name
        self.baseURL = url
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id),
                      name: values.decode(String.self, forKey: .name),
                      address: values.decode(URL.self, forKey: .baseURL).absoluteString)
    }
}
