import SwiftUI
import UIKit

@MainActor
struct ComposerView: View {
    @ObservedObject var model: ComposerModel
    @EnvironmentObject private var sender: CommandSender
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var lifecycle: LifecycleController
    var snapshot: Snapshot? = nil
    var features: [String: Bool] = [:]
    @State private var mode: InputMode = .steer
    @ScaledMetric(relativeTo: .body) private var editorFontSize: CGFloat = 17
    @State private var editing = false
    @State private var contextID = UUID()
    private var running: Bool { snapshot?.thread.activeTurnId != nil || snapshot?.thread.status == "active" }
    private var chosenMode: InputMode {
        if !running { return .start }
        if features["steer"] != true && features["queue"] == true { return .queue }
        return mode
    }
    private var target: [String: JSONValue] {
        return ["threadId": .string(snapshot?.thread.id ?? "")]
    }
    private var enabled: Bool {
        guard lifecycle.active, lifecycle.ready, model.writable, model.hasContent, !model.importing, !model.uploading,
              !sender.busy, sender.canSubmit(.input), sender.blocked(method: .input, params: target) == nil else { return false }
        guard snapshot != nil else { return false }
        return !running || (chosenMode == .steer ? features["steer"] == true : features["queue"] == true)
    }
    private var editorHeight: CGFloat {
        // Keep typing inside a scrolling editor while allowing a complete
        // line at the user's preferred text size.
        max(56, ceil(UIFont.systemFont(ofSize: editorFontSize).lineHeight + 20))
    }
    var body: some View {
        compactComposer
            .onChange(of: lifecycle.active) { _ in contextID = UUID() }
            .onChange(of: session.selectedThreadID) { _ in contextID = UUID() }
            .onDisappear { contextID = UUID() }
    }
    private var compactComposer: some View {
        VStack(alignment: .leading, spacing: 6) {
            AttachmentStrip(model: model)
            HStack(alignment: .bottom, spacing: 8) {
                AttachmentControls(model: model)
                PasteTextView(text: $model.text, focused: $editing, fontSize: editorFontSize, editable: model.writable) { providers in
                    Task { await AttachmentMediaImport.add(providers, to: model) }
                }
                    .frame(height: editorHeight)
                    .padding(4)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                Button { Task { await send() } } label: {
                    Group { if sender.busy || model.uploading { ProgressView() } else { Image(systemName: "arrow.up").font(.system(size: 18, weight: .semibold)) } }.frame(width: 28, height: 32)
                }.buttonStyle(.borderedProminent).disabled(!enabled)
                    .accessibilityLabel(running ? "追加指令" : "发送指令")
            }
            HStack(alignment: .firstTextBaseline) {
                Text(model.storageMessage ?? (model.importing ? "正在准备附件…" : model.message) ?? (snapshot?.readOnlyReason != nil ? "仅查看 · 草稿仍可编辑" : running ? "追加到当前轮次" : "输入指令或添加附件"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 4)
                Menu {
                    ForEach(["继续完成当前任务", "先说明计划，再执行", "检查改动并运行相关测试"], id: \.self) { phrase in
                        Button(phrase) { model.text += model.text.isEmpty ? phrase : "\n" + phrase }
                    }
                } label: { Image(systemName: "text.badge.plus").font(.system(size: 18)).frame(minWidth: 44, minHeight: 44) }
                    .disabled(!model.writable)
                    .accessibilityLabel("插入常用指令").accessibilityHint("添加到草稿后由你发送")
            }
        }
    }
    private func send() async {
        if let snapshot {
            let submittedContext = contextID
            let result = await model.submitInput(using: sender, snapshot: snapshot, mode: chosenMode, features: features, stillCurrent: {
                contextID == submittedContext && lifecycle.active && lifecycle.ready && session.selectedThreadID == snapshot.thread.id && session.snapshot?.cursor.epoch == snapshot.cursor.epoch
            })
            if result?.state == .accepted && session.snapshot?.thread.id == snapshot.thread.id { await session.selectThread(snapshot.thread.id) }
        }
    }
}

@MainActor
struct NewTaskView: View {
    let projects: [Project]
    let serverID: UUID
    let openThread: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var projectID: String
    init(projects: [Project], serverID: UUID, selectedProjectID: String?, openThread: @escaping (String) -> Void) {
        self.projects = projects; self.serverID = serverID; self.openThread = openThread
        _projectID = State(initialValue: selectedProjectID ?? projects.first?.id ?? "")
    }
    var body: some View {
        Group {
            if let project = projects.first(where: { $0.id == projectID }) {
                NewTaskFormView(serverID: serverID, projects: projects, project: project,
                                selectedProjectID: $projectID, openThread: openThread).id(project.id)
            } else {
                Form {
                    Text("请先在 Windows 配置允许访问的项目，再刷新列表。")
                    Button("取消") { dismiss() }
                }
            }
        }
        .navigationTitle("新任务").navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor
private struct NewTaskFormView: View {
    let projects: [Project]
    let project: Project
    let openThread: (String) -> Void
    @Binding var selectedProjectID: String
    @EnvironmentObject private var sender: CommandSender
    @EnvironmentObject private var settings: ModelSettings
    @EnvironmentObject private var lifecycle: LifecycleController
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ComposerModel
    @State private var submitting = false
    @State private var contextID = UUID()
    @State private var editing = false
    @ScaledMetric(relativeTo: .body) private var editorFontSize: CGFloat = 17
    init(serverID: UUID, projects: [Project], project: Project, selectedProjectID: Binding<String>, openThread: @escaping (String) -> Void) {
        self.projects = projects; self.project = project; self.openThread = openThread
        _selectedProjectID = selectedProjectID
        _model = StateObject(wrappedValue: ComposerModel(serverID: serverID, threadID: "__new__:" + project.id))
    }
    private var enabled: Bool {
        lifecycle.active && lifecycle.ready && settings.canCreate && model.writable &&
        model.hasContent && !model.importing && !model.uploading && !submitting && !sender.busy &&
        sender.canSubmit(.create) && sender.blocked(method: .create, params: ["projectId": .string(project.id)]) == nil
    }
    var body: some View {
        Form {
            Section {
                Picker("项目", selection: $selectedProjectID) {
                    ForEach(projects) { Text("\($0.name) · \($0.path)").tag($0.id) }
                }.disabled(submitting || sender.busy)
                if let id = settings.selection?.modelID {
                    Text("模型：\(id) · \(settings.selection?.reasoning ?? "默认推理强度")").font(.footnote).foregroundStyle(.secondary)
                } else { Text("沿用 Windows 当前默认配置。").font(.footnote).foregroundStyle(.secondary) }
            }
            Section("任务指令") {
                PasteTextView(text: $model.text, focused: $editing, fontSize: editorFontSize, editable: model.writable) { providers in
                    Task { await AttachmentMediaImport.add(providers, to: model) }
                }.frame(height: 160)
                HStack {
                    AttachmentControls(model: model)
                    Text("每个附件最多20MB，一次最多10个").font(.caption).foregroundStyle(.secondary)
                }
                AttachmentStrip(model: model)
                Text(model.storageMessage ?? (model.importing ? "正在准备附件…" : model.message) ?? "草稿保存在本机，尚未提交。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section { OperationStatusView(openThread: openThread) }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(submitting || sender.busy) }
            ToolbarItem(placement: .confirmationAction) {
                Button { submit() } label: {
                    if submitting { ProgressView().accessibilityLabel("正在创建任务") }
                    else { Text("创建并发送") }
                }.disabled(!enabled)
            }
        }
        .interactiveDismissDisabled(submitting || sender.busy)
        .onChange(of: lifecycle.active) { _ in contextID = UUID() }
        .onDisappear { contextID = UUID() }
    }
    private func submit() {
        guard enabled else { return }
        submitting = true
        let draft = model, commandSender = sender, preference = settings.selection
        let selectedProject = project.id, onCreated = openThread, submittedContext = contextID
        Task {
            defer { submitting = false }
            let result = await draft.submitCreate(using: commandSender, projectID: selectedProject,
                                                  model: preference?.modelID, reasoning: preference?.reasoning,
                                                  features: lifecycle.info?.features ?? [:], stillCurrent: {
                contextID == submittedContext && lifecycle.active && lifecycle.ready && selectedProjectID == selectedProject
            })
            if result?.state == .accepted, case .object(let data) = result?.result,
               case .string(let id) = data["threadId"], !id.isEmpty { onCreated(id) }
        }
    }
}
