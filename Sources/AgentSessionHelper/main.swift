import Darwin
import Foundation

// A synchronous, short-lived supervisor in the terminal's foreground process group.
// It exits with the CLI and is never a background service.
private var receivedSignal: Int32 = 0
private func noteSignal(_ value: Int32) { receivedSignal = value }

private let environment = ProcessInfo.processInfo.environment
private let arguments = Array(CommandLine.arguments.dropFirst())
private let statePath = environment["ONEAGENT_AGENT_STATE"] ?? ""

private func validStatePath() -> Bool {
    let folder = (statePath as NSString).deletingLastPathComponent
    var info = stat()
    return statePath.hasPrefix("/tmp/1a-agent-\(getuid())-") && (statePath as NSString).lastPathComponent == "invocation.json"
        && lstat(folder, &info) == 0 && info.st_uid == getuid() && info.st_mode & 0o777 == 0o700
        && info.st_mode & S_IFMT == S_IFDIR
}

private func execDirect(_ executable: String, _ args: [String]) -> Never {
    var argv = ([executable] + args).map { strdup($0) } + [nil]
    execv(executable, &argv)
    fputs("1Agent: \(executable): \(String(cString: strerror(errno)))\n", stderr)
    exit(127)
}

private func spawn(_ executable: String, _ args: [String], env: [String: String]) -> pid_t? {
    var argv = ([executable] + args).map { strdup($0) } + [nil]
    var envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    var signals = sigset_t()
    sigemptyset(&signals)
    for value in [SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGPIPE] { sigaddset(&signals, value) }
    posix_spawnattr_setsigdefault(&attr, &signals)
    var mask = sigset_t(); sigemptyset(&mask)
    posix_spawnattr_setsigmask(&attr, &mask)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
    var pid: pid_t = 0
    guard posix_spawn(&pid, executable, nil, &attr, &argv, &envp) == 0 else { return nil }
    return pid
}

private func supportsPrivateCodex(_ executable: String) -> Bool {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = ["--help"]
    process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return false }
    let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: timeout)
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit(); timeout.cancel()
    return String(decoding: data, as: UTF8.self).contains("--no-daemon")
}

private func saveConversation(_ conversation: AgentConversation, invocation: AgentInvocation) {
    guard conversation.isValid else { return }
    // Each event belongs to this invocation; late events from an old run cannot replace a new one.
    let file = (statePath as NSString).deletingLastPathComponent + "/" + invocation.invocationID.uuidString + ".json"
    try? AgentSessionFiles.write(conversation, at: file)
}

private func conversationFile(_ invocation: AgentInvocation) -> String {
    (statePath as NSString).deletingLastPathComponent + "/" + invocation.invocationID.uuidString + ".json"
}

private func claudeArguments(_ args: [String]) -> [String]? {
    var result: [String] = [], settings: [String: Any] = [:], index = 0
    while index < args.count {
        let word = args[index]
        let value: String?
        if word == "--settings", index + 1 < args.count { value = args[index + 1]; index += 2 }
        else if word.hasPrefix("--settings=") { value = String(word.dropFirst(11)); index += 1 }
        else { result.append(word); index += 1; continue }
        guard let value else { return nil }
        let data = value.hasPrefix("{") ? value.data(using: .utf8) : try? Data(contentsOf: URL(fileURLWithPath: value))
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        settings = object
    }
    var hooks = settings["hooks"] as? [String: Any] ?? [:]
    var starts = hooks["SessionStart"] as? [[String: Any]] ?? []
    starts.append(["hooks": [["type": "command", "command": AgentLaunchPolicy.quote(CommandLine.arguments[0]) + " record", "timeout": 3]]])
    hooks["SessionStart"] = starts; settings["hooks"] = hooks
    guard let data = try? JSONSerialization.data(withJSONObject: settings), let json = String(data: data, encoding: .utf8) else { return nil }
    return ["--settings", json] + result
}

