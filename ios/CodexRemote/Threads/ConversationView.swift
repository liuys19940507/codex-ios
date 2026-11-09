import SwiftUI

@MainActor
struct ConversationView: View {
    let threadID: String
    let serverID: UUID
    let drafts: DraftStore
    @EnvironmentObject private var session: SessionStore
    @State private var draft: String
    @State private var draftMessage: String?
    @State private var writable: Bool
    init(threadID: String, serverID: UUID, drafts: DraftStore = DraftStore()) {
        self.threadID = threadID; self.serverID = serverID; self.drafts = drafts
        do {
            _draft = State(initialValue: try drafts.read(serverID: serverID, threadID: threadID))
            _draftMessage = State(initialValue: nil); _writable = State(initialValue: true)
        } catch {
            _draft = State(initialValue: ""); _writable = State(initialValue: false)
            _draftMessage = State(initialValue: "无法读取本地草稿，原文件已保留。")
        }
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
                            VStack(alignment: .leading, spacing: 6) {
                                Label("等待处理", systemImage: "questionmark.circle")
                                Text(request.prompt).textSelection(.enabled)
                            }
                        }
                    } else if session.connectionState == .syncing || session.connectionState == .connecting { ProgressView("正在同步会话…") }
                    if let message = session.message {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(message, systemImage: "exclamationmark.circle")
                            Button("重新同步") { Task { await session.selectThread(threadID) } }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("草稿").font(.headline)
                        TextEditor(text: $draft).frame(minHeight: 120, maxHeight: 220)
                            .padding(4).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityIdentifier("任务草稿").disabled(!writable)
                        Text(draftMessage ?? "草稿保存在本机，尚未提交。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Color.clear.frame(height: 1).id("conversation-end")
                }.padding()
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { proxy.scrollTo("conversation-end", anchor: .bottom) } label: { Image(systemName: "arrow.down.to.line") }
                        .accessibilityLabel("查看最新输出")
                }
            }
        }
        .navigationTitle(session.snapshot?.thread.title ?? "会话")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: threadID) { await session.selectThread(threadID) }
        .onChange(of: draft) { text in
            guard writable else { return }
            do { try drafts.write(text, serverID: serverID, threadID: threadID); draftMessage = nil }
            catch { draftMessage = "草稿未能保存，请复制内容后重试。" }
        }
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
