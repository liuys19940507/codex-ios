import SwiftUI

struct ServerEditorView: View {
    @EnvironmentObject private var connection: ConnectionModel
    @Environment(\.dismiss) private var dismiss
    let server: ServerConfiguration?
    @State private var name: String
    @State private var address: String
    @State private var token = ""
    @State private var saving = false
    @State private var failure: String?

    init(server: ServerConfiguration? = nil) {
        self.server = server
        _name = State(initialValue: server?.name ?? "Windows")
        _address = State(initialValue: server?.baseURL.absoluteString ?? "http://10.147.21.2:8391")
    }

    var body: some View {
        Form {
            Section("Windows 服务") {
                TextField("连接名称", text: $name)
                TextField("服务地址", text: $address, prompt: Text("http://10.147.21.2:8391"))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("服务地址")
                SecureField("配对令牌", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("配对令牌")
            }
            Section {
                Text("手机与电脑需连接同一个 EasyTier 网络。服务地址和配对令牌由 Windows 桥接服务提供。")
                if server != nil { Text("令牌留空可保留原值；修改服务地址时需要重新填写令牌。") }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            Section {
                Button {
                    saving = true
                    Task { @MainActor in
                        do {
                            try await connection.save(name: name, address: address, token: token, editingID: server?.id)
                            token = ""
                            dismiss()
                        } catch { failure = error.localizedDescription }
                        saving = false
                    }
                } label: {
                    HStack {
                        Text("保存并连接")
                        if saving { Spacer(); ProgressView() }
                    }
                }
                .disabled(saving || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (server == nil && token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .disabled(saving)
        .navigationTitle(server == nil ? "添加连接" : "编辑连接")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) } }
        .interactiveDismissDisabled(saving)
        .alert("无法保存连接", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好") { failure = nil }
        } message: { Text(failure ?? "") }
    }
}

struct ConnectionView: View {
    @EnvironmentObject private var connection: ConnectionModel
    @State private var adding = false
    @State private var editing: ServerConfiguration?

    var body: some View {
        List {
            if connection.servers.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("连接 Windows 上的 Codex", systemImage: "terminal")
                            .font(.headline)
                        Text("添加服务地址和配对令牌，查看与继续电脑上的任务。")
                            .foregroundStyle(.secondary)
                        Button("添加连接") { adding = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 12)
                }
            } else {
                Section("已保存的连接") {
                    ForEach(connection.servers) { server in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(server.name).font(.headline)
                                    Text(server.baseURL.absoluteString).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                Spacer()
                                Button { editing = server } label: { Image(systemName: "pencil") }
                                    .accessibilityLabel("编辑 \(server.name)")
                            }
                            Button {
                                Task { await connection.connect(serverID: server.id) }
                            } label: {
                                if connection.activeServerID == server.id && connection.status == .connecting {
                                    HStack { ProgressView(); Text("正在连接…") }
                                } else {
                                    Text(connection.activeServerID == server.id && connection.status == .connected ? "重新连接" : "连接")
                                }
                            }
                            .disabled(connection.status == .connecting)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            if let info = connection.info {
                Section("连接状态") {
                    Label("已连接", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    LabeledContent("Codex 版本", value: info.codexVersion)
                }
            }
            if let message = connection.message {
                Section("连接状态") { Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Codex Remote")
        .toolbar {
            if !connection.servers.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label("添加连接", systemImage: "plus") }
                }
            }
        }
        .sheet(isPresented: $adding) { NavigationStack { ServerEditorView() }.environmentObject(connection) }
        .sheet(item: $editing) { server in NavigationStack { ServerEditorView(server: server) }.environmentObject(connection) }
    }
}
