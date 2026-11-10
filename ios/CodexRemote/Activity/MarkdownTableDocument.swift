import Foundation
import cmark_gfm
import cmark_gfm_extensions

struct MarkdownTableDocument: Equatable {
    enum Alignment: Equatable { case leading, center, trailing }
    struct Styles: OptionSet {
        let rawValue: Int
        static let strong = Self(rawValue: 1 << 0)
        static let emphasis = Self(rawValue: 1 << 1)
        static let code = Self(rawValue: 1 << 2)
        static let strikethrough = Self(rawValue: 1 << 3)
    }
    struct Run: Equatable {
        var text: String
        let styles: Styles
        let link: URL?
    }
    struct Cell: Equatable {
        let runs: [Run]
        let alignment: Alignment
        var text: String { runs.map(\.text).joined() }
    }
    struct Row: Equatable {
        let cells: [Cell]
        let isHeader: Bool
    }
    let rows: [Row]
    var columnCount: Int { rows.first?.cells.count ?? 0 }

    // MarkdownUI's canonical Markdown preserves table cells; its HTML export
    // with the pinned cmark version omits cell tags. Read the same pinned GFM
    // parser's public tree directly, without guessing boundaries from text.
    static func parse(markdown: String) -> Self? {
        guard markdown.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              markdown.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { return nil }
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return nil }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "autolink", "tagfilter", "tasklist"] {
            guard let syntax = cmark_find_syntax_extension(name) else { return nil }
            cmark_parser_attach_syntax_extension(parser, syntax)
        }
        cmark_parser_feed(parser, markdown, markdown.utf8.count)
        guard let document = cmark_parser_finish(parser) else { return nil }
        defer { cmark_node_free(document) }
        guard let table = cmark_node_first_child(document), type(table) == "table", cmark_node_next(table) == nil else { return nil }
        let count = Int(cmark_gfm_extensions_get_table_columns(table))
        guard count > 0, let alignments = cmark_gfm_extensions_get_table_alignments(table) else { return nil }
        var rows: [Row] = [], row = cmark_node_first_child(table)
        while let current = row {
            guard ["table_header", "table_row"].contains(type(current)) else { return nil }
            var cells: [Cell] = [], node = cmark_node_first_child(current)
            while let currentCell = node {
                guard type(currentCell) == "table_cell", cells.count < count else { return nil }
                var runs: [Run] = []
                guard readChildren(currentCell, styles: [], link: nil, depth: 0, runs: &runs) else { return nil }
                let alignment: Alignment
                switch alignments[cells.count] { case 99: alignment = .center; case 114: alignment = .trailing; default: alignment = .leading }
                cells.append(Cell(runs: runs, alignment: alignment))
                node = cmark_node_next(currentCell)
            }
            guard cells.count == count else { return nil }
            rows.append(Row(cells: cells, isHeader: cmark_gfm_extensions_get_table_row_is_header(current) != 0))
            row = cmark_node_next(current)
        }
        return rows.isEmpty ? nil : Self(rows: rows)
    }

    private static func readChildren(_ parent: OpaquePointer, styles: Styles, link: URL?, depth: Int, runs: inout [Run]) -> Bool {
        guard depth < 64 else { return false }
        var node = cmark_node_first_child(parent)
        while let current = node {
            switch type(current) {
            case "text": append(literal(current), styles: styles, link: link, runs: &runs)
            case "code": append(literal(current), styles: styles.union(.code), link: link, runs: &runs)
            case "softbreak", "linebreak": append("\n", styles: styles, link: link, runs: &runs)
            case "emph", "strong", "strikethrough", "link":
                var next = styles, target = link
                switch type(current) {
                case "emph": next.insert(.emphasis)
                case "strong": next.insert(.strong)
                case "strikethrough": next.insert(.strikethrough)
                default: target = safeLink(cmark_node_get_url(current).map(String.init(cString:)))
                }
                guard readChildren(current, styles: next, link: target, depth: depth + 1, runs: &runs) else { return false }
            case "image":
                guard let alt = imageLabel(current, depth: 0) else { return false }
                append(alt.isEmpty ? "[图片]" : "[图片：\(alt)]", styles: styles, link: nil, runs: &runs)
            case "html_inline":
                guard ["<br>", "<br/>", "<br />"].contains(literal(current).lowercased()) else { return false }
                append("\n", styles: styles, link: link, runs: &runs)
            default: return false
            }
            node = cmark_node_next(current)
        }
        return true
    }
    private static func imageLabel(_ parent: OpaquePointer, depth: Int) -> String? {
        guard depth < 64 else { return nil }
        var value = "", node = cmark_node_first_child(parent)
        while let current = node {
            switch type(current) {
            case "text", "code": value += literal(current)
            case "softbreak", "linebreak": value += " "
            case "emph", "strong", "strikethrough", "link", "image":
                guard let child = imageLabel(current, depth: depth + 1) else { return nil }
                value += child
            default: return nil
            }
            node = cmark_node_next(current)
        }
        return value
    }
    private static func type(_ node: OpaquePointer) -> String { cmark_node_get_type_string(node).map(String.init(cString:)) ?? "" }
    private static func literal(_ node: OpaquePointer) -> String { cmark_node_get_literal(node).map(String.init(cString:)) ?? "" }
    private static func append(_ text: String, styles: Styles, link: URL?, runs: inout [Run]) {
        guard !text.isEmpty else { return }
        if let last = runs.last, last.styles == styles, last.link == link { runs[runs.count - 1].text += text }
        else { runs.append(Run(text: text, styles: styles, link: link)) }
    }
    private static func safeLink(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false else { return nil }
        return url
    }
}
