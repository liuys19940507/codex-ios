import SwiftUI

@MainActor
struct ApprovalView: View {
    let request: Pending
    let snapshot: Snapshot
    let features: [String: Bool]
    @EnvironmentObject private var sender: CommandSender
    @EnvironmentObject private var session: SessionStore
    private var options: [String: JSONValue] { request.options.objectValue }
    private var enabled: Bool {
        request.state == .pending && request.threadId == snapshot.thread.id && request.turnId == snapshot.thread.activeTurnId &&
        !sender.busy && sender.canSubmit(.respond) && options["readOnly"] != .bool(true) &&
        sender.blocked(method: .respond, params: ["requestId": .string(request.id)]) == nil
    }
    private var edits: [JSONValue] {
        guard let id = options["itemId"]?.stringValue,
              let item = snapshot.items.first(where: { $0.id == id && $0.turnId == request.turnId }),
              case .array(let changes) = item.data.objectValue["changes"] else { return [] }
        return changes
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: "hand.raised").font(.headline)
            Text(request.prompt).textSelection(.enabled)
            if request.state != .pending { Text("此请求已处理或已过期。").foregroundStyle(.secondary) }
            switch request.kind {
            case .command:
                if features["approvals"] == true, case .array(let decisions) = options["availableDecisions"], !decisions.isEmpty {
                    ForEach(Array(decisions.enumerated()), id: \.offset) { _, decision in
                        if let title = decisionTitle(decision) {
                            if case .object = decision { DisclosureGroup("查看规则变更") { Text(decision.formatted).font(.caption.monospaced()).textSelection(.enabled) } }
                            Button(title) { respond(.object(["decision": decision])) }.buttonStyle(.bordered).disabled(!enabled)
                        } else { fallback }
                    }
                } else { fallback }
            case .file:
                if features["fileApprovals"] == true {
                    ForEach(Array(edits.enumerated()), id: \.offset) { _, edit in
                        DisclosureGroup(edit.objectValue["path"]?.stringValue ?? "文件变更") {
                            Text(edit.objectValue["diff"]?.stringValue ?? edit.formatted).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    if edits.isEmpty { Text("尚未取得对应文件变更，请重新同步或在 Windows 查看。").font(.footnote) }
                    Button("允许本次文件变更") { respond(.object(["decision": .string("accept")])) }.disabled(!enabled || edits.isEmpty)
                    Button("拒绝文件变更", role: .destructive) { respond(.object(["decision": .string("decline")])) }.disabled(!enabled)
                    Button("取消请求") { respond(.object(["decision": .string("cancel")])) }.disabled(!enabled)
                } else { fallback }
            case .question:
                if features["questions"] == true, let fields = QuestionField.parse(request.options) {
                    QuestionView(fields: fields, enabled: enabled, submit: respond).id(request.id)
                } else { fallback }
            case .permission:
                if features["permissions"] == true {
                    PermissionRequestView(options: options, enabled: enabled, submit: respond)
                } else { fallback }
            case .mcp:
                if features["mcp"] == true, options["mode"] == .string("form") {
                    MCPRequestView(schema: options["requestedSchema"] ?? .null, enabled: enabled, submit: respond)
                } else { fallback }
            }
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
    private var fallback: some View {
        VStack(alignment: .leading) {
            Text("请在 Windows CLI 中处理此请求。").font(.footnote).foregroundStyle(.secondary)
            DisclosureGroup("查看请求详情") { Text(request.options.formatted).font(.caption.monospaced()).textSelection(.enabled) }
        }
    }
    private var title: String {
        switch request.kind {
        case .command: return "命令审批"
        case .file: return "文件审批"
        case .permission: return "权限请求"
        case .question: return "需要回答"
        case .mcp: return "工具确认"
        }
    }
    private func decisionTitle(_ decision: JSONValue) -> String? {
        if case .string(let value) = decision {
            switch value {
            case "accept": return "允许执行一次"
            case "acceptForSession": return "允许此会话执行"
            case "decline": return "拒绝执行"
            case "cancel": return "取消请求"
            default: return nil
            }
        }
        let object = decision.objectValue
        if object.count == 1 && object["acceptWithExecpolicyAmendment"] != nil { return "允许并更新执行规则" }
        if object.count == 1 && object["applyNetworkPolicyAmendment"] != nil { return "应用所示网络规则" }
        return nil
    }
    private func respond(_ response: JSONValue) {
        Task {
            guard let current = session.snapshot, let latest = current.pending.first(where: { $0.id == request.id }), latest == request else {
                if session.snapshot?.thread.id == request.threadId { await session.selectThread(request.threadId) }
                return
            }
            let result = await sender.respond(request: latest, snapshot: current, response: response, features: features)
            if result.state == .accepted && session.snapshot?.thread.id == request.threadId { await session.selectThread(request.threadId) }
        }
    }
}

@MainActor
private struct PermissionRequestView: View {
    let options: [String: JSONValue]
    let enabled: Bool
    let submit: (JSONValue) -> Void
    @State private var allow = false
    private var requested: JSONValue { options["permissions"] ?? .null }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(requested.formatted).font(.caption.monospaced()).textSelection(.enabled)
            Text("仅授予以上请求的权限，有效期为当前轮次。").font(.footnote)
            Toggle("允许以上请求的权限", isOn: $allow)
            Button("提交权限选择") {
                submit(.object(["scope": .string("turn"), "permissions": allow ? requested : .object([:])]))
            }.disabled(!enabled || requested.objectValue.isEmpty)
        }.disabled(!enabled)
    }
}
