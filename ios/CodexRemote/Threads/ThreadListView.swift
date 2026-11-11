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
    @StateObject private var sender: CommandSender
    @StateObject private var lifecycle: LifecycleController
    @StateObject private var settings: ModelSettings
    @StateObject private var navigation: WorkspaceNavigator
    @Environment(\.scenePhase) private var phase
    init(server: ServerConfiguration, transport: any BridgeTransport) {
        self.server = server; self.transport = transport
        let session = SessionStore()
        let lifecycle = LifecycleController(session: session, server: server, transport: transport)
        _session = StateObject(wrappedValue: session)
        _lifecycle = StateObject(wrappedValue: lifecycle)
        _navigation = StateObject(wrappedValue: WorkspaceNavigator(session: session))
        _settings = StateObject(wrappedValue: ModelSettings(serverID: server.id, transport: transport))
        _threads = StateObject(wrappedValue: ThreadListModel(transport: transport, serverID: server.id))
        _sender = StateObject(wrappedValue: CommandSender(serverID: server.id, transport: transport, canSend: { [weak lifecycle] in lifecycle?.canWrite($0) == true }))
    }
    var body: some View {
        NavigationStack(path: $navigation.path) {
            ThreadListView(model: threads, serverID: server.id, openThread: { navigation.path.append($0) })
                .workspaceNavigationMenu()
                .navigationDestination(for: WorkspaceDestination.self) { destination in
                    switch destination {
                    case .tasks: EmptyView()
                    case .connections: ConnectionView().workspaceNavigationMenu()
                    case .settings: SettingsView().workspaceNavigationMenu()
                    }
                }
        }
        .environment(\.workspaceNavigation, { destination in Task { await navigation.show(destination) } })
        .environmentObject(session)
        .environmentObject(sender)
        .environmentObject(lifecycle)
        .environmentObject(settings)
        .task {
            await session.connect(server: server, transport: transport)
            await lifecycle.setActive(phase == .active)
            await settings.load()
        }
        .onChange(of: phase) { value in Task { await lifecycle.setActive(value == .active) } }
        .onChange(of: navigation.path.count) { _ in
            if navigation.path.isEmpty, let id = session.selectedThreadID {
                let attachment = session.attachmentID
                Task { await session.leaveThread(id, attachmentID: attachment) }
            }
        }
        .onDisappear { Task { await lifecycle.setActive(false); await session.disconnect() } }
    }
}

