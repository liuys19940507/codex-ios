import SwiftUI
import UIKit

struct ActivityPresentation {
    let title: String
    let body: String
    let status: String?
    let kind: String
    let childThreadIDs: [String]
    static func make(item: Item) -> ActivityPresentation {
        let titles = ["userMessage": "你", "agentMessage": "助手", "plan": "计划", "reasoning": "推理摘要", "commandExecution": "命令执行", "fileChange": "文件变更", "diff": "累计差异", "collabAgentToolCall": "子任务活动", "mcpToolCall": "MCP 工具", "dynamicToolCall": "工具调用"]
        let data = item.data.objectValue
        var ids: [String] = []
        if case .array(let values) = data["childThreadIds"] {
            for value in values { if let id = value.stringValue, !id.isEmpty, !ids.contains(id) { ids.append(id) } }
        }
        var body = item.text
        if body.isEmpty && !["fileChange", "collabAgentToolCall"].contains(item.kind) { body = item.data.formatted }
        return ActivityPresentation(title: titles[item.kind] ?? "工具活动：\(item.kind)", body: body, status: data["status"]?.stringValue, kind: item.kind, childThreadIDs: ids)
    }
    static func chunks(_ text: String, limit: Int = 2048) -> [String] {
        guard !text.isEmpty else { return [] }
        var start = text.startIndex, result: [String] = []
        while start < text.endIndex {
            let end = text.index(start, offsetBy: max(1, limit), limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[start..<end])); start = end
        }
        return result
    }
}

@MainActor
struct ActivityView: View {
    let item: Item
    let partial: Bool
    @State private var expanded = false
    @State private var copied = false
    private var presentation: ActivityPresentation { ActivityPresentation.make(item: item) }
    private var isMessage: Bool { ["userMessage", "agentMessage", "plan", "reasoning"].contains(item.kind) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(presentation.title).font(.caption.weight(.semibold))
                if let status = presentation.status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            if let command = item.data.objectValue["command"]?.stringValue { Text(command).font(.callout.monospaced()).textSelection(.enabled) }
            if item.kind == "fileChange", case .array(let changes) = item.data.objectValue["changes"] {
                ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                    DiffView(text: change.objectValue["diff"]?.stringValue ?? change.formatted, path: change.objectValue["path"]?.stringValue ?? "文件变更")
                }
            } else if item.kind == "diff" {
                DiffView(text: presentation.body, path: "本轮累计差异")
            } else if !presentation.body.isEmpty {
                if !isMessage || presentation.body.count > 4096 {
                    HStack {
                        Button(expanded ? "收起输出" : "展开输出") { expanded.toggle() }
                        Button("复制全部输出") { UIPasteboard.general.string = presentation.body; copied = true }
                    }.buttonStyle(.borderless)
                    if copied { Text("已复制").font(.caption).foregroundStyle(.secondary) }
                    if expanded { output }
                    else if isMessage { Text(String(presentation.body.prefix(2048))).textSelection(.enabled) }
                } else { output }
            }
            if case .number(let code) = item.data.objectValue["exitCode"] { Text("退出码 \(Int(code))").font(.caption).foregroundStyle(.secondary) }
            if item.data.objectValue["prefixComplete"] == .bool(false) {
                Text(partial ? "部分输出，结束后自动补齐" : "此段输出可能不完整").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(presentation.childThreadIDs, id: \.self) { ChildThreadView(threadID: $0) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var output: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(ActivityPresentation.chunks(presentation.body).enumerated()), id: \.offset) { _, text in
                Text(text).font(isMessage ? .body : .callout.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
