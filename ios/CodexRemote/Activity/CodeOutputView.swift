import SwiftUI
import UIKit

struct CodeOutputView: View {
    let text: String
    var language: String? = nil
    var title = "输出"
    var tail = false
    @State private var copied = false
    @State private var showingAll = false
    private var preview: String {
        let lines = RawText.lines(text)
        let value = (tail ? Array(lines.suffix(12)) : Array(lines.prefix(16))).joined()
        return tail ? String(value.suffix(6000)) : String(value.prefix(6000))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(language?.isEmpty == false ? language! : title).font(.caption.monospaced().weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(language == nil ? "复制全部输出" : "复制代码") { UIPasteboard.general.string = text; copied = true }
                    .font(.caption).frame(minHeight: 44)
            }
            if copied { Text("已复制").font(.caption).foregroundStyle(.secondary) }
            if !text.isEmpty {
                ScrollView(.horizontal) {
                    Text(preview).font(.callout.monospaced()).textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                }
                if preview != text { Text(tail ? "显示末尾输出" : "显示部分代码").font(.caption).foregroundStyle(.secondary) }
                Button("查看完整\(language == nil ? "输出" : "代码")") { showingAll = true }.font(.caption).frame(minHeight: 44)
            } else { Text("等待输出…").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(12).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .buttonStyle(.borderless)
        .sheet(isPresented: $showingAll) { RawOutputSheet(title: language ?? title, text: text) }
    }
}

struct RawOutputSheet: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    var body: some View {
        NavigationStack {
            GeometryReader { viewport in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(ActivityPresentation.chunks(text).enumerated()), id: \.offset) { _, chunk in
                            Text(chunk).font(.callout.monospaced()).textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                        }
                    }.padding()
                        .frame(minWidth: viewport.size.width, minHeight: viewport.size.height, alignment: .topLeading)
                }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button(copied ? "已复制" : "复制全部") { UIPasteboard.general.string = text; copied = true } }
            }
        }
    }
}
