import SwiftUI

struct NativeMarkdownTableView: View {
    let html: String
    let fallback: String
    var body: some View {
        if let table = MarkdownTableDocument.parse(html: html) {
            ScrollView(.horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                        GridRow(alignment: .top) {
                            ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                                cellView(cell, header: row.isHeader, row: index)
                            }
                        }
                    }
                }.fixedSize(horizontal: true, vertical: true)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("表格文本").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    Text(fallback).font(.body.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                }
            }
        }
    }
    private func cellView(_ cell: MarkdownTableDocument.Cell, header: Bool, row: Int) -> some View {
        label(cell).font(.body).fontWeight(header ? .semibold : nil)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(minWidth: 64, maxWidth: 280, alignment: cell.alignment.frame)
            .background(Color(uiColor: header || row.isMultiple(of: 2) ? .secondarySystemBackground : .systemBackground))
            .overlay(Rectangle().strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5))
            .gridColumnAlignment(cell.alignment.horizontal)
    }
    private func label(_ cell: MarkdownTableDocument.Cell) -> Text {
        var result = Text("")
        for run in cell.runs {
            var part: Text
            if let url = run.link {
                var attributed = AttributedString(run.text); attributed.link = url
                part = Text(attributed)
            } else { part = Text(run.text) }
            if run.styles.contains(.code) { part = part.font(.body.monospaced()) }
            if run.styles.contains(.strong) { part = part.bold() }
            if run.styles.contains(.emphasis) { part = part.italic() }
            if run.styles.contains(.strikethrough) { part = part.strikethrough() }
            result = result + part
        }
        return result
    }
}

private extension MarkdownTableDocument.Alignment {
    var horizontal: HorizontalAlignment {
        switch self { case .leading: return .leading; case .center: return .center; case .trailing: return .trailing }
    }
    var frame: SwiftUI.Alignment {
        switch self { case .leading: return .leading; case .center: return .center; case .trailing: return .trailing }
    }
}
