import Foundation
import UIKit
import UniformTypeIdentifiers

@MainActor
enum AttachmentMediaImport {
    struct Item: Sendable { let data: Data; let name: String; let kind: AttachmentKind }
    static func canPasteType(_ identifier: String) -> Bool {
        guard let type = UTType(identifier) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .fileURL) ||
            (type.conforms(to: .data) && !type.conforms(to: .text) && !type.conforms(to: .url))
    }
    static func canImport(_ provider: NSItemProvider) -> Bool {
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) || provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) { return true }
        if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) || provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) { return false }
        return provider.registeredTypeIdentifiers.contains(where: canPasteType)
    }
    static func add(_ providers: [NSItemProvider], to model: ComposerModel) async {
        model.beginAttachmentImport(); defer { model.endAttachmentImport() }
        var failures: [String] = []
        for provider in providers {
            do {
                guard model.attachments.count < AttachmentLimits.count else { throw ClientCommandError(message: "一次最多添加10个附件。") }
                let loaded = try await load(provider), item = try normalized(loaded)
                try await model.importData(item.data, name: item.name, kind: item.kind)
            } catch { failures.append(error.localizedDescription) }
        }
        if let failure = failures.first { model.reportAttachmentError(ClientCommandError(message: failure)) }
    }
    static func addFiles(_ files: [URL], to model: ComposerModel) async {
        model.beginAttachmentImport(); defer { model.endAttachmentImport() }
        var failures: [String] = []
        for file in files {
            do {
                guard model.attachments.count < AttachmentLimits.count else { throw ClientCommandError(message: "一次最多添加10个附件。") }
                let loaded = try await Task.detached(priority: .userInitiated) { try readFile(file) }.value
                let item = try normalized(loaded)
                try await model.importData(item.data, name: item.name, kind: item.kind)
            } catch { failures.append(error.localizedDescription) }
        }
        if let failure = failures.first { model.reportAttachmentError(ClientCommandError(message: failure)) }
    }
    nonisolated private static func readFile(_ file: URL) throws -> Item {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        let data = try AttachmentDraftStore.readBounded(file)
        let kind: AttachmentKind = UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true ? .image : .file
        return Item(data: data, name: file.lastPathComponent, kind: kind)
    }
    private static func load(_ provider: NSItemProvider) async throws -> Item {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, error in
                    if let error { continuation.resume(throwing: error); return }
                    do {
                        let url: URL?
                        if let value = value as? URL { url = value }
                        else if let value = value as? Data { url = URL(dataRepresentation: value, relativeTo: nil) }
                        else if let value = value as? String { url = URL(string: value) }
                        else { url = nil }
                        guard let url, url.isFileURL else { throw ConnectionError.invalidPath }
                        continuation.resume(returning: try readFile(url))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        let imageType = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true }
        guard let type = imageType ?? provider.registeredTypeIdentifiers.first(where: canPasteType) else { throw ClientCommandError(message: "剪贴板中没有可添加的图片或文件。") }
        let kind: AttachmentKind = imageType == nil ? .file : .image
        let suggested = provider.suggestedName ?? (kind == .image ? "粘贴图片" : "粘贴文件")
        let suffix = UTType(type)?.preferredFilenameExtension ?? "bin"
        let name = (suggested as NSString).pathExtension.isEmpty ? suggested + "." + suffix : suggested
        // Copy within the provider callback: its temporary file is removed on return.
        // Do not retry a bounded-read failure through whole-payload Data loading.
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                if let error { continuation.resume(throwing: error); return }
                do {
                    guard let url else { throw ConnectionError.invalidResponse }
                    let loaded = try readFile(url)
                    continuation.resume(returning: Item(data: loaded.data, name: name, kind: kind))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private static func normalized(_ item: Item) throws -> Item {
        guard item.kind == .image else { return item }
        guard let image = UIImage(data: item.data) else { throw ClientCommandError(message: "无法读取所选图片。") }
        let alpha = image.cgImage.map { ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains($0.alphaInfo) } ?? true
        guard let data = alpha ? image.pngData() : image.jpegData(compressionQuality: 0.92) else { throw ClientCommandError(message: "图片转换未成功。") }
        try AttachmentLimits.data(data)
        let name = (item.name as NSString).deletingPathExtension + (alpha ? ".png" : ".jpg")
        return Item(data: data, name: name, kind: .image)
    }
}
