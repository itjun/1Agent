import AppKit
import SwiftUI

/// Read-only text of one file along the bottom of a file column, with its encoding and line
/// ending, and a one-click conversion to UTF-8 + LF that keeps the original as `name.bak`.
/// Other files (images, PDFs, …) show as Quick Look in the same place.
struct TextPreviewDrawer: View {
    @ObservedObject var column: FileColumn
    @Environment(\.windowChrome) private var chrome
    @State private var converting = false
    @State private var convertError: String?

    var body: some View {
        if let preview = column.preview {
            VStack(spacing: 0) {
                Rectangle().fill(chrome.hairline).frame(height: 1)
                header(preview)
                Rectangle().fill(chrome.hairline).frame(height: 1)
                content(preview)
            }
            .background(chrome.sidebarBackground)
            .onChange(of: preview.entry) { _, _ in convertError = nil }
        }
    }

    private func header(_ preview: FileColumn.Preview) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: preview.isQuickLook ? "eye" : "doc.text")
                .foregroundStyle(chrome.secondary)
            Text(verbatim: preview.entry.name)
                .font(Theme.Font.body.weight(.semibold))
                .foregroundStyle(chrome.text)
                .lineLimit(1)
                .truncationMode(.middle)
            if let decoded = preview.decoded {
                badge(decoded.encoding.label)
                badge(decoded.lineEnding.label)
            }
            if preview.truncated {
                Text("Only the beginning is shown")
                    .font(Theme.Font.rowMeta)
                    .foregroundStyle(chrome.secondary)
            }
            Spacer(minLength: Theme.Space.s)
            if let convertError {
                Text(verbatim: convertError)
                    .font(Theme.Font.rowMeta)
                    .foregroundStyle(chrome.danger)
                    .lineLimit(1)
            }
            if let decoded = preview.decoded, !decoded.isUTF8LF {
                Button {
                    convert()
                } label: {
                    Text(converting ? String(localized: "Converting…") : String(localized: "Convert to UTF-8 + LF"))
                        .font(Theme.Font.rowMeta)
                }
                .disabled(converting || preview.truncated)
                .help(String(localized: "The original is kept as a .bak file next to it"))
            }
            Button {
                column.preview = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: FileBrowserLayout.toolbarButtonSize, height: FileBrowserLayout.toolbarButtonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(chrome.secondary)
            .help(String(localized: "Close Preview"))
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: FileBrowserLayout.toolbarHeight)
    }

    private func badge(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(chrome.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(chrome.elevated))
    }

    @ViewBuilder
    private func content(_ preview: FileColumn.Preview) -> some View {
        if let error = preview.error {
            Text(verbatim: error)
                .font(Theme.Font.body)
                .foregroundStyle(chrome.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if preview.isQuickLook {
            if let url = preview.quickLook {
                FilePreviewPane(url: url) {}
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if let decoded = preview.decoded {
            ScrollView([.vertical, .horizontal]) {
                Text(TextHighlight.attributed(decoded.text, name: preview.entry.name, chrome: chrome))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(chrome.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.m)
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func convert() {
        converting = true
        convertError = nil
        Task {
            do {
                try await column.convertPreviewToUTF8LF()
            } catch {
                convertError = error.localizedDescription
            }
            converting = false
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
