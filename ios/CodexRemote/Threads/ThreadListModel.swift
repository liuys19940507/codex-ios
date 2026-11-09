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
    private let transport: any BridgeTransport
    private var generation = UUID()
    private var filter: (projectID: String?, query: String) = (nil, "")
    init(transport: any BridgeTransport) { self.transport = transport }

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
            threads = merge([], page.data); nextCursor = page.nextCursor
        } catch {
            guard generation == request else { return }
            message = "无法读取任务列表，请重试。"
        }
        loading = false; hasLoaded = true
    }
    func loadMore() async {
        guard !loading, !loadingMore, let nextCursor else { return }
        let request = generation, chosen = filter
        loadingMore = true; message = nil
        do {
            let page = try await transport.get(path(projectID: chosen.projectID, query: chosen.query, cursor: nextCursor), as: ThreadPage.self)
            guard generation == request else { return }
            guard page.nextCursor != nextCursor else { throw ConnectionError.invalidResponse }
            threads = merge(threads, page.data); self.nextCursor = page.nextCursor
        } catch {
            guard generation == request else { return }
            message = "无法加载更多任务，请重试。"
        }
        loadingMore = false
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
