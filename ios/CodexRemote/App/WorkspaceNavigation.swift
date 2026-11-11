import SwiftUI
import Combine

enum WorkspaceDestination: Hashable, Sendable { case tasks, connections, settings }

@MainActor
final class WorkspaceNavigator: ObservableObject {
    @Published var path = NavigationPath()
    private let session: SessionStore
    init(session: SessionStore) { self.session = session }
    func show(_ destination: WorkspaceDestination) async {
        let thread = session.selectedThreadID, attachment = session.attachmentID
        path = destination == .tasks ? NavigationPath() : NavigationPath([destination])
        if let thread { await session.leaveThread(thread, attachmentID: attachment) }
    }
}

private struct WorkspaceNavigationKey: EnvironmentKey {
    static let defaultValue: (@MainActor (WorkspaceDestination) -> Void)? = nil
}
extension EnvironmentValues {
    var workspaceNavigation: (@MainActor (WorkspaceDestination) -> Void)? {
        get { self[WorkspaceNavigationKey.self] }
        set { self[WorkspaceNavigationKey.self] = newValue }
    }
}

@MainActor
private struct WorkspaceMenuModifier: ViewModifier {
    @Environment(\.workspaceNavigation) private var navigate
    func body(content: Content) -> some View {
        content.toolbar {
            if let navigate {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { navigate(.tasks) } label: { Label("任务", systemImage: "list.bullet.rectangle") }
                            .accessibilityIdentifier("workspace.tasks")
                        Button { navigate(.connections) } label: { Label("连接", systemImage: "network") }
                            .accessibilityIdentifier("workspace.connections")
                        Button { navigate(.settings) } label: { Label("设置", systemImage: "gearshape") }
                            .accessibilityIdentifier("workspace.settings")
                    } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("更多")
                }
            }
        }
    }
}
extension View {
    @MainActor func workspaceNavigationMenu() -> some View { modifier(WorkspaceMenuModifier()) }
}
