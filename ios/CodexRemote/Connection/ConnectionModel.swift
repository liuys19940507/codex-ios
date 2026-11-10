import Foundation
import Combine

@MainActor
final class ConnectionModel: ObservableObject {
    enum Status: Equatable { case disconnected, connecting, connected, failed }
    @Published private(set) var servers: [ServerConfiguration] = []
    @Published private(set) var activeServerID: UUID?
    @Published private(set) var status: Status = .disconnected
    @Published private(set) var info: ServerInfo?
    @Published private(set) var message: String?
    private(set) var transport: (any BridgeTransport)?
    private let serverStore: ServerStore
    private let credentials: CredentialStore
    private let makeTransport: (ServerConfiguration, String) -> any BridgeTransport
    private var generation = UUID()

    init(servers: ServerStore = ServerStore(), credentials: CredentialStore = CredentialStore(),
         makeTransport: @escaping (ServerConfiguration, String) -> any BridgeTransport = { URLSessionTransport(server: $0, token: $1) }) {
        self.serverStore = servers
        self.credentials = credentials
        self.makeTransport = makeTransport
        do { self.servers = try servers.load() }
        catch { status = .failed; message = "无法读取已保存的连接。请检查设备存储后重试。" }
    }

    @discardableResult
    func save(name: String, address: String, token: String, editingID: UUID?) async throws -> ServerConfiguration {
        let server = try ServerConfiguration(id: editingID ?? UUID(), name: name, address: address)
        let previous = servers.first { $0.id == server.id }
        let oldToken = try credentials.load(serverID: server.id)
        let freshToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if freshToken.isEmpty && (previous == nil || previous?.baseURL != server.baseURL) { throw ConnectionError.missingCredential }
        guard let chosenToken = freshToken.isEmpty ? oldToken : freshToken, !chosenToken.isEmpty else { throw ConnectionError.missingCredential }
        var updated = servers.filter { $0.id != server.id }
        if let index = servers.firstIndex(where: { $0.id == server.id }) { updated.insert(server, at: index) }
        else { updated.append(server) }
        try credentials.save(token: chosenToken, serverID: server.id)
        do { try serverStore.save(updated) }
        catch {
            if let oldToken { try credentials.save(token: oldToken, serverID: server.id) }
            else { try credentials.delete(serverID: server.id) }
            throw error
        }
        servers = updated
        await connect(serverID: server.id)
        return server
    }

    func connect(serverID: UUID) async {
        guard let server = servers.first(where: { $0.id == serverID }) else { return }
        let attempt = UUID()
        generation = attempt
        activeServerID = server.id
        info = nil; message = nil; status = .connecting
        let previous = transport
        transport = nil
        await previous?.close()
        guard generation == attempt else { return }
        var candidate: (any BridgeTransport)?
        do {
            guard let token = try credentials.load(serverID: server.id), !token.isEmpty else { throw ConnectionError.missingCredential }
            let next = makeTransport(server, token)
            candidate = next; transport = next
            let result = try await next.get("/v1/info", as: ServerInfo.self)
            guard generation == attempt else { await next.close(); return }
            guard result.apiVersion == 1, !result.serverId.isEmpty else { throw ConnectionError.incompatibleServer }
            info = result; status = .connected
        } catch {
            await candidate?.close()
            guard generation == attempt else { return }
            transport = nil; status = .failed; message = Self.friendlyMessage(error)
        }
    }

    func disconnect() async {
        generation = UUID()
        let previous = transport
        transport = nil; info = nil; status = .disconnected; message = nil
        await previous?.close()
    }

    #if DEBUG
    static func uiTestWorkspace() -> ConnectionModel {
        let server = try! ServerConfiguration(name: "Fixture Windows", address: "https://fixture.invalid")
        let store = ServerStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("CodexRemoteUITest/workspace.json"))
        try? store.save([server])
        let credentials = CredentialStore(backend: UITestKeychain())
        try? credentials.save(token: "fixture-token", serverID: server.id)
        let model = ConnectionModel(servers: store, credentials: credentials)
        model.activeServerID = server.id
        model.transport = UITestWorkspaceTransport(activity: ProcessInfo.processInfo.arguments.contains("--ui-test-activity"))
        model.info = ServerInfo(apiVersion: 1, serverId: "fixture", codexVersion: "0.167.0", features: ["steer": true, "interrupt": true, "queue": false, "approvals": true])
        model.status = .connected
        return model
    }
    #endif

    private static func friendlyMessage(_ error: Error) -> String {
        if let error = error as? ConnectionError {
            switch error {
            case .missingCredential: return "请编辑连接并填写配对令牌。"
            case .incompatibleServer: return "服务版本不兼容，请更新 Windows 桥接服务和 App。"
            case .server(401, _): return "配对令牌不正确，请编辑连接后重试。"
            case .server(503, _): return "Windows 上的 Codex 服务暂时不可用。"
            default: return "服务响应无效，请检查地址和 Windows 桥接服务。"
            }
        }
        if error is URLError { return "无法连接服务。请确认手机和电脑的 EasyTier 已连接，且 Windows 桥接服务正在运行。" }
        if (error as NSError).domain == NSOSStatusErrorDomain { return "无法读取配对令牌，请解锁手机后重试。" }
        return "连接未成功，请检查服务地址和 Windows 桥接服务。"
    }
}
