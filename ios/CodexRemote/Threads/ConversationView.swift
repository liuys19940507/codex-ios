import SwiftUI

@MainActor
struct ConversationView: View {
    let threadID: String
    let serverID: UUID
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var sender: CommandSender
    @EnvironmentObject private var lifecycle: LifecycleController
    @StateObject private var composer: ComposerModel
    @State private var title = "会话"
    @State private var followingLatest = true
    @State private var bottomPosition: CGFloat = .greatestFiniteMagnitude
    @State private var composerPosition: CGFloat = 0
    @State private var manualScrollUntil = Date.distantPast
    @GestureState private var readingGesture = false
    init(threadID: String, serverID: UUID, drafts: DraftStore = DraftStore()) {
        self.threadID = threadID; self.serverID = serverID
        _composer = StateObject(wrappedValue: ComposerModel(serverID: serverID, threadID: threadID, drafts: drafts))
    }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Measure loaded rows consistently; lazy estimates cycled with the composer inset.
                VStack(alignment: .leading, spacing: 20) {
                    if let snapshot = session.snapshot, snapshot.thread.id == threadID {
                        if let reason = snapshot.readOnlyReason { Label(reason, systemImage: "desktopcomputer").font(.callout).foregroundStyle(.secondary) }
                        if snapshot.itemsCursor != nil {
                            Button {
                                let anchor = ConversationTimeline.make(snapshot.items).first?.id
                                Task {
                                    await session.loadMoreHistory(); await Task.yield()
                                    if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                                }
                            } label: { HStack { Text("加载较早记录"); if session.historyLoading { ProgressView() } } }
                            .disabled(session.historyLoading)
                        }
                        if let message = session.historyMessage { Text(message).font(.footnote).foregroundStyle(.secondary) }
                        ForEach(ConversationTimeline.make(snapshot.items)) { row in
                            if row.kind == .process {
                                ProcessView(items: row.items, active: snapshot.thread.activeTurnId == row.turnID, onDraft: draftAction, onInteraction: { followingLatest = false }).id(row.id)
                            } else if let item = row.items.first {
                                ActivityView(item: item, partial: snapshot.thread.activeTurnId == item.turnId, onDraft: draftAction, onContentReady: { scrollToLatestIfFollowing(proxy) }).id(row.id)
                            }
                        }
                        if let parent = snapshot.thread.parentId { NavigationLink("返回父任务", value: parent) }
                        ForEach(snapshot.pending) { request in
                            ApprovalView(request: request, snapshot: snapshot, features: lifecycle.info?.features ?? [:])
                        }
                    } else if session.connectionState == .syncing || session.connectionState == .connecting { ProgressView("正在同步会话…") }
                    if let message = session.message {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(message, systemImage: "exclamationmark.circle")
                            Button("重新同步") { Task { await lifecycle.setActive(true); if lifecycle.ready { await session.selectThread(threadID) } } }
                        }
                    }
                    OperationStatusView()
                    Color.clear.frame(height: 1).id("conversation-end")
                        .background(GeometryReader { value in Color.clear.preference(key: ConversationBottomKey.self, value: value.frame(in: .global).maxY) })
                }.padding()
            }.scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ComposerView(model: composer, snapshot: session.snapshot?.thread.id == threadID ? session.snapshot : nil, features: lifecycle.info?.features ?? [:])
                    .padding(.horizontal, 12).padding(.vertical, 8).background(.bar)
                    .background(GeometryReader { value in Color.clear.preference(key: ConversationComposerKey.self, value: value.frame(in: .global).minY) })
            }
            .onPreferenceChange(ConversationBottomKey.self) { position in
                bottomPosition = position
                if readingGesture || Date() < manualScrollUntil { followingLatest = isNearBottom }
            }
            .onPreferenceChange(ConversationComposerKey.self) { composerPosition = $0 }
            .simultaneousGesture(DragGesture()
                .updating($readingGesture) { _, state, _ in state = true }
                .onChanged { _ in manualScrollUntil = Date().addingTimeInterval(2) }
                .onEnded { _ in followingLatest = isNearBottom; manualScrollUntil = Date().addingTimeInterval(2) })
            .onChange(of: session.snapshot?.cursor) { _ in
                scrollToLatestIfFollowing(proxy)
            }
            .accessibilityAction(named: Text("停止自动跟随")) { followingLatest = false }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        Task {
                            if !lifecycle.active || !lifecycle.ready { await lifecycle.setActive(true) }
                            else { await session.refreshThread(threadID) }
                        }
                    } label: { if session.refreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") } }
                    .accessibilityLabel("刷新历史并重新连接").disabled(session.refreshing || sender.busy)
                    if lifecycle.info?.features["interrupt"] == true, let current = session.snapshot, current.thread.id == threadID, let turn = current.thread.activeTurnId {
                        Button(role: .destructive) {
                            Task { _ = await sender.submit(method: .interrupt, params: ["threadId": .string(threadID), "turnId": .string(turn)]) }
                        } label: { Image(systemName: "stop.circle") }
                        .accessibilityLabel("中断当前轮次").disabled(sender.busy || !sender.canSubmit(.interrupt))
                    }
                    Button { manualScrollUntil = .distantPast; followingLatest = true; proxy.scrollTo("conversation-end", anchor: .bottom) } label: { Image(systemName: "arrow.down.to.line") }
                        .accessibilityLabel("查看最新输出")
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ui-test-events"), let fixture = session.transport as? UITestWorkspaceTransport {
                        Button { Task { await fixture.emitNextOutput() } } label: { Image(systemName: "waveform.path.badge.plus") }
                            .accessibilityLabel("接收测试输出")
                            .accessibilityValue("事件 \(session.snapshot?.cursor.seq ?? -1)")
                    }
                    #endif
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: threadID) { await session.openThread(threadID) }
        .onChange(of: session.snapshot?.thread) { if let thread = $0, thread.id == threadID { title = thread.title } }
    }
    private var isNearBottom: Bool { composerPosition > 0 && bottomPosition <= composerPosition + 80 }
    private func scrollToLatestIfFollowing(_ proxy: ScrollViewProxy) {
        guard followingLatest, !readingGesture, !session.historyLoading, session.snapshot?.thread.id == threadID else { return }
        Task { @MainActor in
            await Task.yield()
            guard followingLatest, !readingGesture, session.selectedThreadID == threadID else { return }
            proxy.scrollTo("conversation-end", anchor: .bottom)
        }
    }
    private var draftAction: ((String) -> Void)? {
        guard composer.writable else { return nil }
        return { text in composer.text += composer.text.isEmpty ? text : "\n\n" + text }
    }
}

private struct ConversationBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct ConversationComposerKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
