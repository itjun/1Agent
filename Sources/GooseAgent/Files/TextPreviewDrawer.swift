import AppKit
import SwiftUI

/// One independent, read-only preview below both file columns.
struct TextPreviewDrawer: View {
    @ObservedObject var column: FileColumn
    @Environment(\.windowChrome) private var chrome
    @State private var converting = false
    @State private var convertError: String?
    @State private var backupPath: String?
    @State private var showingFormat = false
    @State private var outputEncoding: TextFile.Encoding = .utf8
    @State private var outputEnding: TextFile.LineEnding?
    @State private var findRequest = 0

    var body: some View {
        if let preview = column.preview {
            VStack(spacing: 0) {
                header(preview)
                Divider()
                if showingFormat { formatSheet(preview) }
                else { content(preview) }
                if !preview.isQuickLook && !showingFormat { formatBar(preview.decoded, preview: preview) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(showingFormat ? chrome.panelHeader : chrome.background)
            .onChange(of: preview.entry.path) { _, _ in
                convertError = nil
                backupPath = nil
                showingFormat = false
            }

        }
    }

    private func header(_ preview: FileColumn.Preview) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: preview.isQuickLook ? "eye" : "doc.text")
            Text(verbatim: "\(column.title) · \(preview.entry.path)")
                .font(Theme.Font.body.weight(.medium))
                .lineLimit(1).truncationMode(.middle)
                .help(preview.entry.path)
            Spacer(minLength: 4)
            if !preview.isQuickLook {
                Button { findRequest += 1 } label: { Image(systemName: "magnifyingglass") }
                    .help("Find in Preview")
            }
            Button { column.preview = nil } label: { Image(systemName: "xmark") }
                .help("Close Preview").accessibilityLabel(Text("Close Preview"))
        }
        .buttonStyle(FamilyButtonStyle())
        .foregroundStyle(chrome.text)
        .padding(.horizontal, Theme.Space.m)
        .frame(height: FileBrowserLayout.toolbarHeight)
        .background(chrome.panelHeader)
    }

    @ViewBuilder private func content(_ preview: FileColumn.Preview) -> some View {
        if let error = preview.error {
            Text(verbatim: error).foregroundStyle(chrome.danger)
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(Theme.Space.m)
        } else if preview.isQuickLook {
            if let url = preview.quickLook { FilePreviewPane(url: url) {} }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        } else if let decoded = preview.decoded {
            NativeTextPreview(text: decoded.text, chrome: chrome, findRequest: findRequest)
        } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
    }

    private func readingPicker() -> some View {
        Picker("Reading Encoding", selection: Binding(
            get: { column.readingEncoding }, set: { column.reloadPreview(using: $0) }
        )) {
            Text("Automatic").tag(Optional<TextFile.Encoding>.none)
            ForEach(TextFile.Encoding.allCases, id: \.self) { encoding in
                Text(verbatim: encoding.label).tag(Optional(encoding))
            }
        }.fixedSize()
    }

    private func formatMetadata(_ decoded: TextFile.Decoded?) -> some View {
        HStack(spacing: Theme.Space.m) {
            if let decoded {
                Text(verbatim: decoded.encoding.label + (decoded.isInferred ? " · " + String(localized: "Inferred") : ""))
                Text(String(format: String(localized: "Current Line Endings: %@"), decoded.lineEnding.label))
            }
        }.foregroundStyle(chrome.secondary).fixedSize()
    }

    private func correctButton(_ decoded: TextFile.Decoded?) -> some View {
        Button("Correct Format…") {
            guard let decoded else { return }
            outputEncoding = decoded.encoding
            outputEnding = nil
            convertError = nil
            showingFormat = true
        }.disabled(converting || decoded == nil).fixedSize()
    }

    private func formatBar(_ decoded: TextFile.Decoded?, preview: FileColumn.Preview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.m) {
                    readingPicker()
                    formatMetadata(decoded)
                    Spacer(minLength: 4)
                    correctButton(decoded)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack { readingPicker(); Spacer(); correctButton(decoded) }
                    formatMetadata(decoded)
                }
            }.font(Theme.Font.rowMeta)
            if preview.truncated {
                Text("Preview shows the beginning. Format correction reads the complete file, up to 8 MiB.")
                    .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
            }
            if let backupPath {
                Text(String(format: String(localized: "Backup saved: %@"), backupPath))
                    .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                    .lineLimit(1).truncationMode(.middle).help(backupPath).textSelection(.enabled)
            }
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
        .background(chrome.panelHeader)
    }

    private func formatSheet(_ preview: FileColumn.Preview) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text("Correct Format").font(.headline)
                Spacer()

            }
            HStack(spacing: Theme.Space.m) {
                Picker("Output Encoding", selection: $outputEncoding) {
                    ForEach(TextFile.Encoding.allCases, id: \.self) { Text(verbatim: $0.label).tag($0) }
                }
                Picker("Output Line Endings", selection: $outputEnding) {
                    Text("Keep Original").tag(Optional<TextFile.LineEnding>.none)
                    ForEach([TextFile.LineEnding.lf, .crlf, .cr], id: \.self) { Text(verbatim: $0.label).tag(Optional($0)) }
                }
            }
            Button("Use UTF-8 + LF") { outputEncoding = .utf8; outputEnding = .lf }
                .buttonStyle(.link)
            if let convertError { Text(verbatim: convertError).foregroundStyle(chrome.danger).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { showingFormat = false }.keyboardShortcut(.cancelAction)
                Button(converting ? String(localized: "Converting…") : String(localized: "Save Correction")) { save() }
                    .keyboardShortcut(.defaultAction)
            }.disabled(converting)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity)
        .background(chrome.panelHeader)
    }

    private func save() {
        converting = true
        convertError = nil
        Task {
            do {
                backupPath = try await column.savePreviewFormat(encoding: outputEncoding, lineEnding: outputEnding)
                showingFormat = false
            } catch { convertError = error.localizedDescription }
            converting = false
        }
    }
}

