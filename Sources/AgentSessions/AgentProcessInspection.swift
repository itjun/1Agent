import Darwin
import Foundation
import SQLite3

/// Kernel ownership is the association key. A matching cwd or modification time is insufficient.
enum AgentProcessInspection {
    static func startDate(of pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }
    static func descendants(of root: pid_t) -> Set<pid_t> {
        var result: Set<pid_t> = [root], pending = [root]
        while let parent = pending.popLast(), result.count < 512 {
            let bytes = proc_listchildpids(parent, nil, 0)
            guard bytes > 0 else { continue }
            var children = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.stride + 16)
            let count = children.withUnsafeMutableBytes { proc_listchildpids(parent, $0.baseAddress, Int32($0.count)) }
            for child in children.prefix(max(0, Int(count) / MemoryLayout<pid_t>.stride)) where child > 0 {
                if result.insert(child).inserted { pending.append(child) }
            }
        }
        return result
    }

    static func openPaths(of pid: pid_t) -> [String] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 16)
        let count = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        var paths: [String] = []
        for fd in fds.prefix(max(0, Int(count) / MemoryLayout<proc_fdinfo>.stride)) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            let size = MemoryLayout<vnode_fdinfowithpath>.size
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(size)) == size else { continue }
            let path = withUnsafePointer(to: &info.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            paths.append(path)
        }
        return paths
    }

    static func codexSessionIDs(paths: [String]) -> Set<String> {
        Set(paths.compactMap { path in
            if path.contains("/thread-writer-locks/"), path.hasSuffix(".lock") {
                let id = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                return UUID(uuidString: id) == nil ? nil : id
            }
            if path.hasSuffix(".jsonl"), path.contains("/sessions/"),
               let header = AgentSessionFiles.sessionHeader(at: path) { return header.id }
            return nil
        })
    }

    /// Current Codex writes history to SQLite. An idle, never-used TUI has a writer lock
    /// but no saved conversation, and must not produce a broken resume reference.
    static func codexDirectory(id: String, paths: [String]) -> String? {
        for path in paths where path.hasSuffix(".sqlite") && URL(fileURLWithPath: path).lastPathComponent.hasPrefix("state_") {
            var database: OpaquePointer?
            guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
                if let database { sqlite3_close(database) }; continue
            }
            defer { sqlite3_close(database) }
            sqlite3_busy_timeout(database, 50)
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT cwd FROM threads WHERE id = ? AND has_user_event = 1", -1, &statement, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, id, -1, transient)
            if sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) {
                let cwd = String(cString: value)
                if cwd.hasPrefix("/") { return cwd }
            }
        }
        for path in paths where path.hasSuffix(".jsonl") && path.contains("/sessions/") {
            if let header = AgentSessionFiles.sessionHeader(at: path), header.id == id { return header.cwd }
        }
        return nil
    }
}
