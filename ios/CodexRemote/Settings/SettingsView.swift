import SwiftUI
import Foundation
import Combine

struct ModelPreference: Codable, Equatable {
    let modelID: String?
    let reasoning: String?
}
struct ModelSettingsStore {
    let url: URL
    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexRemote/models.json")) { self.url = url }
    private func values() throws -> [String: ModelPreference] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: ModelPreference].self, from: Data(contentsOf: url))
    }
    func load(serverID: UUID) throws -> ModelPreference { try values()[serverID.uuidString] ?? ModelPreference(modelID: nil, reasoning: nil) }
    func save(_ preference: ModelPreference, serverID: UUID) throws {
        var all = try values(); all[serverID.uuidString] = preference
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(all).write(to: url, options: .atomic)
    }
}

@MainActor
final class ModelSettings: ObservableObject {
    @Published private(set) var models: [ModelOption] = []
    @Published private(set) var selection: ModelPreference?
    @Published private(set) var message: String?
    @Published private(set) var loading = false
    private var loaded = false
    private let serverID: UUID
    private let transport: any BridgeTransport
    private let store: ModelSettingsStore
    private var generation = UUID()
    init(serverID: UUID, transport: any BridgeTransport, store: ModelSettingsStore = ModelSettingsStore()) {
        self.serverID = serverID; self.transport = transport; self.store = store
        do { selection = try store.load(serverID: serverID) }
        catch { message = "无法读取模型设置，暂不能创建任务。" }
    }
    var canCreate: Bool {
        guard loaded, let selection else { return false }
        return valid(selection)
    }
    func load() async {
        let request = UUID(); generation = request; loading = true
        do {
            let values = try await transport.get("/v1/models", as: [ModelOption].self)
            guard generation == request else { return }
            guard values.allSatisfy({ !$0.id.isEmpty }), Set(values.map(\.id)).count == values.count else { throw ConnectionError.invalidResponse }
            models = values; loaded = true
            if selection == nil { message = "无法读取模型设置，暂不能创建任务。" }
            else if !canCreate { message = "已保存的模型或推理强度当前不可用，请重新选择。" }
            else { message = values.isEmpty ? "Windows 未返回可选模型；仍可明确选择沿用服务端默认配置。" : nil }
        } catch {
            guard generation == request else { return }
            loaded = false; message = "无法读取 Windows 模型列表，请重试。"
        }
        loading = false
    }
    func select(modelID: String?, reasoning: String?) throws {
        let next = ModelPreference(modelID: modelID, reasoning: reasoning)
        guard loaded, valid(next) else { throw ClientCommandError(message: "请选择服务端实际提供的模型和推理强度。") }
        try store.save(next, serverID: serverID)
        selection = next; message = models.isEmpty ? "Windows 未返回可选模型，将沿用服务端默认配置。" : nil
    }
    private func valid(_ preference: ModelPreference) -> Bool {
        guard let id = preference.modelID else { return preference.reasoning == nil }
        guard let model = models.first(where: { $0.id == id }) else { return false }
        return preference.reasoning == nil || model.reasoning.contains(preference.reasoning!)
    }
}

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var settings: ModelSettings
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var lifecycle: LifecycleController
    @State private var failure: String?
    var body: some View {
        Form {
            Section("下一次新建任务") {
                Picker("模型", selection: Binding(get: { settings.selection?.modelID }, set: { choose($0, nil) })) {
                    Text("沿用 Windows 默认配置").tag(nil as String?)
                    ForEach(settings.models) { Text($0.name).tag(Optional($0.id)) }
                }.disabled(settings.loading)
                if let id = settings.selection?.modelID, let model = settings.models.first(where: { $0.id == id }) {
                    Picker("推理强度", selection: Binding(get: { settings.selection?.reasoning }, set: { choose(id, $0) })) {
                        Text("使用模型默认值").tag(nil as String?)
                        ForEach(model.reasoning, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                }
                Text("仅用于之后新建的任务。当前会话继续沿用 Windows 上的配置。").font(.footnote).foregroundStyle(.secondary)
                if let message = settings.message { Text(message).font(.footnote) }
                if let failure { Text(failure).font(.footnote).foregroundStyle(.red) }
                Button("刷新模型列表") { Task { await settings.load() } }.disabled(settings.loading)
                if settings.loading { ProgressView() }
            }
            Section("当前会话权限") {
                LabeledContent("审批策略", value: session.snapshot?.policy.approvalPolicy ?? "未能确认")
                LabeledContent("沙箱", value: session.snapshot?.policy.sandbox ?? "未能确认")
                Text("由 Windows 服务提供，只读显示。").font(.footnote).foregroundStyle(.secondary)
            }
            Section("服务状态") {
                LabeledContent("连接", value: lifecycle.ready ? "已同步" : "尚未同步")
                LabeledContent("Codex 版本", value: lifecycle.info?.codexVersion ?? "未能确认")
                if let message = lifecycle.message { Text(message) }
                Button("重新同步连接") { Task { await lifecycle.setActive(true) } }
            }
        }.navigationTitle("设置").task { await settings.load() }
    }
    private func choose(_ model: String?, _ reasoning: String?) {
        do { try settings.select(modelID: model, reasoning: reasoning); failure = nil }
        catch { failure = error.localizedDescription }
    }
}
