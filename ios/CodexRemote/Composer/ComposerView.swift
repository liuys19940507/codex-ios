import SwiftUI

@MainActor
struct ComposerView: View {
    @ObservedObject var model: ComposerModel
    @EnvironmentObject private var sender: CommandSender
    @EnvironmentObject private var session: SessionStore
    var snapshot: Snapshot? = nil
    var features: [String: Bool] = [:]
    var projectID: String? = nil
    var onCreated: ((String) -> Void)? = nil
    @State private var mode: InputMode = .steer
    private var running: Bool { snapshot?.thread.activeTurnId != nil || snapshot?.thread.status == "active" }
    private var chosenMode: InputMode {
        if !running { return .start }
        if features["steer"] != true && features["queue"] == true { return .queue }
        return mode
    }
    private var method: Command.Method { projectID == nil ? .input : .create }
    private var target: [String: JSONValue] {
        if let projectID { return ["projectId": .string(projectID)] }
        return ["threadId": .string(snapshot?.thread.id ?? "")]
    }
    private var enabled: Bool {
        guard model.writable, !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sender.busy, sender.canSubmit(method), sender.blocked(method: method, params: target) == nil else { return false }
        if projectID != nil { return true }
        guard snapshot != nil else { return false }
        return !running || (chosenMode == .steer ? features["steer"] == true : features["queue"] == true)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(projectID == nil ? "指令草稿" : "任务指令").font(.headline)
            TextEditor(text: $model.text).frame(minHeight: 120, maxHeight: 220)
                .padding(4).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("任务草稿").disabled(!model.writable)
            if projectID == nil && running {
                if features["steer"] == true && features["queue"] == true {
                    Picker("发送方式", selection: $mode) {
                        Text("追加到当前轮次").tag(InputMode.steer)
                        Text("排队").tag(InputMode.queue)
                    }
                } else if features["steer"] == true { Text("发送后追加到当前轮次。").font(.footnote).foregroundStyle(.secondary) }
                if features["queue"] != true { Text("未发送的内容保留为草稿，不会自动排队。").font(.footnote).foregroundStyle(.secondary) }
            }
            Button {
                Task {
                    if let projectID {
                        let result = await model.submitCreate(using: sender, projectID: projectID)
                        if result?.state == .accepted, case .object(let data) = result?.result,
                           case .string(let id) = data["threadId"] { onCreated?(id) }
                    } else if let snapshot {
                        let result = await model.submitInput(using: sender, snapshot: snapshot, mode: chosenMode, features: features)
                        if result?.state == .accepted && session.snapshot?.thread.id == snapshot.thread.id {
                            await session.selectThread(snapshot.thread.id)
                        }
                    }
                }
            } label: {
                HStack {
                    Text(projectID != nil ? "创建并发送" : running ? (chosenMode == .queue ? "加入队列" : "追加指令") : "发送指令")
                    if sender.busy { Spacer(); ProgressView() }
                }.frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent).disabled(!enabled)
            Text(model.storageMessage ?? model.message ?? "草稿保存在本机，尚未提交。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

@MainActor
struct NewTaskView: View {
    let projects: [Project]
    let serverID: UUID
    let openThread: (String) -> Void
    @EnvironmentObject private var sender: CommandSender
    @Environment(\.dismiss) private var dismiss
    @State private var projectID: String
    init(projects: [Project], serverID: UUID, selectedProjectID: String?, openThread: @escaping (String) -> Void) {
        self.projects = projects; self.serverID = serverID; self.openThread = openThread
        _projectID = State(initialValue: selectedProjectID ?? projects.first?.id ?? "")
    }
    var body: some View {
        Form {
            Section {
                Picker("项目", selection: $projectID) { ForEach(projects) { Text($0.name).tag($0.id) } }
                Text("使用 Windows 当前配置的默认模型。").font(.footnote).foregroundStyle(.secondary)
            }
            if let project = projects.first(where: { $0.id == projectID }) {
                Section { NewTaskDraftView(serverID: serverID, project: project, openThread: openThread).id(project.id) }
            } else { Text("请先在 Windows 配置允许访问的项目，再刷新列表。") }
            Section { OperationStatusView(openThread: openThread) }
        }
        .navigationTitle("新任务").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(sender.busy) } }
        .interactiveDismissDisabled(sender.busy)
    }
}

@MainActor
private struct NewTaskDraftView: View {
    let project: Project
    let openThread: (String) -> Void
    @StateObject private var model: ComposerModel
    init(serverID: UUID, project: Project, openThread: @escaping (String) -> Void) {
        self.project = project; self.openThread = openThread
        _model = StateObject(wrappedValue: ComposerModel(serverID: serverID, threadID: "__new__:" + project.id))
    }
    var body: some View { ComposerView(model: model, projectID: project.id, onCreated: openThread) }
}
