import SwiftUI
import UIKit

@main
@MainActor
struct CodexRemoteApp: App {
    @StateObject private var connection: ConnectionModel
    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-workspace") {
            Self.prepareTestClipboard()
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
    #if DEBUG
    private static func prepareTestClipboard() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-test-paste-text") { UIPasteboard.general.string = "native clipboard 中文😀" }
        if arguments.contains("--ui-test-paste-image") {
            UIPasteboard.general.image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
                UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            }
        }
        if arguments.contains("--ui-test-paste-file") {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-中文.txt")
            try? Data("FILE_PASTE_FIXTURE_中文😀".utf8).write(to: file, options: .atomic)
            UIPasteboard.general.urls = [file]
        }
    }
    #endif
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
