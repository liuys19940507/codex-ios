import SwiftUI

struct MCPField: Identifiable {
    let id: String
    let schema: [String: JSONValue]
    let required: Bool
    var title: String { schema["title"]?.stringValue ?? id }
    var type: String { schema["type"]?.stringValue ?? "" }
    var choices: [String] { Self.choices(type == "array" ? (schema["items"] ?? .null).objectValue : schema) ?? [] }
    static func choices(_ schema: [String: JSONValue]) -> [String]? {
        if case .array(let values) = schema["enum"] {
            let strings = values.compactMap(\.stringValue)
            return strings.count == values.count ? strings : nil
        }
        if case .array(let values) = schema["oneOf"] ?? schema["anyOf"] {
            var strings: [String] = []
            for value in values {
                let fields = value.objectValue
                guard Set(fields.keys).isSubset(of: ["const", "title"]), let string = fields["const"]?.stringValue else { return nil }
                strings.append(string)
            }
            return strings
        }
        return nil
    }
    static func parse(_ value: JSONValue) -> [MCPField]? {
        let schema = value.objectValue
        guard schema["type"] == .string("object"), Set(schema.keys).isSubset(of: ["$schema", "type", "properties", "required"]),
              case .object(let properties) = schema["properties"] else { return nil }
        var required: [String] = []
        if case .array(let values) = schema["required"] {
            required = values.compactMap(\.stringValue)
            guard required.count == values.count, Set(required).isSubset(of: Set(properties.keys)) else { return nil }
        } else if schema["required"] != nil { return nil }
        var fields: [MCPField] = []
        let common: Set<String> = ["type", "title", "description", "default"]
        for key in properties.keys.sorted() {
            guard case .object(let raw) = properties[key], let type = raw["type"]?.stringValue else { return nil }
            let extra: Set<String>
            switch type {
            case "boolean": extra = []
            case "number", "integer": extra = ["minimum", "maximum"]
            case "string": extra = ["enum", "enumNames", "oneOf", "minLength", "maxLength", "format"]
            case "array":
                extra = ["items", "minItems", "maxItems"]
                let items = (raw["items"] ?? .null).objectValue
                guard Set(items.keys).isSubset(of: ["type", "enum", "anyOf"]), !(choices(items) ?? []).isEmpty else { return nil }
            default: return nil
            }
            guard Set(raw.keys).isSubset(of: common.union(extra)) else { return nil }
            if type == "string" && (raw["enum"] != nil || raw["oneOf"] != nil), (choices(raw) ?? []).isEmpty { return nil }
            if let format = raw["format"]?.stringValue, !["email", "uri", "date", "date-time"].contains(format) { return nil }
            fields.append(MCPField(id: key, schema: raw, required: required.contains(key)))
        }
        return fields
    }
}

@MainActor
struct MCPRequestView: View {
    let schema: JSONValue
    let enabled: Bool
    let submit: (JSONValue) -> Void
    @State private var included = Set<String>()
    @State private var texts: [String: String] = [:]
    @State private var booleans: [String: Bool] = [:]
    @State private var selected: [String: Set<String>] = [:]
    private func content(_ fields: [MCPField]) -> JSONValue? {
        var result: [String: JSONValue] = [:]
        for field in fields where field.required || included.contains(field.id) {
            let text = texts[field.id] ?? ""
            switch field.type {
            case "boolean": result[field.id] = .bool(booleans[field.id] ?? false)
            case "number", "integer":
                guard let number = Double(text), number.isFinite, field.type != "integer" || number.rounded() == number else { return nil }
                if case .number(let min) = field.schema["minimum"], number < min { return nil }
                if case .number(let max) = field.schema["maximum"], number > max { return nil }
                result[field.id] = .number(number)
            case "array":
                let values = field.choices.filter { selected[field.id]?.contains($0) == true }
                if case .number(let min) = field.schema["minItems"], Double(values.count) < min { return nil }
                if case .number(let max) = field.schema["maxItems"], Double(values.count) > max { return nil }
                result[field.id] = .array(values.map(JSONValue.string))
            default:
                guard field.choices.isEmpty || field.choices.contains(text) else { return nil }
                if case .number(let min) = field.schema["minLength"], Double(text.unicodeScalars.count) < min { return nil }
                if case .number(let max) = field.schema["maxLength"], Double(text.unicodeScalars.count) > max { return nil }
                result[field.id] = .string(text)
            }
        }
        return .object(result)
    }
    var body: some View {
        if let fields = MCPField.parse(schema) {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(fields) { field in
                    VStack(alignment: .leading, spacing: 6) {
                        if !field.required { Toggle("包含 \(field.title)", isOn: Binding(get: { included.contains(field.id) }, set: { if $0 { included.insert(field.id) } else { included.remove(field.id) } })) }
                        if field.required || included.contains(field.id) {
                            Text(field.title).font(.headline)
                            if let description = field.schema["description"]?.stringValue { Text(description).font(.footnote) }
                            if field.type == "boolean" { Toggle(field.title, isOn: Binding(get: { booleans[field.id] ?? false }, set: { booleans[field.id] = $0 })) }
                            else if field.type == "array" {
                                ForEach(field.choices, id: \.self) { choice in
                                    Toggle(choice, isOn: Binding(get: { selected[field.id]?.contains(choice) == true }, set: { if $0 { selected[field.id, default: []].insert(choice) } else { selected[field.id]?.remove(choice) } }))
                                }
                            } else if !field.choices.isEmpty {
                                Picker(field.title, selection: Binding(get: { texts[field.id] ?? "" }, set: { texts[field.id] = $0 })) {
                                    Text("请选择").tag("")
                                    ForEach(field.choices, id: \.self) { Text($0).tag($0) }
                                }
                            } else {
                                TextField(field.title, text: Binding(get: { texts[field.id] ?? "" }, set: { texts[field.id] = $0 }), axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled()
                            }
                        }
                    }
                }
                Button("确认表单") { if let value = content(fields) { respond("accept", value) } }.disabled(!enabled || content(fields) == nil)
                Button("拒绝表单", role: .destructive) { respond("decline", .null) }.disabled(!enabled)
                Button("取消请求") { respond("cancel", .null) }.disabled(!enabled)
            }.disabled(!enabled)
        } else {
            Text("此表单格式尚不支持，请在 Windows CLI 中处理。").font(.footnote)
        }
    }
    private func respond(_ action: String, _ content: JSONValue) { submit(.object(["action": .string(action), "content": content, "_meta": .null])) }
}
