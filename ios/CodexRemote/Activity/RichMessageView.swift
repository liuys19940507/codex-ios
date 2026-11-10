import SwiftUI
import MarkdownUI

private struct PlaceholderImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View { Label("图片", systemImage: "photo").font(.callout).foregroundStyle(.secondary) }
}
private struct PlaceholderInlineImageProvider: InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image { Image(systemName: "photo") }
}

@MainActor
struct RichMessageView: View {
    let text: String
    var onRendered: (() -> Void)? = nil
    @StateObject private var rendering = MessageRenderModel()
    @State private var showingAll = false
    // MarkdownUI's ScaledFontSizeModifier applies Dynamic Type itself.
    private let fontSize: CGFloat = 17
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(rendering.blocks) { block in
                if block.kind == .code {
                    CodeOutputView(text: block.content, language: block.language ?? "代码", title: "代码")
                    if !block.complete { Text("代码块未闭合").font(.caption).foregroundStyle(.secondary) }
                } else {
                    Markdown(String(block.content.prefix(16000)))
                        .markdownTheme(Theme.gitHub.text {
                            FontSize(fontSize); BackgroundColor(nil); ForegroundColor(.primary)
                        })
                        .markdownBlockStyle(\.codeBlock) { config in CodeOutputView(text: config.content, language: config.language ?? "代码", title: "代码") }
                        .markdownBlockStyle(\.table) { config in
                            // Resolve table cell anchors in a separate viewport
                            // with content-sized columns, independent of history.
                            ScrollView(.horizontal) {
                                config.label.fixedSize(horizontal: true, vertical: true)
                                    .markdownTableBorderStyle(.init(color: .secondary.opacity(0.3)))
                                    .markdownTableBackgroundStyle(.alternatingRows(.clear, Color(uiColor: .secondarySystemBackground)))
                            }.markdownMargin(top: 0, bottom: 16)
                        }
                        .markdownImageProvider(PlaceholderImageProvider())
                        .markdownInlineImageProvider(PlaceholderInlineImageProvider())
                        .textSelection(.enabled)
                    if block.content.count > 16000 { Button("查看完整回复") { showingAll = true } }
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            ["https", "http"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
        .onAppear { rendering.update(text) }
        .onChange(of: text) { rendering.update($0) }
        .onDisappear { rendering.cancel() }
        .task(id: rendering.revision) {
            guard rendering.revision > 0 else { return }
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard !Task.isCancelled else { return }
            onRendered?()
        }
        .sheet(isPresented: $showingAll) { RawOutputSheet(title: "完整回复", text: text) }
    }
}
