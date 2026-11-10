import SwiftUI

struct ChildThreadView: View {
    let threadID: String
    var body: some View {
        NavigationLink(value: threadID) {
            VStack(alignment: .leading, spacing: 4) {
                Label("打开子任务", systemImage: "arrow.triangle.branch")
                Text(threadID).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}
