import SwiftUI
import WebKit
@_implementationOnly import cmark_gfm
@_implementationOnly import cmark_gfm_extensions

/// HTML 和 Markdown 共用只读网页视图。文件中的脚本、表单和网络请求不能执行。
struct DocumentPreview: View {
    let text: String
    let isMarkdown: Bool
    let directory: URL?
    let findRequest: Int
    @StateObject private var reader = DocumentReader()
    @State private var isFinding = false
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if isFinding {
                HStack {
                    TextField("Find", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .focused($isSearchFocused)
                        .onSubmit { reader.find(query) }
                        .onChange(of: query) { _, value in reader.find(value) }
                    Button { reader.find(query, backwards: true) } label: { Image(systemName: "chevron.up") }
                        .accessibilityLabel(Text("Find Previous"))
                    Button { reader.find(query) } label: { Image(systemName: "chevron.down") }
                        .accessibilityLabel(Text("Find Next"))
                    Button(action: closeFind) { Image(systemName: "xmark") }
                        .accessibilityLabel(Text("Hide Find Bar"))
                }
                .buttonStyle(PreviewCardButtonStyle()).padding(6)
                .onExitCommand(perform: closeFind)
            }
            DocumentWebView(reader: reader)
        }
        .task(id: text) {
            let body = isMarkdown ? await DocumentPreview.markdownHTML(text) : text
            guard !Task.isCancelled else { return }
            reader.load(body, directory: directory)
        }
        .onChange(of: findRequest) { _, _ in
            isFinding = true
            isSearchFocused = true
        }
    }

    private func closeFind() {
        query = ""
        reader.find("")
        isFinding = false
    }

    nonisolated static func markdownHTML(_ text: String) async -> String {
        cmark_gfm_core_extensions_ensure_registered()
        let parser = cmark_parser_new(CMARK_OPT_DEFAULT)
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "tasklist", "autolink"] {
            cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension(name))
        }
        cmark_parser_feed(parser, text, text.utf8.count)
        let tree = cmark_parser_finish(parser)
        defer { cmark_node_free(tree) }
        let html = cmark_render_html(tree, CMARK_OPT_DEFAULT, cmark_parser_get_syntax_extensions(parser))!
        defer { free(html) }
        return """
            <meta name="color-scheme" content="dark">
            <style>
            body { background: #000; color: #eee; font: 15px/1.6 -apple-system, sans-serif; margin: 16px; overflow-wrap: anywhere; }
            h1,h2,h3 { line-height: 1.25; } img { max-width: 100%; }
            pre { overflow-x: auto; padding: .7em; background: rgba(128,128,128,.12); }
            code { font-family: ui-monospace, monospace; }
            blockquote { margin-left: 0; padding-left: 1em; border-left: 3px solid #8888; }
            table { border-collapse: collapse; } th,td { border: 1px solid #8888; padding: .3em .6em; }
            </style>
            \(String(cString: html))
            """
    }
}

@MainActor
private final class DocumentReader: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    private var initialURL: URL?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.setAccessibilityIdentifier("files.preview.document")
    }

    func load(_ body: String, directory: URL?) {
        let local = directory == nil ? "" : " file:"
        let policy = "default-src 'none'; style-src 'unsafe-inline'\(local); img-src data:\(local); font-src data:\(local); form-action 'none'; base-uri 'none'"
        let document = "<!doctype html><meta charset=utf-8><meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">" + body
        initialURL = directory ?? URL(string: "about:blank")
        webView.loadHTMLString(document, baseURL: directory)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let isInitial = initialURL != nil && action.request.url == initialURL &&
            action.targetFrame?.isMainFrame == true && action.navigationType == .other
        if isInitial { initialURL = nil }
        decisionHandler(isInitial ? .allow : .cancel)
    }

    func find(_ query: String, backwards: Bool = false) {
        let options = WKFindConfiguration()
        options.backwards = backwards
        options.wraps = true
        webView.find(query, configuration: options) { _ in }
    }
}

private struct DocumentWebView: NSViewRepresentable {
    let reader: DocumentReader
    func makeNSView(context: Context) -> WKWebView { reader.webView }
    func updateNSView(_ webView: WKWebView, context: Context) {}
}
