import SwiftUI

@MainActor
struct AppRootView: View {
    @EnvironmentObject private var connection: ConnectionModel
    var body: some View {
        if connection.status == .connected, let server = connection.servers.first(where: { $0.id == connection.activeServerID }), let transport = connection.transport {
            WorkspaceView(server: server, transport: transport).id(server.id)
        } else { NavigationStack { ConnectionView() } }
    }
}

@MainActor
private struct WorkspaceView: View {
    let server: ServerConfiguration
    let transport: any BridgeTransport
    @StateObject private var session: SessionStore
    @StateObject private var threads: ThreadListModel
    init(server: ServerConfiguration, transport: any BridgeTransport) {
        self.server = server; self.transport = transport
        _session = StateObject(wrappedValue: SessionStore())
        _threads = StateObject(wrappedValue: ThreadListModel(transport: transport))
    }
    var body: some View {
        TabView {
            NavigationStack { ThreadListView(model: threads, serverID: server.id) }
                .tabItem { Label("任务", systemImage: "list.bullet.rectangle") }
            NavigationStack { ConnectionView() }
                .tabItem { Label("连接", systemImage: "network") }
        }
        .environmentObject(session)
        .task { await session.connect(server: server, transport: transport) }
        .onDisappear { Task { await session.disconnect() } }
    }
}

@MainActor
struct ThreadListView: View {
    @ObservedObject var model: ThreadListModel
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dynamicTypeSize) private var typeSize
    let serverID: UUID
    @State private var projectID: String?
    @State private var query = ""
    private struct Search: Hashable { let project: String?; let query: String }
    var body: some View {
        List {
            if !model.projects.isEmpty {
                Section {
                    Picker("项目", selection: $projectID) {
                        Text("全部项目").tag(nil as String?)
                        ForEach(model.projects) { project in Text(project.name).tag(Optional(project.id)) }
                    }
                }
            }
            if let message = model.projectMessage { Section { Text(message).foregroundStyle(.secondary) } }
            if model.loading || !model.hasLoaded { ProgressView("正在读取任务…") }
            else if model.threads.isEmpty && model.message == nil { Text(query.isEmpty ? "暂无会话" : "没有匹配的任务").foregroundStyle(.secondary) }
            ForEach(model.threads) { thread in
                NavigationLink(value: thread.id) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(thread.title).font(.headline).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                        Text(status(thread)).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
                .disabled(session.currentServerID != serverID || session.transport == nil)
            }
            if let message = model.message {
                Section {
                    Label(message, systemImage: "exclamationmark.circle")
                    Button("重试") { Task { await model.reload(projectID: projectID, query: query) } }
                }
            }
            if model.nextCursor != nil {
                Button { Task { await model.loadMore() } } label: {
                    HStack { Text("加载更多"); if model.loadingMore { Spacer(); ProgressView() } }
                }.disabled(model.loading || model.loadingMore)
            }
        }
        .navigationTitle("任务")
        .searchable(text: $query, prompt: "搜索任务")
        .navigationDestination(for: String.self) { id in ConversationView(threadID: id, serverID: serverID) }
        .task { await model.loadProjects() }
        .task(id: Search(project: projectID, query: query)) {
            if !query.isEmpty { try? await Task.sleep(nanoseconds: 250_000_000) }
            guard !Task.isCancelled else { return }
            await model.reload(projectID: projectID, query: query)
        }
        .refreshable { await model.loadProjects(); await model.reload(projectID: projectID, query: query) }
    }
    private func status(_ thread: ThreadSummary) -> String {
        if thread.activeTurnId != nil || thread.status == "active" { return "进行中" }
        if thread.status == "notLoaded" { return "历史会话" }
        return thread.status == "idle" || thread.status == "completed" ? "空闲" : "等待刷新"
    }
}
