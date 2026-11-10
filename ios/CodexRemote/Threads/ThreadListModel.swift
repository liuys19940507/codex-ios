import Foundation
import Combine

@MainActor
final class ThreadListModel: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published private(set) var threads: [ThreadSummary] = []
    @Published private(set) var loading = false
    @Published private(set) var loadingMore = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var message: String?
    @Published private(set) var projectMessage: String?
    @Published private(set) var nextCursor: String?
    @Published private(set) var pinnedThreads: [ThreadSummary] = []
    @Published private(set) var pinMessage: String?
    private let transport: any BridgeTransport
    private let serverID: UUID?
    private let pinStore: PinnedThreadStore
    private var generation = UUID()
    private var filter: (projectID: String?, query: String) = (nil, "")
    init(transport: any BridgeTransport, serverID: UUID? = nil, pinStore: PinnedThreadStore = PinnedThreadStore()) {
        self.transport = transport; self.serverID = serverID; self.pinStore = pinStore
        if let serverID {
            do { pinnedThreads = try pinStore.load(serverID: serverID) }
            catch { pinMessage = "无法读取置顶记录，普通任务仍可正常使用。" }
        }
    }
    var visiblePinnedThreads: [ThreadSummary] {
        let listed = Set(threads.map(\.id))
        return pinnedThreads.filter {
            (filter.projectID == nil || $0.projectId == filter.projectID) &&
            (filter.query.isEmpty || $0.title.localizedCaseInsensitiveContains(filter.query) || listed.contains($0.id))
        }
    }
    var unpinnedThreads: [ThreadSummary] {
        let pinned = Set(pinnedThreads.map(\.id))
        return threads.filter { !pinned.contains($0.id) }
    }
    func isPinned(_ id: String) -> Bool { pinnedThreads.contains { $0.id == id } }
    func togglePin(_ thread: ThreadSummary) {
        if isPinned(thread.id) { removePin(thread.id) }
        else { persistPins([thread] + pinnedThreads) }
    }
    func removePin(_ id: String) {
        guard isPinned(id) else { return }
        persistPins(pinnedThreads.filter { $0.id != id })
    }
    func renamePinned(_ id: String, title: String) {
        guard var thread = pinnedThreads.first(where: { $0.id == id }) else { return }
        thread.title = title; updatePins([thread])
    }
    private func persistPins(_ next: [ThreadSummary]) {
        guard let serverID, next != pinnedThreads else { return }
        do { try pinStore.save(next, serverID: serverID); pinnedThreads = next; pinMessage = nil }
        catch { pinMessage = "无法保存置顶设置，已保留原来的置顶顺序。" }
    }
    private func updatePins(_ fresh: [ThreadSummary]) {
        let values = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        persistPins(pinnedThreads.map { values[$0.id] ?? $0 })
    }

    func loadProjects() async {
        do { projects = try await transport.get("/v1/projects", as: [Project].self); projectMessage = nil }
        catch { projectMessage = "无法读取项目列表，请刷新重试。" }
    }
    func reload(projectID: String?, query: String) async {
        let request = UUID(); generation = request; filter = (projectID, query)
        loading = true; loadingMore = false; hasLoaded = false; threads = []; nextCursor = nil; message = nil
        do {
            let page = try await transport.get(path(projectID: projectID, query: query, cursor: nil), as: ThreadPage.self)
            guard generation == request else { return }
            threads = merge([], page.data); nextCursor = page.nextCursor; updatePins(page.data)
        } catch {
            guard generation == request else { return }
            message = "无法读取任务列表，请重试。"
        }
        loading = false; hasLoaded = true
        if message == nil { await refreshMissingPins(request: request) }
    }
    func loadMore() async {
        guard !loading, !loadingMore, let nextCursor else { return }
        let request = generation, chosen = filter
        loadingMore = true; message = nil
        do {
            let page = try await transport.get(path(projectID: chosen.projectID, query: chosen.query, cursor: nextCursor), as: ThreadPage.self)
            guard generation == request else { return }
            guard page.nextCursor != nextCursor else { throw ConnectionError.invalidResponse }
            threads = merge(threads, page.data); self.nextCursor = page.nextCursor; updatePins(page.data)
        } catch {
            guard generation == request else { return }
            message = "无法加载更多任务，请重试。"
        }
        loadingMore = false
    }
    private func refreshMissingPins(request: UUID) async {
        let listed = Set(threads.map(\.id))
        let missing = pinnedThreads.filter { !listed.contains($0.id) && (filter.projectID == nil || $0.projectId == filter.projectID) }.map(\.id)
        guard !missing.isEmpty else { return }
        // Older servers keep the local cache. A snapshot GET is not a safe
        // fallback: it can establish a native subscription for a loaded task.
        do {
            let info = try await transport.get("/v1/info", as: ServerInfo.self)
            guard generation == request, info.features["threadMetadata"] == true else { return }
        } catch {
            if generation == request { pinMessage = "暂时无法刷新置顶任务，已保留本机记录。" }
            return
        }
        var failed = false
        for id in missing {
            guard generation == request else { return }
            guard isPinned(id), let pathID = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) else { continue }
            do {
                let thread = try await transport.get("/v1/threads/\(pathID)/metadata", as: ThreadSummary.self)
                guard generation == request else { return }
                guard thread.id == id else { throw ConnectionError.invalidResponse }
                updatePins([thread])
            } catch {
                guard generation == request else { return }
                if let error = error as? ConnectionError, case .server(404, _) = error { removePin(id) }
                else { failed = true }
            }
        }
        if failed { pinMessage = "部分置顶任务暂未刷新，已保留上次记录。" }
    }
    private func path(projectID: String?, query: String, cursor: String?) -> String {
        var components = URLComponents(); components.path = "/v1/threads"
        var params: [URLQueryItem] = []
        if let projectID { params.append(URLQueryItem(name: "projectId", value: projectID)) }
        if !query.isEmpty { params.append(URLQueryItem(name: "query", value: query)) }
        if let cursor { params.append(URLQueryItem(name: "cursor", value: cursor)) }
        components.queryItems = params.isEmpty ? nil : params
        return components.string!
    }
    private func merge(_ current: [ThreadSummary], _ next: [ThreadSummary]) -> [ThreadSummary] {
        var ids = Set<String>()
        return (current + next).filter { ids.insert($0.id).inserted }
    }
}
