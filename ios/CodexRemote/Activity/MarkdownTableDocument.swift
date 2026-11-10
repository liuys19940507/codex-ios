import Foundation

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

    // Input is the existing Markdown parser's table HTML, never a URL.
    // Unsupported structure returns nil so the caller displays the whole table
    // as text. Original message bytes remain the authority for message copying.
    static func parse(html: String) -> Self? {
        guard html.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              html.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { return nil }
        let delegate = TableHTMLParser()
        let parser = XMLParser(data: Data(html.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.document
    }
}

private final class TableHTMLParser: NSObject, XMLParserDelegate {
    private typealias Document = MarkdownTableDocument
    private struct Context {
        var styles: Document.Styles = []
        var link: URL?
    }
    private struct Frame { let tag: String; let context: Context }
    private final class CellBuffer {
        var runs: [Document.Run] = []
        let alignment: Document.Alignment
        let header: Bool
        init(alignment: Document.Alignment, header: Bool) { self.alignment = alignment; self.header = header }
    }
    private var frames: [Frame] = []
    private var rows: [Document.Row] = []
    private var cells: [Document.Cell]?
    private var headers: [Bool] = []
    private var cell: CellBuffer?
    private var valid = true
    private var seenTable = false
    private var closedTable = false
    private let textParents: Set<String> = ["th", "td", "strong", "b", "em", "i", "code", "del", "s", "a"]
    var document: MarkdownTableDocument? {
        guard valid, closedTable, frames.isEmpty, cells == nil, cell == nil, !rows.isEmpty else { return nil }
        return MarkdownTableDocument(rows: rows)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        guard valid else { return }
        let tag = elementName.lowercased(), parent = frames.last?.tag
        var context = frames.last?.context ?? Context()
        switch tag {
        case "table":
            guard parent == nil, !seenTable else { reject(parser); return }
            seenTable = true
        case "thead", "tbody", "tfoot":
            guard parent == "table" else { reject(parser); return }
        case "tr":
            guard ["table", "thead", "tbody", "tfoot"].contains(parent ?? ""), cells == nil else { reject(parser); return }
            cells = []; headers = []
        case "th", "td":
            guard parent == "tr", cell == nil else { reject(parser); return }
            let alignment: Document.Alignment
            switch attributes["align"]?.lowercased() {
            case "center": alignment = .center
            case "right": alignment = .trailing
            default: alignment = .leading
            }
            cell = CellBuffer(alignment: alignment, header: tag == "th")
        default:
            guard cell != nil, textParents.contains(parent ?? "") else { reject(parser); return }
            switch tag {
            case "strong", "b": context.styles.insert(.strong)
            case "em", "i": context.styles.insert(.emphasis)
            case "code": context.styles.insert(.code)
            case "del", "s": context.styles.insert(.strikethrough)
            case "a": context.link = safeLink(attributes["href"])
            case "br", "img": break
            default: reject(parser); return
            }
        }
        frames.append(Frame(tag: tag, context: context))
        if tag == "br" { append("\n", context: context) }
        if tag == "img" {
            let alt = attributes["alt"] ?? ""
            context.link = nil
            append(alt.isEmpty ? "[图片]" : "[图片：\(alt)]", context: context)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard valid, let frame = frames.last, frame.tag == elementName.lowercased() else { reject(parser); return }
        switch frame.tag {
        case "th", "td":
            guard let completed = cell, cells != nil else { reject(parser); return }
            cells?.append(Document.Cell(runs: completed.runs, alignment: completed.alignment))
            headers.append(completed.header); cell = nil
        case "tr":
            guard let completed = cells, !completed.isEmpty,
                  rows.first.map({ $0.cells.count == completed.count }) ?? true,
                  headers.allSatisfy({ $0 == headers.first }) else { reject(parser); return }
            rows.append(Document.Row(cells: completed, isHeader: headers.first == true))
            cells = nil; headers = []
        case "table": closedTable = true
        default: break
        }
        frames.removeLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard valid else { return }
        if cell != nil, let frame = frames.last, textParents.contains(frame.tag) {
            append(string, context: frame.context)
        } else if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reject(parser) }
    }
    func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespaceString: String) { self.parser(parser, foundCharacters: whitespaceString) }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else { reject(parser); return }
        self.parser(parser, foundCharacters: text)
    }
    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { valid = false }
    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) { reject(parser) }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { reject(parser); return nil }

    private func append(_ text: String, context: Context) {
        guard !text.isEmpty, let cell else { return }
        if let last = cell.runs.last, last.styles == context.styles, last.link == context.link {
            cell.runs[cell.runs.count - 1].text += text
        } else { cell.runs.append(Document.Run(text: text, styles: context.styles, link: context.link)) }
    }
    private func safeLink(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false else { return nil }
        return url
    }
    private func reject(_ parser: XMLParser) { valid = false; parser.abortParsing() }
}
