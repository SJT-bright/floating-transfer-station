import AppKit
import SwiftUI

struct TextDocumentSheet: View {
    @ObservedObject var model: BoardModel
    private let itemID: UUID
    private let onClose: () -> Void
    @State private var draft: String
    @State private var original: String
    @State private var isEditing: Bool
    @State private var saveError: String?

    init(model: BoardModel, item: BoardItem, initiallyEditing: Bool, onClose: @escaping () -> Void) {
        self.model = model
        itemID = item.id
        self.onClose = onClose
        _draft = State(initialValue: item.text ?? "")
        _original = State(initialValue: item.text ?? "")
        _isEditing = State(initialValue: initiallyEditing)
    }

    private var current: BoardItem? { model.items.first { $0.id == itemID && $0.kind == .text } }
    private var isEmpty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isEditing ? "编辑正文" : "文字全文").font(.headline)
                Spacer()
                if isEditing {
                    Button("取消", action: onClose).keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("station-body-cancel")
                    Button("保存") {
                        if model.updateText(itemID, to: draft, expectedOriginal: original) { onClose() }
                        else { saveError = model.statusText }
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(isEmpty || draft == original)
                    .accessibilityIdentifier("station-body-save")
                } else {
                    Button("编辑正文") {
                        guard let current else { return }
                        original = current.text ?? ""
                        draft = original
                        saveError = nil
                        isEditing = true
                    }
                    .disabled(current == nil)
                    .accessibilityIdentifier("station-body-edit")
                    Button("复制全文") { if let current { model.copyToClipboard(current) } }
                        .disabled(current == nil)
                    Button("关闭", action: onClose).keyboardShortcut(.cancelAction)
                }
            }
            .buttonStyle(.bordered)
            if let name = current?.name, !name.isEmpty {
                Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            if isEditing {
                Text("只修改正文，名称、分类、置顶和排序保持不变。")
                    .font(.caption).foregroundStyle(.secondary)
                BodyTextEditor(text: $draft)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let saveError {
                    Text(saveError).font(.caption).foregroundStyle(.red)
                        .accessibilityIdentifier("station-body-save-error")
                } else if isEmpty {
                    Text("正文不能为空；取消会保留原文。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                FullTextReader(text: current?.text ?? "这条内容已被删除。")
            }
        }
        .padding(16)
        .frame(width: 500, height: 440)
        .interactiveDismissDisabled(isEditing && draft != original)
    }
}

private struct BodyTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        let editor = BodyEditingTextView(frame: .zero)
        editor.string = text
        editor.isEditable = true
        editor.isSelectable = true
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = .textColor
        editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 460, height: CGFloat.greatestFiniteMagnitude)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.setAccessibilityIdentifier("station-body-editor")
        editor.delegate = context.coordinator
        scroll.documentView = editor
        DispatchQueue.main.async { editor.window?.makeFirstResponder(editor) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        // Do not replace the native string during typing: that would destroy
        // IME composition, selection and undo history.
        guard let editor = scroll.documentView as? NSTextView, editor.string != text else { return }
        editor.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BodyTextEditor
        init(_ parent: BodyTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}

// The accessory app intentionally has no system Edit menu. Handle these in
// the editor itself so standard shortcuts also work in its attached sheet.
private final class BodyEditingTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": selectAll(nil)
        case "c": copy(nil)
        case "x": cut(nil)
        case "v": pasteAsPlainText(nil)
        case "z":
            if flags.contains(.shift) { undoManager?.redo() }
            else { undoManager?.undo() }
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