private func discover(_ invocation: AgentInvocation, child: pid_t, cwd: String, env: [String: String]) -> AgentConversation? {
    let pids = AgentProcessInspection.descendants(of: child)
    let storage = env.filter { AgentConversation.storageKeys.contains($0.key) }
    if invocation.kind == .codex {
        // Only inspect the CLI itself, not its tools/subagents, which own different conversations.
        let paths = AgentProcessInspection.openPaths(of: child)
        let ids = AgentProcessInspection.codexSessionIDs(paths: paths)
        guard ids.count == 1, let id = ids.first, let directory = AgentProcessInspection.codexDirectory(id: id, paths: paths) else { return nil }
        return AgentConversation(kind: .codex, sessionID: id, directory: directory, executable: invocation.executable, storageEnvironment: storage)
    }
    if invocation.kind == .grok {
        let home = env["GROK_HOME"] ?? (env["HOME"] ?? NSHomeDirectory()) + "/.grok"
        struct Entry: Decodable { var session_id: String; var pid: Int32; var cwd: String; var opened_at: String }
        guard let entries = AgentSessionFiles.read([Entry].self, at: home + "/active_sessions.json") else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let owned = entries.filter { entry in
            guard pids.contains(entry.pid), UUID(uuidString: entry.session_id) != nil,
                  let started = AgentProcessInspection.startDate(of: entry.pid) else { return false }
            let opened = formatter.date(from: entry.opened_at) ?? ISO8601DateFormatter().date(from: entry.opened_at)
            return opened.map { $0.timeIntervalSince(started) >= -1 } ?? false
        }
        guard owned.count == 1, let entry = owned.first else { return nil }
        return AgentConversation(kind: .grok, sessionID: entry.session_id, directory: entry.cwd, executable: invocation.executable, storageEnvironment: storage)
    }
    return nil
}

private func recordHook() {
    guard validStatePath(), let invocation = AgentSessionFiles.read(AgentInvocation.self, at: statePath),
          invocation.kind == .claude, environment["ONEAGENT_AGENT_INVOCATION"] == invocation.invocationID.uuidString,
          let data = try? FileHandle.standardInput.read(upToCount: 65_536),
          let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          body["hook_event_name"] as? String == "SessionStart", let id = body["session_id"] as? String,
          let cwd = body["cwd"] as? String else { return }
    let storage = environment.filter { AgentConversation.storageKeys.contains($0.key) }
    saveConversation(AgentConversation(kind: .claude, sessionID: id, sessionFile: body["transcript_path"] as? String,
                                      directory: cwd, executable: invocation.executable, storageEnvironment: storage), invocation: invocation)
}

