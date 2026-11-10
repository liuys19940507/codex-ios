import SwiftUI
import UIKit

struct DiffLine: Equatable {
    enum Kind: Equatable { case context, add, remove, header }
    let text: String
    let kind: Kind
}
enum DiffPresentation {
    static func parse(_ text: String) -> [DiffLine] {
        var start = text.startIndex, lines: [DiffLine] = []
        // Keep original terminators and the missing final newline, including CRLF.
        while start < text.endIndex {
            let end: String.Index
            if let newline = text.unicodeScalars[start...].firstIndex(where: { $0.value == 10 }) { end = text.unicodeScalars.index(after: newline) }
            else { end = text.endIndex }
            let line = String(text[start..<end])
            let kind: DiffLine.Kind
            if line.hasPrefix("diff ") || line.hasPrefix("@@") || line.hasPrefix("--- ") || line.hasPrefix("+++ ") || line.hasPrefix("index ") { kind = .header }
            else if line.hasPrefix("+") { kind = .add }
            else if line.hasPrefix("-") { kind = .remove }
            else { kind = .context }
            lines.append(DiffLine(text: line, kind: kind)); start = end
        }
        return lines
    }
}

struct DiffView: View {
    let text: String
    let path: String
    @State private var expanded = false
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $expanded) {
                HStack {
                    Button("复制差异") { UIPasteboard.general.string = text; copied = true }
                    if copied { Text("已复制").font(.caption) }
                }.buttonStyle(.borderless)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(DiffPresentation.parse(text).enumerated()), id: \.offset) { _, line in
                        Text(visible(line.text)).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(color(line.kind)).padding(.vertical, 2)
                    }
                }
            } label: { Label(path, systemImage: "doc.text").lineLimit(nil) }
        }
    }
    private func visible(_ text: String) -> String {
        if text.hasSuffix("\r\n") { return String(text.unicodeScalars.dropLast(2)) }
        if text.hasSuffix("\n") { return String(text.dropLast()) }
        return text
    }
    private func color(_ kind: DiffLine.Kind) -> Color {
        switch kind { case .add: return .green; case .remove: return .red; case .header: return .secondary; case .context: return .primary }
    }
}
