import SwiftUI

struct QuestionField: Identifiable {
    struct Choice: Identifiable { let label: String; let description: String; var id: String { label } }
    let id: String
    let title: String
    let prompt: String
    let secret: Bool
    let allowsOther: Bool
    let choices: [Choice]
    static func parse(_ value: JSONValue) -> [QuestionField]? {
        guard case .object(let options) = value, case .array(let raw) = options["questions"], !raw.isEmpty else { return nil }
        var fields: [QuestionField] = [], ids = Set<String>()
        for value in raw {
            guard case .object(let q) = value, case .string(let id) = q["id"], !id.isEmpty, ids.insert(id).inserted,
                  case .string(let prompt) = q["question"] else { return nil }
            var choices: [Choice] = [], labels = Set<String>()
            if case .array(let values) = q["options"] {
                for value in values {
                    guard case .object(let option) = value, case .string(let label) = option["label"], !label.isEmpty, labels.insert(label).inserted else { return nil }
                    choices.append(Choice(label: label, description: option["description"]?.stringValue ?? ""))
                }
                if choices.isEmpty { return nil }
            } else if q["options"] != nil && q["options"] != .null { return nil }
            fields.append(QuestionField(id: id, title: q["header"]?.stringValue ?? "问题", prompt: prompt,
                                        secret: q["isSecret"] == .bool(true), allowsOther: q["isOther"] == .bool(true), choices: choices))
        }
        return fields
    }
}

@MainActor
struct QuestionView: View {
    let fields: [QuestionField]
    let enabled: Bool
    let submit: (JSONValue) -> Void
    @State private var selections: [String: String] = [:]
    @State private var answers: [String: String] = [:]
    private func value(_ field: QuestionField) -> String? {
        if field.choices.isEmpty || selections[field.id] == "other" { return answers[field.id] }
        guard let selected = selections[field.id], let index = Int(selected), field.choices.indices.contains(index) else { return nil }
        return field.choices[index].label
    }
    private var complete: Bool { fields.allSatisfy { !(value($0) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: 8) {
                    Text(field.title).font(.headline)
                    Text(field.prompt).textSelection(.enabled)
                    if !field.choices.isEmpty {
                        Picker("选择回答", selection: Binding(get: { selections[field.id] ?? "" }, set: { selections[field.id] = $0 })) {
                            Text("请选择").tag("")
                            ForEach(Array(field.choices.enumerated()), id: \.offset) { index, choice in Text(choice.label).tag(String(index)) }
                            if field.allowsOther { Text("填写回答").tag("other") }
                        }
                        if let choice = field.choices.first(where: { $0.label == value(field) }), !choice.description.isEmpty {
                            Text(choice.description).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if field.choices.isEmpty || selections[field.id] == "other" {
                        let binding = Binding(get: { answers[field.id] ?? "" }, set: { answers[field.id] = $0 })
                        if field.secret { SecureField("回答", text: binding).textContentType(.none) }
                        else { TextField("回答", text: binding, axis: .vertical).lineLimit(2...8) }
                    }
                }
            }
            Button("提交回答") {
                let result = Dictionary(uniqueKeysWithValues: fields.map { ($0.id, JSONValue.object(["answers": .array([.string(value($0) ?? "")])])) })
                submit(.object(["answers": .object(result)]))
            }.buttonStyle(.borderedProminent).disabled(!enabled || !complete)
        }.disabled(!enabled)
    }
}

extension JSONValue {
    var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    var objectValue: [String: JSONValue] { if case .object(let value) = self { return value }; return [:] }
    var formatted: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(data: encoder.encode(self), encoding: .utf8)) ?? "无法显示请求内容"
    }
}
