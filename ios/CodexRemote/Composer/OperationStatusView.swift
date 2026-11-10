import SwiftUI

@MainActor
struct OperationStatusView: View {
    @EnvironmentObject private var sender: CommandSender
    var openThread: ((String) -> Void)? = nil
    @State private var reviewID: String?
    @State private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let operation = sender.lastOperation {
                Label(status(operation.state), systemImage: operation.state == .accepted ? "checkmark.circle" : "info.circle")
                    .font(.footnote)
            }
            if let message = sender.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            ForEach(sender.unresolved) { record in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(title(record.method))：\(status(record.receipt.state))").font(.subheadline.weight(.semibold))
                    if case .object(let result) = record.receipt.result, case .string(let id) = result["threadId"] {
                        if let openThread { Button("打开已创建的会话") { openThread(id) } }
                        else { NavigationLink("打开已创建的会话", value: id) }
                    }
                    Button("核对结果") { Task { _ = await sender.reconcile(id: record.id) } }
                        .disabled(sender.checkingIDs.contains(record.id) || sender.busy)
                    if record.receipt.state == .unknown {
                        Button("我已查看任务结果") { reviewID = record.id }.disabled(sender.busy)
                    }
                }
            }
        }
        .buttonStyle(.borderless)
        .confirmationDialog("已核对任务结果？", isPresented: Binding(get: { reviewID != nil }, set: { if !$0 { reviewID = nil } })) {
            Button("确认已核对") {
                if let id = reviewID {
                    do { try sender.acknowledgeReviewed(id: id) } catch { failure = error.localizedDescription }
                }
                reviewID = nil
            }
            Button("取消", role: .cancel) { reviewID = nil }
        } message: {
            Text("确认后可再次发送，但不会自动重发。上一条如果已经执行，再次发送可能产生重复结果。")
        }
        .alert("无法保存核对状态", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好") { failure = nil }
        } message: { Text(failure ?? "") }
    }
    private func status(_ state: Operation.State) -> String {
        switch state {
        case .pending: return "正在提交"
        case .accepted: return "操作已确认"
        case .failed: return "本次操作未被接受"
        case .unknown: return "结果尚未确认"
        }
    }
    private func title(_ method: Command.Method) -> String {
        switch method {
        case .create: return "创建任务"
        case .input: return "发送指令"
        case .interrupt: return "中断轮次"
        case .respond: return "处理请求"
        case .rename: return "重命名"
        case .archive: return "归档"
        case .attach: return "连接会话"
        case .release: return "释放会话"
        }
    }
}