@MainActor
struct ThreadListView: View {
    @ObservedObject var model: ThreadListModel
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var sender: CommandSender
    @EnvironmentObject private var lifecycle: LifecycleController
    @EnvironmentObject private var settings: ModelSettings
    @Environment(\.dynamicTypeSize) private var typeSize
    let serverID: UUID
    let openThread: (String) -> Void
    @State private var projectID: String?
    @State private var query = ""
    @State private var creating = false
    @State private var createdThreadID: String?
    @State private var renaming: ThreadSummary?
    @State private var renameTitle = ""
    @State private var archiving: ThreadSummary?
    private struct Search: Hashable { let project: String?; let query: String }
    var body: some View {
        List {
            if let warning = session.releaseMessage { Text(warning).font(.footnote).foregroundStyle(.secondary) }
            if !lifecycle.ready {
                Section {
                    Text(lifecycle.message ?? "正在校验服务并同步状态…").font(.footnote)
                    Button("重新同步连接") { Task { await lifecycle.setActive(true) } }
                }
            }
            if !model.projects.isEmpty {
                Section {
                    Picker("项目", selection: $projectID) {
                        Text("全部项目").tag(nil as String?)
                        ForEach(model.projects) { project in Text("\(project.name) · \(project.path)").tag(Optional(project.id)) }
                    }
                }
            }
            if let message = model.projectMessage { Section { Text(message).foregroundStyle(.secondary) } }
            if let message = model.pinMessage { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
            if !model.visiblePinnedThreads.isEmpty {
                Section("置顶任务") { taskRows(model.visiblePinnedThreads) }
            }
            if model.loading || !model.hasLoaded { ProgressView("正在读取任务…") }
            else if model.threads.isEmpty && model.visiblePinnedThreads.isEmpty && model.message == nil { Text(query.isEmpty ? "暂无会话" : "没有匹配的任务").foregroundStyle(.secondary) }
            if model.visiblePinnedThreads.isEmpty { taskRows(model.unpinnedThreads) }
            else if !model.unpinnedThreads.isEmpty {
                Section("其他任务") { taskRows(model.unpinnedThreads) }
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
            if sender.lastOperation != nil || !sender.unresolved.isEmpty || sender.message != nil {
                Section("操作状态") { OperationStatusView(openThread: openThread) }
            }
        }
        .navigationTitle("任务")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: { Label("新任务", systemImage: "plus") }
                    .disabled(model.projects.isEmpty || !sender.canSubmit(.create) || !settings.canCreate)
            }
        }
        .searchable(text: $query, prompt: "搜索任务")
        .navigationDestination(for: String.self) { id in ConversationView(threadID: id, serverID: serverID).workspaceNavigationMenu() }
        .task { await model.loadProjects() }
        .task(id: Search(project: projectID, query: query)) {
            if !query.isEmpty { try? await Task.sleep(nanoseconds: 250_000_000) }
            guard !Task.isCancelled else { return }
            await model.reload(projectID: projectID, query: query)
        }
        .refreshable { await model.loadProjects(); await model.reload(projectID: projectID, query: query) }
        .sheet(isPresented: $creating, onDismiss: {
            if let id = createdThreadID { createdThreadID = nil; openThread(id) }
        }) {
            NavigationStack {
                NewTaskView(projects: model.projects, serverID: serverID, selectedProjectID: projectID) { id in
                    createdThreadID = id; creating = false
                    Task { await model.reload(projectID: projectID, query: query) }
                }
            }.environmentObject(sender).environmentObject(session).environmentObject(settings).environmentObject(lifecycle)
        }
        .alert("重命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("会话名称", text: $renameTitle)
            Button("保存") {
                guard let target = renaming else { return }
                let title = renameTitle
                Task {
                    let result = await sender.submit(method: .rename, params: ["threadId": .string(target.id), "title": .string(title)])
                    if result.state == .accepted { model.renamePinned(target.id, title: title); await model.reload(projectID: projectID, query: query) }
                }
            }.disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sender.busy)
            Button("取消", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("归档此会话？", isPresented: Binding(get: { archiving != nil }, set: { if !$0 { archiving = nil } }), titleVisibility: .visible) {
            Button("确认归档", role: .destructive) {
                guard let target = archiving else { return }
                Task {
                    let result = await sender.submit(method: .archive, params: ["threadId": .string(target.id)])
                    if result.state == .accepted { model.removePin(target.id); await model.reload(projectID: projectID, query: query) }
                }
            }
            Button("取消", role: .cancel) { archiving = nil }
        }
    }
    private func taskRows(_ threads: [ThreadSummary]) -> some View {
        ForEach(threads) { thread in
            NavigationLink(value: thread.id) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(thread.title).font(.headline).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                        Text(status(thread)).font(.caption).foregroundStyle(.secondary)
                        if let project = model.projects.first(where: { $0.id == thread.projectId }) {
                            Text(project.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 0)
                    if model.isPinned(thread.id) { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange).accessibilityHidden(true) }
                }.padding(.vertical, 4)
            }
            .accessibilityIdentifier("thread-row-\(thread.id)")
            .accessibilityValue(model.isPinned(thread.id) ? "已置顶" : "")
            .disabled(session.currentServerID != serverID || session.transport == nil)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button { model.togglePin(thread) } label: {
                    Label(model.isPinned(thread.id) ? "取消置顶" : "置顶", systemImage: model.isPinned(thread.id) ? "pin.slash" : "pin")
                }.tint(.orange)
            }
            .contextMenu {
                Button { model.togglePin(thread) } label: {
                    Label(model.isPinned(thread.id) ? "取消置顶" : "置顶", systemImage: model.isPinned(thread.id) ? "pin.slash" : "pin")
                }
                Button("重命名") { renameTitle = thread.title; renaming = thread }
                    .disabled(sender.busy || !sender.canSubmit(.rename))
                Button("归档", role: .destructive) { archiving = thread }
                    .disabled(sender.busy || !sender.canSubmit(.archive) || thread.activeTurnId != nil || thread.status == "active")
            }
        }
    }
    private func status(_ thread: ThreadSummary) -> String {
        if thread.activeTurnId != nil || thread.status == "active" { return "进行中" }
        if thread.status == "notLoaded" { return "历史会话" }
        return thread.status == "idle" || thread.status == "completed" ? "空闲" : "等待刷新"
    }
}
