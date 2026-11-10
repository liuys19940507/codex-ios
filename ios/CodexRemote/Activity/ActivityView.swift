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
        let known = ["userMessage", "agentMessage", "plan", "reasoning", "commandExecution", "fileChange", "diff", "collabAgentToolCall", "mcpToolCall", "dynamicToolCall"]
        if body.isEmpty && !known.contains(item.kind) { body = item.data.formatted }
        if item.kind == "mcpToolCall", body.isEmpty { body = [data["result"], data["error"]].compactMap { $0 == .null ? nil : $0?.formatted }.joined(separator: "\n") }
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
    var onDraft: ((String) -> Void)? = nil
    var onContentReady: (() -> Void)? = nil
    @State private var copied = false
    private var presentation: ActivityPresentation { ActivityPresentation.make(item: item) }
    var body: some View {
        Group {
            if item.kind == "userMessage" {
                HStack {
                    Spacer(minLength: 36)
                    Text(item.text).textSelection(.enabled).padding(12)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                }
            } else { content }
        }
        .contextMenu {
            Button("复制消息") { UIPasteboard.general.string = item.text.isEmpty ? presentation.body : item.text }
            if !item.text.isEmpty, let onDraft { Button("追加到草稿") { onDraft(item.text) } }
        }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if item.kind != "agentMessage" {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.kind == "reasoning" ? ReasoningSummary.make(item.text).title : presentation.title).font(.caption.weight(.semibold))
                    if let status = presentation.status { Text(Self.status(status)).font(.caption).foregroundStyle(status == "failed" ? .red : .secondary) }
                }
            }
            if let command = item.data.objectValue["command"]?.stringValue { Text(command).font(.callout.monospaced()).textSelection(.enabled) }
            if item.kind == "fileChange", case .array(let changes) = item.data.objectValue["changes"] {
                ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                    DiffView(text: change.objectValue["diff"]?.stringValue ?? change.formatted, path: change.objectValue["path"]?.stringValue ?? "文件变更")
                }
            } else if item.kind == "diff" {
                DiffView(text: presentation.body, path: "本轮累计差异")
            } else if item.kind == "commandExecution" {
                CodeOutputView(text: item.text, title: "命令输出", tail: true)
            } else if item.kind == "plan", case .array(let steps) = item.data.objectValue["steps"], !steps.isEmpty {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    let data = step.objectValue
                    Label(data["step"]?.stringValue ?? "步骤", systemImage: data["status"]?.stringValue == "completed" ? "checkmark.circle.fill" : data["status"]?.stringValue == "inProgress" ? "circle.dotted" : "circle")
                        .font(.callout)
                }
            } else if !presentation.body.isEmpty {
                if ["agentMessage", "reasoning", "plan"].contains(item.kind) {
                    RichMessageView(text: item.kind == "reasoning" ? ReasoningSummary.make(item.text).body : presentation.body, onRendered: onContentReady)
                } else { CodeOutputView(text: presentation.body, title: presentation.title) }
            }
            if case .number(let code) = item.data.objectValue["exitCode"] { Text("退出码 \(Int(code))").font(.caption).foregroundStyle(.secondary) }
            if case .number(let duration) = item.data.objectValue["durationMs"] { Text(String(format: "耗时 %.1f 秒", duration / 1000)).font(.caption).foregroundStyle(.secondary) }
            if item.data.objectValue["prefixComplete"] == .bool(false) {
                Text(partial ? "部分输出，结束后自动补齐" : "此段输出可能不完整").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(presentation.childThreadIDs, id: \.self) { ChildThreadView(threadID: $0) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    static func status(_ value: String) -> String {
        ["completed": "已完成", "inProgress": "执行中", "failed": "失败", "declined": "已拒绝", "interrupted": "已中断", "unknown": "状态未知"][value] ?? value
    }
}
