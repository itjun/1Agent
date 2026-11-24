import SwiftUI

struct FilePreviewEditButton: View {
    @ObservedObject var column: FileColumn
    @State private var source: FileColumn.Preview?

    var body: some View {
        if let preview = column.preview, preview.isEditableText {
            Button("Edit") { source = preview }
                .accessibilityIdentifier("files.preview.edit")
                .sheet(item: $source) { snapshot in
                    FilePreviewEditor(column: column, source: snapshot)
                }
        }
    }
}

private struct FilePreviewEditor: View {
    let column: FileColumn
    let source: FileColumn.Preview
    @Environment(\.dismiss) private var dismiss
    @Environment(\.windowChrome) private var chrome
    @State private var original: TextFile.Decoded?
    @State private var draft = ""
    @State private var editor = CommandLiteralTextView(frame: .zero)
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(verbatim: source.entry.name).font(.headline).help(source.entry.path)
            if original != nil {
                CommandLiteralEditor(text: $draft, textColor: NSColor(chrome.text), backgroundColor: NSColor(chrome.background),
                                     identifier: "files.preview.editor", editor: editor)
                    .disabled(isSaving)
            } else if error == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error { Text(verbatim: error).foregroundStyle(chrome.danger).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSaving)
                Button("Save", action: save).keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(original == nil || isSaving)
            }
        }
        .padding().frame(width: SheetLayout.commandEditor, height: SheetLayout.commandEditorHeight)
        .background(chrome.background).foregroundStyle(chrome.text)
        .interactiveDismissDisabled(isSaving || (original != nil && draft != original?.text))
        .task {
            do {
                let decoded = try await column.textForEditing(source)
                draft = decoded.text
                original = decoded
            } catch { self.error = error.localizedDescription }
        }
    }

    private func save() {
        guard !isSaving, let original else { return }
        // 输入法的末尾组词可能仍留在 NSTextView，保存当前可见的完整文字。
        editor.unmarkText()
        let text = editor.string
        guard text != original.text else { dismiss(); return }
        isSaving = true
        error = nil
        Task {
            do {
                try await column.saveEditedText(text, original: original, source: source)
                dismiss()
            } catch { self.error = error.localizedDescription }
            isSaving = false
        }
    }
}
