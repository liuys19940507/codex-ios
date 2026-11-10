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
    init(threadID: String, serverID: UUID, drafts: DraftStore = DraftStore()) {
        self.threadID = threadID; self.serverID = serverID
        _composer = StateObject(wrappedValue: ComposerModel(serverID: serverID, threadID: threadID, drafts: drafts))
    }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if let snapshot = session.snapshot, snapshot.thread.id == threadID {
                        if snapshot.itemsCursor != nil {
                            Button {
                                let anchor = snapshot.items.first?.id
                                Task {
                                    await session.loadMoreHistory(); await Task.yield()
                                    if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                                }
                            } label: { HStack { Text("加载较早记录"); if session.historyLoading { ProgressView() } } }
                            .disabled(session.historyLoading)
                        }
                        if let message = session.historyMessage { Text(message).font(.footnote).foregroundStyle(.secondary) }
                        ForEach(snapshot.items) { item in
                            ActivityView(item: item, partial: snapshot.thread.activeTurnId == item.turnId).id(item.id)
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
                    ComposerView(model: composer, snapshot: session.snapshot?.thread.id == threadID ? session.snapshot : nil, features: lifecycle.info?.features ?? [:])
                    OperationStatusView()
                    Color.clear.frame(height: 1).id("conversation-end")
                }.padding()
            }.scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if lifecycle.info?.features["interrupt"] == true, let current = session.snapshot, current.thread.id == threadID, let turn = current.thread.activeTurnId {
                        Button(role: .destructive) {
                            Task { _ = await sender.submit(method: .interrupt, params: ["threadId": .string(threadID), "turnId": .string(turn)]) }
                        } label: { Image(systemName: "stop.circle") }
                        .accessibilityLabel("中断当前轮次").disabled(sender.busy || !sender.canSubmit(.interrupt))
                    }
                    Button { proxy.scrollTo("conversation-end", anchor: .bottom) } label: { Image(systemName: "arrow.down.to.line") }
                        .accessibilityLabel("查看最新输出")
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: threadID) { await session.selectThread(threadID) }
        .onChange(of: session.snapshot?.thread) { if let thread = $0, thread.id == threadID { title = thread.title } }
    }
}
