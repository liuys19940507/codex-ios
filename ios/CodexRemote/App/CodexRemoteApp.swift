import SwiftUI

@main
struct CodexRemoteApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                VStack(spacing: 16) {
                    Image(systemName: "terminal")
                        .font(.largeTitle)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("连接尚未配置")
                        .font(.title2.weight(.semibold))
                    Text("连接 Windows 上的 Codex 服务后，即可查看和继续任务。")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Codex Remote")
            }
        }
    }
}
