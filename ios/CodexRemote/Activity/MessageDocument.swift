import Foundation

enum RawText {
    static func lines(_ text: String) -> [String] {
        var start = text.startIndex, result: [String] = []
        while start < text.endIndex {
            let end: String.Index
            if let newline = text.unicodeScalars[start...].firstIndex(where: { $0.value == 10 }) { end = text.unicodeScalars.index(after: newline) }
            else { end = text.endIndex }
            result.append(String(text[start..<end])); start = end
        }
        return result
    }
    static func visibleLine(_ text: String) -> String {
        if text.hasSuffix("\r\n") { return String(text.unicodeScalars.dropLast(2)) }
        if text.hasSuffix("\n") { return String(text.dropLast()) }
        return text
    }
}

struct MessageBlock: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable { case markdown, code }
    let id: Int
    let kind: Kind
    let raw: String
    let content: String
    let language: String?
    let complete: Bool
}

enum MessageDocument {
    static func parse(_ text: String) -> [MessageBlock] {
        var blocks: [MessageBlock] = [], prose = "", raw = "", code = ""
        var fence: Character?, width = 0, language: String?
        func append(_ kind: MessageBlock.Kind, _ raw: String, _ content: String, complete: Bool = true) {
            guard !raw.isEmpty else { return }
            blocks.append(MessageBlock(id: blocks.count, kind: kind, raw: raw, content: content, language: kind == .code ? language : nil, complete: complete))
        }
        for line in RawText.lines(text) {
            let body = RawText.visibleLine(line), indent = body.prefix(while: { $0 == " " }).count
            let trimmed = body.dropFirst(indent)
            if let marker = fence {
                let closingWidth = trimmed.prefix(while: { $0 == marker }).count
                if indent <= 3, closingWidth >= width, trimmed.dropFirst(closingWidth).trimmingCharacters(in: .whitespaces).isEmpty {
                    raw += line; append(.code, raw, code); fence = nil; raw = ""; code = ""
                } else { raw += line; code += line }
            } else if indent <= 3, let marker = trimmed.first, marker == "`" || marker == "~" {
                let count = trimmed.prefix(while: { $0 == marker }).count
                let info = String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces)
                if count >= 3, marker != "`" || !info.contains("`") {
                    append(.markdown, prose, prose); prose = ""
                    fence = marker; width = count; language = info.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
                    raw = line; code = ""
                } else { prose += line }
            } else { prose += line }
        }
        if fence != nil { append(.code, raw, code, complete: false) }
        append(.markdown, prose, prose)
        return blocks
    }
}

struct ReasoningSummary: Equatable {
    let title: String
    let body: String
    static func make(_ text: String) -> ReasoningSummary {
        let clean = text.replacingOccurrences(of: "<!-- -->", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = RawText.lines(clean)
        if let first = lines.first {
            let title = RawText.visibleLine(first).trimmingCharacters(in: .whitespaces)
            if title.hasPrefix("**"), title.hasSuffix("**"), title.count > 4 {
                return ReasoningSummary(title: String(title.dropFirst(2).dropLast(2)), body: lines.dropFirst().joined().trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return ReasoningSummary(title: "推理摘要", body: clean)
    }
}
