import Foundation
import Combine

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var cursor: Cursor?
    @Published private(set) var connectionState: SyncState = .disconnected
    @Published private(set) var currentServerID: UUID?
    @Published private(set) var message: String?
    private(set) var transport: (any BridgeTransport)?
    private let makeTransport: @MainActor (ServerConfiguration) async throws -> any BridgeTransport
    private let cursors: CursorStore
    private var generation = UUID(), selection = UUID(), streamID = UUID()
    private var stream: Task<Void, Never>?
    private var selectedThread: String?
    private var loading = false
    private var buffered: [Envelope] = []
    private var overflow = false

    init(makeTransport: @escaping @MainActor (ServerConfiguration) async throws -> any BridgeTransport = { server in
        guard let token = try CredentialStore().load(serverID: server.id) else { throw ConnectionError.missingCredential }
        return URLSessionTransport(server: server, token: token)
    }, cursors: CursorStore = CursorStore()) {
        self.makeTransport = makeTransport; self.cursors = cursors
    }

    func connect(server: ServerConfiguration, transport supplied: (any BridgeTransport)? = nil) async {
        let connection = UUID()
        generation = connection; selection = UUID(); streamID = UUID()
        stream?.cancel(); stream = nil
        let previous = transport
        transport = nil; snapshot = nil; selectedThread = nil; loading = false; buffered = []; overflow = false
        currentServerID = server.id; cursor = nil; message = nil; connectionState = .connecting
        await previous?.close()
        guard generation == connection else { return }
        do {
            let next: any BridgeTransport
            if let supplied { next = supplied } else { next = try await makeTransport(server) }
            guard generation == connection else { await next.close(); return }
            transport = next
            cursor = try cursors.load(serverID: server.id)
            connectionState = .syncing
        } catch {
            guard generation == connection else { return }
            connectionState = .failed; message = "无法准备任务连接，请重新连接服务。"
        }
    }

    func selectThread(_ id: String) async {
        guard let transport, let serverID = currentServerID else { return }
        let connection = generation, chosen = UUID(), originalEpoch = cursor?.epoch
        selection = chosen; selectedThread = id; loading = true; buffered = []; overflow = false
        snapshot = nil; message = nil; connectionState = .syncing
        let pathID = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? ""
        do {
            guard !pathID.isEmpty else { throw ConnectionError.invalidPath }
            for attempt in 0..<3 {
                let fresh = try await transport.get("/v1/threads/\(pathID)/snapshot", as: Snapshot.self)
                guard generation == connection, selection == chosen else { return }
                guard fresh.thread.id == id, fresh.cursor.seq >= 0 else { throw ConnectionError.invalidResponse }
                var projected = fresh, invalid = false
                let received = cursor
                if overflow, received?.epoch != fresh.cursor.epoch || (received?.seq ?? 0) > fresh.cursor.seq { invalid = true }
                for event in buffered {
                    if event.cursor.epoch != projected.cursor.epoch {
                        if event.cursor.epoch == originalEpoch && fresh.cursor.epoch != originalEpoch { continue }
                        invalid = true; break
                    }
                    if event.cursor.seq <= projected.cursor.seq { continue }
                    if event.cursor.seq != projected.cursor.seq + 1 { invalid = true; break }
                    projected = reduce(snapshot: projected, event: event)
                }
                buffered = []; overflow = false
                if invalid {
                    stream?.cancel(); stream = nil; streamID = UUID()
                    if attempt == 2 { throw ConnectionError.invalidResponse }
                    continue
                }
                snapshot = projected; cursor = projected.cursor; loading = false
                try cursors.save(projected.cursor, serverID: serverID)
                connectionState = .connected
                if stream == nil || originalEpoch != projected.cursor.epoch { startStream(transport, after: projected.cursor, connection: connection) }
                return
            }
        } catch {
            guard generation == connection, selection == chosen else { return }
            loading = false; buffered = []; snapshot = nil
            connectionState = .failed; message = "无法同步任务，请刷新后重试。"
        }
    }

    private func startStream(_ transport: any BridgeTransport, after: Cursor, connection: UUID) {
        stream?.cancel()
        let identifier = UUID(); streamID = identifier
        stream = Task { [weak self] in
            do {
                for try await frame in transport.events(after: after) {
                    guard !Task.isCancelled, let self, self.generation == connection, self.streamID == identifier else { return }
                    switch frame {
                    case .event(let event): self.receive(event)
                    case .resyncRequired: self.resynchronize()
                    }
                }
                guard !Task.isCancelled, let self, self.generation == connection, self.streamID == identifier else { return }
                self.connectionState = .failed; self.message = "实时连接已断开，请重新同步任务。"
            } catch {
                guard !Task.isCancelled, let self, self.generation == connection, self.streamID == identifier else { return }
                self.connectionState = .failed; self.message = "实时连接已断开，请重新同步任务。"
            }
        }
    }

    private func receive(_ event: Envelope) {
        guard let current = cursor, let serverID = currentServerID else { resynchronize(); return }
        if event.cursor.epoch == current.epoch && event.cursor.seq <= current.seq { return }
        if loading {
            if buffered.count < 2000 { buffered.append(event) } else { overflow = true }
            if event.cursor.epoch == current.epoch { cursor = event.cursor }
            return
        }
        guard event.cursor.epoch == current.epoch, event.cursor.seq == current.seq + 1 else { resynchronize(); return }
        // All observed threads share one cursor. Filtering inside the reducer
        // happens only after validating and advancing this global sequence.
        cursor = event.cursor
        if let value = snapshot { snapshot = reduce(snapshot: value, event: event) }
        do { try cursors.save(event.cursor, serverID: serverID) }
        catch { connectionState = .failed; message = "无法保存同步状态，请检查设备存储。" }
    }

    private func resynchronize() {
        guard let id = selectedThread else { connectionState = .syncing; return }
        if loading { overflow = true; return }
        stream?.cancel(); stream = nil; streamID = UUID()
        connectionState = .syncing
        let connection = generation
        Task { [weak self] in
            guard let self, self.generation == connection else { return }
            await self.selectThread(id)
        }
    }

    func disconnect() async {
        generation = UUID(); selection = UUID(); streamID = UUID()
        stream?.cancel(); stream = nil
        let previous = transport
        transport = nil; snapshot = nil; cursor = nil; currentServerID = nil; selectedThread = nil
        loading = false; buffered = []; message = nil; connectionState = .disconnected
        await previous?.close()
    }
}
