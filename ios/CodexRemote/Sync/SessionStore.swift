import Foundation
import Combine

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var cursor: Cursor?
    @Published private(set) var connectionState: SyncState = .disconnected
    @Published private(set) var currentServerID: UUID?
    @Published private(set) var message: String?
    @Published private(set) var historyLoading = false
    @Published private(set) var historyMessage: String?
    @Published private(set) var refreshing = false
    @Published private(set) var releaseMessage: String?
    private struct Attachment { let threadID: String; let id: UUID }
    private var attachment: Attachment?
    var attachmentID: UUID? { attachment?.id }
    var selectedThreadID: String? { selectedThread }
    var canControl: Bool { snapshot != nil && snapshot?.readOnlyReason == nil && connectionState == .connected }
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
        let previousAttachment = attachment
        attachment = nil; refreshing = false
        transport = nil; snapshot = nil; selectedThread = nil; loading = false; buffered = []; overflow = false
        currentServerID = server.id; cursor = nil; message = nil; connectionState = .connecting
        historyLoading = false; historyMessage = nil
        if let previous, let previousAttachment { await release(previousAttachment, using: previous) }
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
        historyLoading = false; historyMessage = nil
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

    func openThread(_ id: String) async {
        guard let transport else { return }
        if attachment?.threadID == id { await refreshThread(id); return }
        let previous = attachment, next = Attachment(threadID: id, id: UUID()), connection = generation
        attachment = next; selectedThread = id; selection = UUID()
        stream?.cancel(); stream = nil; streamID = UUID()
        snapshot = nil; message = nil; connectionState = .syncing
        if let previous { await release(previous, using: transport) }
        guard generation == connection, attachment?.id == next.id else { return }
        await refreshThread(id)
    }

    func refreshThread(_ id: String) async {
        guard let transport, let current = attachment, current.threadID == id else { await selectThread(id); return }
        let connection = generation
        refreshing = true; message = nil; connectionState = .syncing
        defer { if generation == connection, attachment?.id == current.id { refreshing = false } }
        do {
            let command = Command(id: UUID().uuidString, method: .attach, params: ["threadId": .string(id), "attachmentId": .string(current.id.uuidString)])
            let receipt = try await transport.command(command)
            guard generation == connection, attachment?.id == current.id else { return }
            guard receipt.id == command.id, receipt.state == .accepted else { throw ClientCommandError(message: receipt.message ?? "会话连接未确认，请刷新重试。") }
            await selectThread(id)
        } catch {
            guard generation == connection, attachment?.id == current.id else { return }
            connectionState = .failed; message = "无法重新连接会话，请检查 EasyTier 后刷新重试。"
        }
    }

    func leaveThread(_ id: String, attachmentID expected: UUID?) async {
        guard let current = attachment, current.threadID == id, current.id == expected else { return }
        attachment = nil; selectedThread = nil; selection = UUID(); streamID = UUID()
        stream?.cancel(); stream = nil
        snapshot = nil; loading = false; buffered = []; overflow = false; refreshing = false
        historyLoading = false; historyMessage = nil; message = nil; connectionState = .syncing
        if let transport { await transport.cancelEvents(); await release(current, using: transport) }
    }

    private func release(_ current: Attachment, using transport: any BridgeTransport) async {
        do {
            let command = Command(id: UUID().uuidString, method: .release, params: ["threadId": .string(current.threadID), "attachmentId": .string(current.id.uuidString)])
            let receipt = try await transport.command(command)
            guard receipt.id == command.id, receipt.state == .accepted else { throw ConnectionError.invalidResponse }
            releaseMessage = nil
        } catch { releaseMessage = "尚未确认释放上一会话的连接，请保持 EasyTier 在线后重新进入并返回列表。" }
    }

    private func startStream(_ transport: any BridgeTransport, after: Cursor, connection: UUID) {
        stream?.cancel()
        let identifier = UUID(); streamID = identifier
        stream = Task { [weak self] in
            defer {
                if self?.generation == connection && self?.streamID == identifier { self?.stream = nil }
            }
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

    func loadMoreHistory() async {
        guard !loading, !historyLoading, let value = snapshot, let anchor = value.itemsCursor, let transport else { return }
        let connection = generation, chosen = selection, id = value.thread.id
        historyLoading = true; historyMessage = nil
        defer { if generation == connection && selection == chosen { historyLoading = false } }
        do {
            let pathID = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? ""
            var path = URLComponents(); path.percentEncodedPath = "/v1/threads/\(pathID)/items"
            path.queryItems = [URLQueryItem(name: "cursor", value: anchor)]
            let page = try await transport.get(path.string!, as: ItemPage.self)
            guard generation == connection, selection == chosen, let current = snapshot, current.thread.id == id else { return }
            guard page.nextCursor != anchor else { throw ConnectionError.invalidResponse }
            snapshot = Snapshot(cursor: current.cursor, thread: current.thread, items: mergeHistory(older: page.data, current: current.items),
                                itemsCursor: page.nextCursor, pending: current.pending, policy: current.policy, readOnlyReason: current.readOnlyReason)
            let existing = Set(current.items.map(\.id))
            let added = Set(page.data.map(\.id)).subtracting(existing).count
            if page.nextCursor == nil {
                historyMessage = added > 0 ? "已加载较早的\(added)条记录，已到最早记录。" : "已到最早记录。"
            } else {
                historyMessage = added > 0 ? "已加载较早的\(added)条记录。" : "未发现新增记录，可继续加载较早记录。"
            }
        } catch {
            guard generation == connection, selection == chosen else { return }
            if let failure = error as? ConnectionError, case .server(409, _) = failure { await selectThread(id) }
            else { historyMessage = "无法加载较早的记录，请重试。" }
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
        let connection = generation, chosen = selection
        Task { [weak self] in
            guard let self, self.generation == connection, self.selection == chosen, self.selectedThread == id else { return }
            await self.selectThread(id)
        }
    }

    func suspend() async {
        generation = UUID(); selection = UUID(); streamID = UUID()
        stream?.cancel(); stream = nil
        loading = false; buffered = []; overflow = false
        historyLoading = false; historyMessage = nil
        connectionState = .disconnected
        message = "实时连接已暂停，恢复后会重新同步。"
        await transport?.cancelEvents()
    }

    func resumeForeground() async -> Bool {
        guard transport != nil, currentServerID != nil else { return false }
        if let id = selectedThread {
            if attachment != nil { await refreshThread(id) } else { await selectThread(id) }
            return connectionState == .connected
        }
        connectionState = .syncing; message = nil
        return true
    }

    func disconnect() async {
        generation = UUID(); selection = UUID(); streamID = UUID()
        stream?.cancel(); stream = nil
        let previous = transport
        let previousAttachment = attachment
        attachment = nil; refreshing = false
        transport = nil; snapshot = nil; cursor = nil; currentServerID = nil; selectedThread = nil
        loading = false; buffered = []; message = nil; connectionState = .disconnected
        historyLoading = false; historyMessage = nil
        if let previous, let previousAttachment { await release(previousAttachment, using: previous) }
        await previous?.close()
    }
}
