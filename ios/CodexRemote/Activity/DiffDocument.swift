import Foundation

struct DiffFile: Equatable, Sendable {
    var path: String
    var lines: [DiffLine] = []
    var added = 0, removed = 0
    var partial = false, binary = false
    var raw: String { lines.map(\.text).joined() }
}

struct DiffDocument: Equatable, Sendable {
    let files: [DiffFile]
    static func parse(_ text: String, path: String) -> DiffDocument {
        var files: [DiffFile] = [], file = DiffFile(path: path)
        var old = 0, new = 0, inHunk = false, sawFile = false
        let hunk = try! NSRegularExpression(pattern: #"^@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@"#)
        func finish() {
            if inHunk && (old != 0 || new != 0) { file.partial = true }
            if !file.lines.isEmpty { files.append(file) }
            file = DiffFile(path: path); old = 0; new = 0; inHunk = false
        }
        func headerPath(_ value: String) -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let decoded = (try? JSONDecoder().decode(String.self, from: Data(trimmed.utf8))) ?? trimmed
            return decoded.hasPrefix("a/") || decoded.hasPrefix("b/") ? String(decoded.dropFirst(2)) : decoded
        }
        for raw in RawText.lines(text) {
            let line = RawText.visibleLine(raw)
            var kind = DiffLine.Kind.context
            if line.hasPrefix("diff --git ") {
                if sawFile { finish() }
                sawFile = true; kind = .header
                let parts = line.components(separatedBy: " b/")
                if parts.count == 2 { file.path = parts[1] }
            } else if let match = hunk.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                if inHunk && (old != 0 || new != 0) { file.partial = true }
                func count(_ index: Int) -> Int { Range(match.range(at: index), in: line).flatMap { Int(line[$0]) } ?? 1 }
                old = count(1); new = count(2); inHunk = true; kind = .header
            } else if inHunk {
                if line.hasPrefix("+") { file.added += 1; new -= 1; kind = .add }
                else if line.hasPrefix("-") { file.removed += 1; old -= 1; kind = .remove }
                else if line.hasPrefix(" ") { old -= 1; new -= 1 }
                else if !line.hasPrefix("\\ No newline") { file.partial = true }
                if old < 0 || new < 0 { file.partial = true }
                if old == 0 && new == 0 { inHunk = false }
            } else if line.hasPrefix("+++ ") || line.hasPrefix("--- ") {
                let candidate = headerPath(String(line.dropFirst(4)))
                if candidate != "/dev/null" { file.path = candidate }
                kind = .header
            } else if line.hasPrefix("rename to ") { file.path = headerPath(String(line.dropFirst(10))); kind = .header }
            else if line.hasPrefix("Binary files ") || line == "GIT binary patch" { file.binary = true; kind = .header }
            else if line.hasPrefix("index ") || line.hasPrefix("rename from ") || line.hasPrefix("similarity index ") { kind = .header }
            else if line.hasPrefix("+") { file.added += 1; kind = .add }
            else if line.hasPrefix("-") { file.removed += 1; kind = .remove }
            file.lines.append(DiffLine(text: raw, kind: kind))
        }
        finish()
        return DiffDocument(files: files)
    }
}
