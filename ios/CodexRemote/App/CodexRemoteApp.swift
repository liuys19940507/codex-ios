import SwiftUI

@main
@MainActor
struct CodexRemoteApp: App {
    @StateObject private var connection: ConnectionModel
    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-workspace") {
            _connection = StateObject(wrappedValue: ConnectionModel.uiTestWorkspace())
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-test-saved-connection") {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("CodexRemoteUITest/servers.json")
            let store = ServerStore(url: url)
            if let server = try? ServerConfiguration(name: "Fixture Windows", address: "https://fixture.example") { try? store.save([server]) }
            _connection = StateObject(wrappedValue: ConnectionModel(servers: store))
            return
        }
        #endif
        _connection = StateObject(wrappedValue: ConnectionModel())
    }
    var body: some Scene {
        WindowGroup {
            AppRootView()
            .environmentObject(connection)
            .preferredColorScheme(testColorScheme)
        }
    }
    private var testColorScheme: ColorScheme? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-test-rendering") { return arguments.contains("--ui-test-dark") ? .dark : .light }
        #endif
        return nil
    }
}
