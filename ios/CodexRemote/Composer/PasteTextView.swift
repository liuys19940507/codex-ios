import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
struct PasteTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let fontSize: CGFloat
    let editable: Bool
    let onPasteAttachments: ([NSItemProvider]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> AttachmentTextView {
        let view = AttachmentTextView()
        view.delegate = context.coordinator; context.coordinator.view = view
        view.backgroundColor = .clear; view.textColor = .label
        view.isScrollEnabled = true; view.isSelectable = true
        view.adjustsFontForContentSizeCategory = false
        view.allowsEditingTextAttributes = false
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.textContainer.lineFragmentPadding = 5
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityIdentifier = "任务草稿"; view.accessibilityLabel = "任务草稿"
        let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        toolbar.autoresizingMask = [.flexibleWidth]
        let close = UIBarButtonItem(title: "收起键盘", style: .plain, target: context.coordinator, action: #selector(Coordinator.closeKeyboard))
        toolbar.items = [UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil), close]
        view.inputAccessoryView = toolbar
        return view
    }
    func updateUIView(_ view: AttachmentTextView, context: Context) {
        context.coordinator.parent = self
        view.font = UIFont.systemFont(ofSize: fontSize); view.isEditable = editable
        view.receiveAttachments = onPasteAttachments
        if view.text != text {
            view.text = text
            view.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            if view.isFirstResponder { view.scrollRangeToVisible(view.selectedRange) }
        }
        if !focused, view.isFirstResponder { view.resignFirstResponder() }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PasteTextView
        weak var view: UITextView?
        init(_ parent: PasteTextView) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.focused = true }
        func textViewDidEndEditing(_ textView: UITextView) { parent.focused = false }
        @objc func closeKeyboard() { parent.focused = false; view?.resignFirstResponder() }
    }
}

@MainActor
final class AttachmentTextView: UITextView {
    var receiveAttachments: (([NSItemProvider]) -> Void)?
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), isEditable,
           UIPasteboard.general.types.contains(where: AttachmentMediaImport.canPasteType) { return true }
        return super.canPerformAction(action, withSender: sender)
    }
    override func paste(_ sender: Any?) {
        // Read clipboard contents only for the user's explicit paste action.
        if isEditable, let files = UIPasteboard.general.urls?.filter(\.isFileURL), !files.isEmpty, let receiveAttachments {
            receiveAttachments(files.map { NSItemProvider(item: $0 as NSURL, typeIdentifier: UTType.fileURL.identifier) }); return
        }
        let providers = UIPasteboard.general.itemProviders.filter(AttachmentMediaImport.canImport)
        if isEditable, !providers.isEmpty, let receiveAttachments { receiveAttachments(providers); return }
        super.paste(sender)
    }
}
