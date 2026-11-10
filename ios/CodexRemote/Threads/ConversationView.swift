import SwiftUI

@MainActor
struct ConversationView: View {
    let threadID: String
    let serverID: UUID
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var sender: CommandSender
    @EnvironmentObject private var connection: ConnectionModel
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
                            VStack(alignment: .leading, spacing: 8) {
                                Text(title(item)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(item.text.isEmpty ? "暂无文字输出" : item.text).textSelection(.enabled)
                                if case .object(let data) = item.data, data["prefixComplete"] == .bool(false) {
                                    Text(snapshot.thread.activeTurnId == item.turnId ? "部分输出，结束后自动补齐" : "此段输出可能不完整")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).id(item.id)
                        }
                        ForEach(snapshot.pending) { request in
                            ApprovalView(request: request, snapshot: snapshot, features: connection.info?.features ?? [:])
                        }
                    } else if session.connectionState == .syncing || session.connectionState == .connecting { ProgressView("正在同步会话…") }
                    if let message = session.message {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(message, systemImage: "exclamationmark.circle")
                            Button("重新同步") { Task { await session.selectThread(threadID) } }
                        }
                    }
                    ComposerView(model: composer, snapshot: session.snapshot?.thread.id == threadID ? session.snapshot : nil, features: connection.info?.features ?? [:])
                    OperationStatusView()
                    Color.clear.frame(height: 1).id("conversation-end")
                }.padding()
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if connection.info?.features["interrupt"] == true, let current = session.snapshot, current.thread.id == threadID, let turn = current.thread.activeTurnId {
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
    private func title(_ item: Item) -> String {
        switch item.kind {
        case "userMessage": return "你"
        case "agentMessage": return "助手"
        case "plan": return "计划"
        case "diff", "fileChange": return "文件变更"
        case "commandExecution": return "命令执行"
        default: return "工具活动"
        }
    }
}
