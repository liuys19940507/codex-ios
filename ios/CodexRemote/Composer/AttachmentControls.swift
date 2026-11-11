import SwiftUI
import PhotosUI
import QuickLook
import UniformTypeIdentifiers

@MainActor
struct AttachmentControls: View {
    @ObservedObject var model: ComposerModel
    @State private var photos = false
    @State private var files = false
    @State private var address = false
    @State private var imageAddress = ""
    @State private var serverPath = false
    var body: some View {
        Menu {
            Button { photos = true } label: { Label("从照片选择", systemImage: "photo") }
            Button { files = true } label: { Label("选择文件", systemImage: "doc") }
            Button { address = true } label: { Label("添加图片地址", systemImage: "link") }
        } label: {
            Image(systemName: "plus.circle").font(.system(size: 23)).frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("添加附件")
        .disabled(!model.writable || model.importing || model.uploading || model.attachments.count >= AttachmentLimits.count)
        .sheet(isPresented: $photos) {
            AttachmentPhotoPicker(limit: max(1, AttachmentLimits.count - model.attachments.count)) { providers in
                photos = false
                Task { await AttachmentMediaImport.add(providers, to: model) }
            }.ignoresSafeArea()
        }
        .fileImporter(isPresented: $files, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await AttachmentMediaImport.addFiles(urls, to: model) }
            case .failure(let error): model.reportAttachmentError(error)
            }
        }
        .sheet(isPresented: $address) {
            NavigationStack {
                Form {
                    Picker("地址类型", selection: $serverPath) {
                        Text("图片 URL").tag(false); Text("电脑图片路径").tag(true)
                    }.pickerStyle(.segmented)
                    TextField(serverPath ? "C:\\项目\\图片.png" : "https://example.com/image.png", text: $imageAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("图片地址")
                    Text(serverPath ? "电脑图片需位于当前项目中。" : "也支持 PNG/JPEG 的图片 data URL。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("每个附件最多20MB，一次最多10个。只有点击发送后才上传。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .navigationTitle("添加图片地址").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { address = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("添加") {
                            Task {
                                do { try await model.addImageAddress(imageAddress, serverPath: serverPath); address = false; imageAddress = "" }
                                catch { model.reportAttachmentError(error) }
                            }
                        }.disabled(imageAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }
}

@MainActor
struct AttachmentStrip: View {
    @ObservedObject var model: ComposerModel
    @State private var preview: DraftAttachment?
    var body: some View {
        if !model.attachments.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(model.attachments) { item in
                        HStack(spacing: 2) {
                            Button { preview = item } label: {
                                Label(item.name, systemImage: item.kind == .file ? "doc" : "photo")
                                    .font(.subheadline).lineLimit(1).frame(maxWidth: 180)
                            }.accessibilityLabel("预览附件：" + item.name)
                            Button {
                                do { try model.removeAttachment(item.id) } catch { model.reportAttachmentError(error) }
                            } label: { Image(systemName: "xmark.circle.fill").frame(minWidth: 44, minHeight: 44) }
                                .accessibilityLabel("移除附件：" + item.name).disabled(model.uploading)
                        }
                        .buttonStyle(.plain).padding(.leading, 10)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    }
                }.padding(.vertical, 2)
            }.frame(maxHeight: 64).accessibilityIdentifier("附件列表")
            .sheet(item: $preview) { item in
                NavigationStack {
                    Group {
                        if let url = model.previewURL(item) { AttachmentQuickLook(url: url, name: item.name) }
                        else {
                            ScrollView { Text(item.location ?? item.name).textSelection(.enabled).padding() }
                        }
                    }
                    .navigationTitle("附件预览").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭预览") { preview = nil } } }
                }
            }
        }
    }
}

private struct AttachmentPhotoPicker: UIViewControllerRepresentable {
    let limit: Int
    let finished: ([NSItemProvider]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(finished: finished) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images; configuration.selectionLimit = limit
        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: PHPickerViewController, context: Context) { }
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let finished: ([NSItemProvider]) -> Void
        init(finished: @escaping ([NSItemProvider]) -> Void) { self.finished = finished }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) { finished(results.map(\.itemProvider)) }
    }
}

private struct AttachmentQuickLook: UIViewControllerRepresentable {
    let url: URL
    let name: String
    func makeCoordinator() -> Coordinator { Coordinator(url: url, name: name) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) { }
    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewItem {
        let previewItemURL: URL?
        let previewItemTitle: String?
        init(url: URL, name: String) { previewItemURL = url; previewItemTitle = name }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { self }
    }
}
