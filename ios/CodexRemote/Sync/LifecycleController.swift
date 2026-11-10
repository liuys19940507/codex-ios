import Foundation
import Combine

@MainActor
final class LifecycleController: ObservableObject {
    @Published private(set) var ready = false
    @Published private(set) var active = false
    @Published private(set) var info: ServerInfo?
    @Published private(set) var message: String?
    private let session: SessionStore
    private let server: ServerConfiguration
    private let transport: any BridgeTransport
    private var generation = UUID()
    init(session: SessionStore, server: ServerConfiguration, transport: any BridgeTransport) {
        self.session = session; self.server = server; self.transport = transport
    }
    func setActive(_ value: Bool) async {
        let request = UUID(); generation = request
        active = value; ready = false; message = nil
        await session.suspend()
        guard value, active, generation == request else { return }
        do {
            let fresh = try await transport.get("/v1/info", as: ServerInfo.self)
            guard active, generation == request else { return }
            info = fresh
            guard fresh.apiVersion == 1, !fresh.serverId.isEmpty else { throw ConnectionError.incompatibleServer }
            let synchronized = await session.resumeForeground()
            guard active, generation == request else { return }
            ready = synchronized
            if !synchronized { message = "会话尚未同步，发送和审批暂不可用。" }
        } catch {
            guard active, generation == request else { return }
            if let failure = error as? ConnectionError, case .incompatibleServer = failure { message = "服务版本不兼容，请更新 App 和 Windows 桥接。" }
            else { message = "恢复连接失败，请检查 EasyTier 后重新同步。" }
        }
    }
    func canWrite(_ method: Command.Method) -> Bool {
        guard active, ready, info?.apiVersion == 1, session.currentServerID == server.id, session.transport != nil else { return false }
        switch method {
        case .create, .rename, .archive: return session.connectionState != .failed && session.connectionState != .disconnected
        default: return session.connectionState == .connected
        }
    }
}
