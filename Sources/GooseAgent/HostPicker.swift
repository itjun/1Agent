import AppKit
import SwiftUI

/// ⌘T. Type to filter, ↑↓ to move, ⏎ to open. ⌘-click (or the checkbox) ticks several hosts;
/// ⏎ then opens all of them as one workspace. Hosts are grouped by the `config.d` file they came from.
struct HostPicker: View {
    @Environment(\.windowChrome) private var chrome
    @ObservedObject var model: AppModel
    var window: WindowState
    @State private var query = ""
    @State private var highlighted: String?
    @State private var ticked: [String] = []
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

    private var orderedAliases: [String] {
        filtered.map(\.alias)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Open a Terminal")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(chrome.text)
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .padding(.bottom, 12)

            Button {
                model.openLocalTerminal(in: window)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local Terminal")
                        .font(Theme.sidebarRowTitle)
                        .foregroundStyle(chrome.text)
                    Text(LocalTerminal.homeDirectory)
                        .font(Theme.sidebarRowMeta)
                        .foregroundStyle(chrome.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            Rectangle()
                .fill(chrome.hairline)
                .frame(height: 1)
                .padding(.horizontal, 28)
                .padding(.bottom, 12)

            TextField("Search hosts", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .padding(.horizontal, 28)
                .padding(.bottom, 12)
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

            if model.configFailed {
                Text("Could not read SSH config.")
                    .font(Theme.sidebarRowMeta)
                    .foregroundStyle(chrome.secondary)
                    .padding(.horizontal, 28)
                Spacer()
            } else if filtered.isEmpty {
                Group {
                    if model.hosts.isEmpty {
                        Text("SSH config has no hosts to connect to.")
                    } else {
                        Text("No matching hosts")
                    }
                }
                .font(Theme.sidebarRowMeta)
                .foregroundStyle(chrome.secondary)
                .padding(.horizontal, 28)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(sections) { section in
                                if !section.title.isEmpty {
                                    Text(section.title)
                                        .font(Theme.sidebarRowMeta)
                                        .foregroundStyle(chrome.secondary)
                                        .padding(.horizontal, 12)
                                        .padding(.top, 10)
                                        .padding(.bottom, 2)
                                }
                                ForEach(section.hosts) { host in
                                    hostRow(host)
                                        .id(host.alias)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                    }
                    .onChange(of: highlighted) { _, alias in
                        guard let alias else { return }
                        proxy.scrollTo(alias, anchor: .center)
                    }
                }
            }
            HStack(spacing: 12) {
                Text(hintText)
                    .font(Theme.sidebarRowMeta)
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
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(chrome.background)
        .onAppear {
            highlighted = orderedAliases.first
        }
    }

    private var hintText: String {
        if ticked.count >= 2 {
            return String(localized: "⏎ opens the ticked hosts together. ⌘-click to tick more.")
        }
        return String(localized: "↑↓ to move, ⏎ to open, ⌘-click to tick several.")
    }

    private func hostRow(_ host: SSHHost) -> some View {
        let isHighlighted = highlighted == host.alias
        let isTicked = ticked.contains(host.alias)
        let openCount = model.openSessionCount(alias: host.alias)
        return HStack(spacing: 10) {
            Button {
                toggleTick(host.alias)
            } label: {
                Image(systemName: isTicked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(isTicked ? chrome.accent : chrome.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Tick host"))
            VStack(alignment: .leading, spacing: 2) {
                Text(host.alias)
                    .font(Theme.sidebarRowTitle)
                    .foregroundStyle(chrome.text)
                if !host.subtitle.isEmpty {
                    Text(host.subtitle)
                        .font(Theme.sidebarRowMeta)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHighlighted ? chrome.accent.opacity(0.16) : Color.clear)
        )
        .contentShape(Rectangle())
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
            return
        }
        var next = index + delta
        if next < 0 {
            next = aliases.count - 1
        } else if next >= aliases.count {
            next = 0
        }
        highlighted = aliases[next]
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
