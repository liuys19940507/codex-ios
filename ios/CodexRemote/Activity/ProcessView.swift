import SwiftUI

struct ProcessView: View {
    let items: [Item]
    let active: Bool
    var onDraft: ((String) -> Void)? = nil
    var onInteraction: (() -> Void)? = nil
    @State private var expanded = false
    private var commands: Int { items.filter { $0.kind == "commandExecution" }.count }
    private var files: Int { items.filter { $0.kind == "fileChange" || $0.kind == "diff" }.count }
    private var failed: Int { items.filter { $0.data.objectValue["status"]?.stringValue == "failed" }.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { onInteraction?(); expanded.toggle() } label: {
                HStack(spacing: 10) {
                    if active { ProgressView() } else { Image(systemName: "list.bullet.rectangle") }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(active ? "正在处理" : "查看处理过程").font(.callout.weight(.medium))
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption).accessibilityHidden(true)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel(expanded ? "收起处理过程" : "查看处理过程")
            .accessibilityIdentifier("查看处理过程").accessibilityValue(expanded ? "已展开" : "已收起")
            if expanded {
                // Stable row heights prevent lazy placement from cycling while
                // scrolling large text above the fixed composer.
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(items) { item in ActivityView(item: item, partial: active, onDraft: onDraft) }
                }
            }
        }
        .padding(12).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
    private var summary: String {
        var parts = ["\(items.count) 项活动"]
        if commands > 0 { parts.append("命令 \(commands)") }
        if files > 0 { parts.append("文件变更 \(files)") }
        if failed > 0 { parts.append("失败 \(failed)") }
        return parts.joined(separator: " · ")
    }
}
