import AppKit
import SwiftUI

/// A read-only preview in a full-height drawer beside its source file column.
struct TextPreviewDrawer: View {
    @ObservedObject var column: FileColumn
    var onClose: (() -> Void)? = nil
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
            .onExitCommand(perform: close)
            .onChange(of: preview.entry.path) { _, _ in
                convertError = nil
                backupPath = nil
                showingFormat = false
            }

        }
    }

    private func close() {
        if let onClose { onClose() } else { column.preview = nil }
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
            Button(action: close) { Image(systemName: "xmark") }
                .help("Close Preview").accessibilityLabel(Text("Close Preview"))
                .accessibilityIdentifier("files.preview.close")
                .keyboardShortcut(.cancelAction)
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
            NativeTextPreview(text: decoded.text, path: preview.entry.path, findRequest: findRequest, onClose: close)
        } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
    }

    private func readingPicker() -> some View {
        FamilyPicker(value: Binding(
            get: { column.readingEncoding }, set: { column.reloadPreview(using: $0) }
        ), options: [(Optional<TextFile.Encoding>.none, String(localized: "Automatic"))] +
            TextFile.Encoding.allCases.map { (Optional($0), $0.label) })
            .frame(width: 180)
            .accessibilityLabel(Text("Reading Encoding"))
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
                VStack(alignment: .leading, spacing: 4) {
                    Text("Output Encoding")
                    FamilyPicker(value: $outputEncoding, options: TextFile.Encoding.allCases.map { ($0, $0.label) })
                        .accessibilityLabel(Text("Output Encoding"))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Output Line Endings")
                    FamilyPicker(value: $outputEnding, options: [(Optional<TextFile.LineEnding>.none, String(localized: "Keep Original"))] +
                        [TextFile.LineEnding.lf, .crlf, .cr].map { (Optional($0), $0.label) })
                        .accessibilityLabel(Text("Output Line Endings"))
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
