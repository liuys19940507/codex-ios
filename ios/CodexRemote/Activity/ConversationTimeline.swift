import Foundation

struct ConversationRow: Equatable, Identifiable {
    enum Kind: Equatable { case message, process }
    let id: String
    let kind: Kind
    let turnID: String
    let items: [Item]
}

enum ConversationTimeline {
    static func make(_ source: [Item]) -> [ConversationRow] {
        var seen = Set<String>(), turns: [String] = [], groups: [String: [Item]] = [:]
        for item in source where seen.insert(item.turnId + ":" + item.id).inserted {
            if groups[item.turnId] == nil { turns.append(item.turnId) }
            groups[item.turnId, default: []].append(item)
        }
        var result: [ConversationRow] = []
        func isMessage(_ item: Item) -> Bool {
            item.kind == "userMessage" || item.kind == "agentMessage" && item.data.objectValue["phase"]?.stringValue != "commentary"
        }
        for turn in turns {
            let items = groups[turn] ?? []
            let process = items.filter { !isMessage($0) && !($0.kind == "reasoning" && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            var inserted = false
            for item in items {
                if item.kind != "userMessage", !inserted, !process.isEmpty {
                    result.append(ConversationRow(id: "process:\(turn)", kind: .process, turnID: turn, items: process)); inserted = true
                }
                if isMessage(item), !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(ConversationRow(id: "message:\(turn):\(item.id)", kind: .message, turnID: turn, items: [item]))
                }
            }
        }
        return result
    }
}