/// AppKit provides fast selection, horizontal scrolling and the native find bar.
private struct NativeTextPreview: NSViewRepresentable {
    let text: String
    let chrome: WindowChrome
    let findRequest: Int
    final class Coordinator { var text = ""; var findRequest = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.findBarPosition = .aboveContent
        let view = NSTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.usesFindBar = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 12, height: 10)
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        view.backgroundColor = NSColor(chrome.background)
        view.textColor = NSColor(chrome.text)
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        if context.coordinator.text != text || view.string != text {
            context.coordinator.text = text
            view.string = text
            view.sizeToFit()
        }
        if context.coordinator.findRequest != findRequest {
            context.coordinator.findRequest = findRequest
            let item = NSMenuItem()
            item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
            view.performFindPanelAction(item)
        }
    }
}

/// A light syntax tint: comments, strings and numbers. Long files are shown plain.
enum TextHighlight {
    static let maxHighlightedLength = 200_000
    /// The drawer redraws on every selection change in its column; the text rarely changes.
    @MainActor private static var cached: (text: String, name: String, chrome: WindowChrome, value: AttributedString)?

    @MainActor
    static func attributed(_ text: String, name: String, chrome: WindowChrome) -> AttributedString {
        if let cached, cached.name == name, cached.chrome == chrome, cached.text == text {
            return cached.value
        }
        let value = highlight(text, name: name, chrome: chrome)
        cached = (text, name, chrome, value)
        return value
    }

    private static func highlight(_ text: String, name: String, chrome: WindowChrome) -> AttributedString {
        var result = AttributedString(text)
        guard text.utf16.count <= maxHighlightedLength else { return result }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let ext = (name as NSString).pathExtension.lowercased()
        let hashComments: Set<String> = [
            "sh", "bash", "zsh", "fish", "py", "rb", "yml", "yaml", "toml", "conf", "cfg", "ini", "env",
            "properties", "pl", "r", "mk", "cmake", "tf", "hcl", "nginx", "service", "dockerignore", "gitignore",
        ]
        let commentPattern = hashComments.contains(ext) || name.lowercased() == "makefile" || name.lowercased() == "dockerfile"
            ? #"(?m)(^|\s)#.*$"#
            : #"(?m)//.*$|/\*[\s\S]*?\*/|<!--[\s\S]*?-->"#
        let rules: [(String, Color)] = [
            (#"\b\d+(\.\d+)?\b"#, chrome.warning),
            (#""(\\.|[^"\\\n])*"|'(\\.|[^'\\\n])*'"#, chrome.success),
            (commentPattern, chrome.secondary),
        ]
        for (pattern, color) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: full) {
                guard let range = Range(match.range, in: text),
                      let lower = AttributedString.Index(range.lowerBound, within: result),
                      let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
                result[lower..<upper].foregroundColor = color
            }
        }
        return result
    }
}
