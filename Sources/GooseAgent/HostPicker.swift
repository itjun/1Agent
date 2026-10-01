import AppKit
import SwiftUI

/// ⌘T. Type to filter, ↑↓ to move, ⏎ to open. ⌘-click selects several hosts;
/// ⏎ then opens all of them as one workspace. Hosts are grouped by the `config.d` file they came from.
struct HostPicker: View {
    @Environment(\.windowChrome) private var chrome
    @ObservedObject var model: AppModel
    var window: WindowState
    @State private var query = ""
    @State private var highlighted: String?
    /// Set only by ↑↓, so hovering never scrolls the list under the mouse.
    @State private var keyboardTarget: String?
    @State private var ticked: [String] = []
    @State private var localHovered = false
    @FocusState private var searchFocused: Bool

    /// Rows in display order: a header per source group, hosts underneath, config order inside a group.
    private struct Section: Identifiable {
        var id: String { title }
        var title: String
        var hosts: [SSHHost]
    }

    private var filtered: [SSHHost] {
        HostSearch.filter(model.hosts, query: query)
    }

    /// With a query, matches stay in score order under one flat list. Without one, the config
    /// groups are shown with their file names as headers.
    private var sections: [Section] {
        let hosts = filtered
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            return [Section(title: "", hosts: hosts)]
        }
        var order: [String] = []
        var grouped: [String: [SSHHost]] = [:]
        for host in hosts {
            let key = host.source ?? ""
            if grouped[key] == nil {
                order.append(key)
            }
            grouped[key, default: []].append(host)
        }
        return order.map { Section(title: $0, hosts: grouped[$0] ?? []) }
    }

    /// One list entry: a group header or a host row.
    private enum PickerRow: Identifiable {
        case header(String)
        case host(SSHHost)

        var id: String {
            switch self {
            case .header(let title): return "header:\(title)"
            case .host(let host): return "host:\(host.alias)"
            }
        }
    }

    /// `sections` flattened into one list. A single `ForEach` keeps every row's identity stable
    /// when the search text turns the grouped list into a flat one; nested `ForEach`es reused row
    /// views across groups and some rows lost their highlight.
    private var rows: [PickerRow] {
        var rows: [PickerRow] = []
        for section in sections {
            if !section.title.isEmpty {
                rows.append(.header(section.title))
            }
            for host in section.hosts {
                rows.append(.host(host))
            }
        }
        return rows
    }

    private var orderedAliases: [String] {
        filtered.map(\.alias)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
                .padding(Theme.Space.l)

            localTerminalRow
                .padding(.horizontal, Theme.Space.l)

            Rectangle()
                .fill(chrome.hairline)
                .frame(height: 1)
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.s)

            if model.configFailed {
                Text("Could not read SSH config.")
                    .font(Theme.Font.rowMeta)
                    .foregroundStyle(chrome.secondary)
                    .padding(.horizontal, Theme.Space.l + Theme.Space.m)
                    .padding(.top, Theme.Space.s)
                Spacer()
            } else if filtered.isEmpty {
                Group {
                    if model.hosts.isEmpty {
                        Text("SSH config has no hosts to connect to.")
                    } else {
                        Text("No matching hosts")
                    }
                }
                .font(Theme.Font.rowMeta)
                .foregroundStyle(chrome.secondary)
                .padding(.horizontal, Theme.Space.l + Theme.Space.m)
                .padding(.top, Theme.Space.s)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(rows) { row in
                                switch row {
                                case .header(let title):
                                    Text(title)
                                        .font(Theme.Font.sidebarSection)
                                        .foregroundStyle(chrome.secondary)
                                        .padding(.horizontal, Theme.Space.m)
                                        .padding(.top, Theme.Space.m)
                                        .padding(.bottom, Theme.Space.xs)
                                case .host(let host):
                                    hostRow(host)
                                }
                            }
                        }
                        .padding(.horizontal, Theme.Space.l)
                        .padding(.bottom, Theme.Space.l)
                    }
                    .onChange(of: keyboardTarget) { _, alias in
                        guard let alias else { return }
                        proxy.scrollTo("host:\(alias)", anchor: .center)
                    }
                }
            }
            HStack(spacing: Theme.Space.m) {
                Text(hintText)
                    .font(Theme.Font.rowMeta)
                    .foregroundStyle(chrome.secondary)
                    .lineLimit(1)
                Spacer()
                if ticked.count >= 2 {
                    Button(String(format: String(localized: "Open %lld as Workspace"), ticked.count)) {
                        openTicked()
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                }
                Button("Cancel") { window.hostPickerPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
            .background(chrome.sidebarBackground)
            .overlay(alignment: .top) {
                Rectangle().fill(chrome.hairline).frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(chrome.background)
        .onAppear {
            highlighted = orderedAliases.first
        }
    }

    /// Spotlight-style search at the top. Focus, ↑↓, ⏎ and filtering behave exactly as before.
    private var searchField: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(chrome.secondary)
            TextField("Search hosts", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(chrome.text)
                .focused($searchFocused)
                .onAppear { searchFocused = true }
                .onSubmit { openHighlighted() }
                .onKeyPress(.upArrow) {
                    moveHighlight(-1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveHighlight(1)
                    return .handled
                }
                .onChange(of: query) { _, _ in
                    highlighted = orderedAliases.first
                }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(chrome.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(maxWidth: .infinity)
        .frame(height: SheetLayout.searchFieldHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(chrome.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .stroke(chrome.hairline, lineWidth: 1)
        )
    }

    /// Fixed first row. Looks like a host row but stays out of the ↑↓ highlight.
    private var localTerminalRow: some View {
        Button {
            model.openLocalTerminal(in: window)
        } label: {
            HStack(spacing: Theme.Space.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local Terminal")
                        .font(Theme.Font.row.weight(.medium))
                        .foregroundStyle(chrome.text)
                    Text(verbatim: "~")
                        .font(Theme.Font.rowMeta)
                        .foregroundStyle(chrome.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: SheetLayout.pickerRowHeight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(localHovered ? chrome.accentFill : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            localHovered = inside
        }
    }

    private var hintText: String {
        if ticked.count >= 2 {
            return String(localized: "⏎ opens the selected hosts as one workspace. ⌘-click to select more.")
        }
        return String(localized: "↑↓ to move, ⏎ to open, ⌘-click to tick several.")
    }

    private func hostRow(_ host: SSHHost) -> some View {
        let isHighlighted = highlighted == host.alias
        let isTicked = ticked.contains(host.alias)
        let openCount = model.openSessionCount(alias: host.alias)
        return HStack(spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(host.alias)
                    .font(Theme.Font.row.weight(.medium))
                    .foregroundStyle(chrome.text)
                if !host.subtitle.isEmpty {
                    Text(host.subtitle)
                        .font(Theme.Font.rowMeta)
                        .foregroundStyle(chrome.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if openCount > 0 {
                Text(openCount == 1 ? String(localized: "Open") : String(format: String(localized: "Open ×%lld"), openCount))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(chrome.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(chrome.accent.opacity(0.14)))
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: SheetLayout.pickerRowHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(rowFill(highlighted: isHighlighted, ticked: isTicked))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .stroke(isTicked ? chrome.accent : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .accessibilityAddTraits(isTicked ? .isSelected : [])
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                toggleTick(host.alias)
                highlighted = host.alias
            } else {
                model.openHost(host.alias, in: window)
            }
        }
        .onHover { inside in
            if inside {
                highlighted = host.alias
            }
        }
    }

    private func rowFill(highlighted: Bool, ticked: Bool) -> Color {
        if ticked {
            return chrome.accent.opacity(0.18)
        }
        if highlighted {
            return chrome.accentFill
        }
        return Color.clear
    }

    private func toggleTick(_ alias: String) {
        if let index = ticked.firstIndex(of: alias) {
            ticked.remove(at: index)
        } else {
            ticked.append(alias)
        }
    }

    private func moveHighlight(_ delta: Int) {
        let aliases = orderedAliases
        guard !aliases.isEmpty else { return }
        guard let current = highlighted, let index = aliases.firstIndex(of: current) else {
            highlighted = delta > 0 ? aliases.first : aliases.last
            keyboardTarget = highlighted
            return
        }
        var next = index + delta
        if next < 0 {
            next = aliases.count - 1
        } else if next >= aliases.count {
            next = 0
        }
        highlighted = aliases[next]
        keyboardTarget = highlighted
    }

    /// ⏎: the ticked set when there are several, otherwise the highlighted host.
    private func openHighlighted() {
        if ticked.count >= 2 {
            openTicked()
            return
        }
        guard let alias = highlighted ?? orderedAliases.first else { return }
        model.openHost(alias, in: window)
    }

    private func openTicked() {
        let order = model.hosts.map(\.alias)
        let chosen = order.filter { ticked.contains($0) }
        guard !chosen.isEmpty else { return }
        model.openHosts(chosen, in: window)
    }
}
