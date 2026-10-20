import Foundation

/// What a sidebar row and its pane show. Most are terminals; dropped files get panes of their own
/// that sit in the same splits.
enum PaneContent: Equatable {
    case terminal
    /// Quick Look of one local file.
    case preview(path: String)

    var isTerminal: Bool {
        if case .terminal = self {
            return true
        }
        return false
    }
}

/// Where a new pane goes relative to the pane it was opened from.
enum PanePlacement: Equatable {
    case newTab
    case split(SplitEdge)
}

/// Where the Files area starts for one host. With a host it shows this Mac beside the host,
/// without one only this Mac.
struct FileBrowserTarget: Equatable, Codable {
    var host: String?
    var localPath: String
    var remotePath: String?
}

extension TerminalTab {
    /// Sidebar and pane title of a preview pane. Nil for a terminal.
    var contentTitle: String? {
        switch content {
        case .terminal:
            return nil
        case .preview(let path):
            return (path as NSString).lastPathComponent
        }
    }
}
