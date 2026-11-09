import SwiftUI

@main
@MainActor
struct CodexRemoteApp: App {
    @StateObject private var connection = ConnectionModel()
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ConnectionView()
            }
            .environmentObject(connection)
        }
    }
}
