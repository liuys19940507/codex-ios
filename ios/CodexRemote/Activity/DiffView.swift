import SwiftUI
import UIKit

struct DiffLine: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case context, add, remove, header }
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
    @State private var document = DiffDocument(files: [])
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(document.files.enumerated()), id: \.offset) { _, file in FileDiffView(file: file) }
            if document.files.isEmpty { Text(path).font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: text) {
            let source = text, fallback = path
            let parsed = await Task.detached(priority: .userInitiated) { DiffDocument.parse(source, path: fallback) }.value
            guard !Task.isCancelled else { return }; document = parsed
        }
    }
}

private struct FileDiffView: View {
    let file: DiffFile
    @State private var expanded = false
    @State private var copied = false
    @State private var showingAll = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $expanded) {
                HStack {
                    Button("复制差异") { UIPasteboard.general.string = file.raw; copied = true }
                    Button("查看完整差异") { showingAll = true }
                    if copied { Text("已复制").font(.caption) }
                }.buttonStyle(.borderless).font(.caption)
                if file.binary { Text("二进制文件变更").font(.caption).foregroundStyle(.secondary) }
                ScrollView(.horizontal) { PatchLines(lines: Array(file.lines.prefix(80))) }
                if file.lines.count > 80 { Text("差异较长，可打开完整视图阅读。").font(.caption).foregroundStyle(.secondary) }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Label(file.path, systemImage: "doc.text").lineLimit(nil)
                    HStack(spacing: 12) {
                        Text("+\(file.added)").foregroundStyle(.green)
                        Text("−\(file.removed)").foregroundStyle(.red)
                        if file.partial { Text("差异片段不完整").foregroundStyle(.secondary) }
                    }.font(.caption.monospaced())
                }
            }
        }
        .sheet(isPresented: $showingAll) {
            NavigationStack {
                ScrollView([.horizontal, .vertical]) { PatchLines(lines: file.lines).padding() }
                    .navigationTitle(file.path).navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("完成") { showingAll = false } }
                        ToolbarItem(placement: .primaryAction) { Button("复制差异") { UIPasteboard.general.string = file.raw } }
                    }
            }
        }
    }
}

private struct PatchLines: View {
    let lines: [DiffLine]
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(RawText.visibleLine(line.text)).font(.caption.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(color(line.kind)).padding(.vertical, 2)
                    .background(color(line.kind).opacity(line.kind == .add || line.kind == .remove ? 0.08 : 0))
            }
        }
    }
    private func color(_ kind: DiffLine.Kind) -> Color {
        switch kind { case .add: return .green; case .remove: return .red; case .header: return .secondary; case .context: return .primary }
    }
}