private func run(kind: AgentConversation.Kind, executable: String, args: [String], resumed: AgentConversation? = nil) -> Never {
    let foreground = tcgetpgrp(STDIN_FILENO)
    if foreground > 0 && foreground != getpgrp() { execDirect(executable, args) }
    guard validStatePath(), AgentLaunchPolicy.tracks(kind, arguments: args) else { execDirect(executable, args) }
    var invocation = AgentInvocation(invocationID: UUID(), ownerPID: getpid(), kind: kind, executable: executable,
                                     phase: .active, conversation: resumed)
    do { try AgentSessionFiles.write(invocation, at: statePath) } catch { execDirect(executable, args) }
    var env = environment
    if let resumed {
        for (key, value) in resumed.storageEnvironment where AgentConversation.storageKeys.contains(key) { env[key] = value }
    }
    env["ONEAGENT_AGENT_INVOCATION"] = invocation.invocationID.uuidString
    env["ONEAGENT_AGENT_KIND"] = kind.rawValue
    env["ONEAGENT_AGENT_EXECUTABLE"] = executable
    var childArgs = args
    let resources = environment["ONEAGENT_AGENT_RESOURCES"] ?? ""
    if kind == .pi || kind == .omp {
        let adapter = resources + "/session-extension.mjs"
        if FileManager.default.fileExists(atPath: adapter) { childArgs = ["--extension", adapter] + childArgs }
    }
    if kind == .claude {
        guard let adapted = claudeArguments(childArgs) else {
            invocation.phase = .ended; try? AgentSessionFiles.write(invocation, at: statePath)
            execDirect(executable, args)
        }
        childArgs = adapted
    }
    // Current Codex can keep model work on a shared daemon after the TUI exits. This terminal
    // deliberately owns its server so closing 1Agent stops its work and permits exact PID binding.
    if kind == .codex, !childArgs.contains("--no-daemon"), supportsPrivateCodex(executable) { childArgs = ["--no-daemon"] + childArgs }
    signal(SIGINT, SIG_IGN); signal(SIGQUIT, SIG_IGN)
    signal(SIGTERM, noteSignal); signal(SIGHUP, noteSignal)
    guard let child = spawn(executable, childArgs, env: env) else {
        invocation.phase = .ended; try? AgentSessionFiles.write(invocation, at: statePath); exit(127)
    }
    let cwd = kind == .codex ? AgentLaunchPolicy.directory(arguments: args, defaultDirectory: FileManager.default.currentDirectoryPath)
        : FileManager.default.currentDirectoryPath
    var status: Int32 = 0, stopAt: Date?, stoppingPIDs: Set<pid_t> = []
    while true {
        if (kind == .codex || kind == .grok) && receivedSignal == 0 {
            let found = discover(invocation, child: child, cwd: cwd, env: env)
            if let found { saveConversation(found, invocation: invocation) }
            else { try? FileManager.default.removeItem(atPath: conversationFile(invocation)) }
            if invocation.conversation != found {
                invocation.conversation = found; try? AgentSessionFiles.write(invocation, at: statePath)
            }
        }
        if receivedSignal != 0, stopAt == nil {
            stopAt = Date(); stoppingPIDs = AgentProcessInspection.descendants(of: child)
            // Let the CLI cancel and flush its transcript before touching its tools or the PTY.
            kill(child, SIGTERM)
        }
        let result = waitpid(child, &status, WNOHANG)
        if result == child || (result < 0 && errno != EINTR) { break }
        if let stopAt, Date().timeIntervalSince(stopAt) > 2.5 {
            stoppingPIDs.formUnion(AgentProcessInspection.descendants(of: child))
            for pid in stoppingPIDs { kill(pid, SIGKILL) }
            _ = waitpid(child, &status, 0); break
        }
        usleep(150_000)
    }
    if let saved = AgentSessionFiles.read(AgentConversation.self, at: conversationFile(invocation)), saved.isValid {
        invocation.conversation = saved
    }
    if receivedSignal != 0 {
        // Reap only descendants of this invocation; never kill a shared Grok leader.
        for pid in stoppingPIDs where pid != child { kill(pid, SIGTERM) }
        invocation.phase = .suspended
    } else { invocation.phase = .ended }
    try? AgentSessionFiles.write(invocation, at: statePath)
    exit((status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
}

if arguments.first == "record" { recordHook(); exit(0) }
if arguments.first == "resume", arguments.count == 2,
   let conversation = AgentSessionFiles.read(AgentConversation.self, at: arguments[1]), conversation.isValid {
    let missing = !FileManager.default.isExecutableFile(atPath: conversation.executable)
        || ((conversation.kind == .pi || conversation.kind == .omp) && !FileManager.default.fileExists(atPath: conversation.sessionFile ?? ""))
    guard !missing, FileManager.default.changeCurrentDirectoryPath(conversation.directory) else {
        fputs(environment["ONEAGENT_AGENT_RESTORE_ERROR"] ?? "无法恢复 Agent 会话，请检查工具、会话文件和目录。\n", stderr); exit(1)
    }
    for (key, value) in conversation.storageEnvironment where AgentConversation.storageKeys.contains(key) { setenv(key, value, 1) }
    run(kind: conversation.kind, executable: conversation.executable, args: conversation.resumeArguments, resumed: conversation)
}
if arguments.first == "run", arguments.count >= 3, let kind = AgentConversation.Kind(rawValue: arguments[1]) {
    run(kind: kind, executable: arguments[2], args: Array(arguments.dropFirst(3)))
}
exit(64)
