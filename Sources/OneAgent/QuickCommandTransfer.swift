import AppKit
import Foundation

/// Only portable content crosses the clipboard. Host/path bindings and identity never do.
struct QuickCommandTransfer: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var alias: String
        var command: String
        var group: String

        func validatedCommand() throws -> QuickCommand {
            try QuickCommand(alias: alias, command: command, group: group, scope: .local).validated()
        }
    }
    var version = 1
    var entries: [Entry]

    init(commands: [QuickCommand]) throws {
        entries = commands.map { Entry(alias: $0.alias, command: $0.command, group: $0.group) }
        try validate()
    }
    private func validate() throws {
        guard version == 1 else { throw QuickCommandError.unsupportedVersion }
        guard !entries.isEmpty, entries.count <= 10_000 else { throw QuickCommandError.invalidBackup }
        for entry in entries { _ = try entry.validatedCommand() }
    }
    func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= 32 * 1024 * 1024 else { throw QuickCommandError.invalidBackup }
        return data
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 32 * 1024 * 1024 else { throw QuickCommandError.invalidBackup }
        let transfer = try JSONDecoder().decode(Self.self, from: data)
        try transfer.validate()
        return transfer
    }
    var plainText: String { entries.map(\.command).joined(separator: "\n") }
}

/// Captures the target and new identities once, before presenting the paste dialog.
struct QuickCommandPasteRequest: Identifiable {
    let id = UUID()
    let context: QuickCommandContext
    let drafts: [QuickCommand]

    init(transfer: QuickCommandTransfer, context: QuickCommandContext) throws {
        _ = try transfer.encoded()
        self.context = context
        drafts = try transfer.entries.map { try $0.validatedCommand() }
    }

    func copies(existing: [QuickCommand], directory: String? = nil,
                includesSubdirectories: Bool = false) throws -> [QuickCommand] {
        let scope: QuickCommandScope = directory != nil ? .directory : context.host == nil ? .local : .host
        if let directory, !QuickCommand.validPath(directory) { throw QuickCommandError.invalidDirectory }
        let normalized = directory.map(QuickCommand.path)
        var occupied = Set(existing.filter {
            $0.scope == scope && $0.host == context.host && $0.directory.map(QuickCommand.path) == normalized
        }.map(\.alias))
        let maximum = max(-1, existing.map(\.order).max() ?? -1)
        guard maximum <= Int.max - drafts.count else { throw QuickCommandError.invalidBackup }
        return try drafts.enumerated().map { offset, draft in
            var copy = draft
            var candidate = copy.alias
            var number = 1
            while occupied.contains(candidate) {
                let suffix = number == 1 ? String(localized: " (Copy)")
                    : String(format: String(localized: " (Copy %lld)"), Int64(number))
                candidate = String(copy.alias.prefix(max(0, 200 - suffix.count))) + suffix
                number += 1
            }
            occupied.insert(candidate)
            copy.alias = candidate
            copy.scope = scope
            copy.host = context.host
            copy.directory = normalized
            copy.includesSubdirectories = directory != nil && includesSubdirectories
            copy.order = maximum + offset + 1
            copy.updatedAt = Date()
            return try copy.validated()
        }
    }
}

@MainActor
enum QuickCommandClipboard {
    static let type = NSPasteboard.PasteboardType("com.itjun.1agent.quick-command-transfer")

    static func copy(_ commands: [QuickCommand], to pasteboard: NSPasteboard = .general) throws {
        let transfer = try QuickCommandTransfer(commands: commands)
        let data = try transfer.encoded()
        let item = NSPasteboardItem()
        item.setData(data, forType: type)
        item.setString(transfer.plainText, forType: .string)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw QuickCommandTransferError.clipboardUnavailable }
    }
    static func read(from pasteboard: NSPasteboard = .general) throws -> QuickCommandTransfer {
        guard let data = pasteboard.data(forType: type) else { throw QuickCommandTransferError.noCommands }
        return try QuickCommandTransfer.decode(data)
    }
}

enum QuickCommandTransferError: LocalizedError {
    case noCommands, clipboardUnavailable
    var errorDescription: String? {
        switch self {
        case .noCommands: String(localized: "Copy quick commands before pasting them here.")
        case .clipboardUnavailable: String(localized: "Could not copy quick commands. Please try again.")
        }
    }
}
