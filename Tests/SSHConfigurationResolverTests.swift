import Foundation

@main
enum SSHConfigurationResolverTests {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ssh 配置 " + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let included = directory.appendingPathComponent("included.conf")
        try "Host fixture-*\n HostName 192.0.2.10\n Port 2222\nMatch host 192.0.2.10\n User matched-user\n".write(to: included, atomically: true, encoding: .utf8)
        let config = directory.appendingPathComponent("config")
        try "Include \"\(included.path)\"\n".write(to: config, atomically: true, encoding: .utf8)
        let environment = ["PATH=/usr/bin:/bin", "HOME=\(directory.path)", "USER=fixture"]
        let result = try await SSHConfigurationQuery(alias: "fixture-one", environment: environment, configurationFile: config).run()
        precondition(result == ResolvedSSHConfiguration(hostName: "192.0.2.10", user: "matched-user", port: "2222"))
        do {
            _ = try await SSHConfigurationQuery(alias: "fixture-one", environment: environment, configurationFile: config, outputLimit: 32).run()
            fatalError("Output cap did not apply")
        } catch SSHConfigurationError.outputTooLarge {}
        let slow = directory.appendingPathComponent("slow")
        try "Match exec \"/bin/sleep 1\"\n User slow\n".write(to: slow, atomically: true, encoding: .utf8)
        let start = Date()
        do {
            _ = try await SSHConfigurationQuery(alias: "fixture", environment: environment, configurationFile: slow, timeout: 0.05).run()
            fatalError("Timeout did not apply")
        } catch SSHConfigurationError.timedOut {}
        precondition(Date().timeIntervalSince(start) < 0.8)
        let pending = Task { try await SSHConfigurationQuery(alias: "fixture", environment: environment, configurationFile: slow).run() }
        try await Task.sleep(for: .milliseconds(30))
        pending.cancel()
        do { _ = try await pending.value; fatalError("Cancellation ignored") }
        catch is CancellationError {}
        let counter = directory.appendingPathComponent("queries")
        let sharedConfig = directory.appendingPathComponent("shared")
        try "Match exec \"/usr/bin/printf x >> '\(counter.path)'; /bin/sleep 0.2\"\n User shared\n".write(to: sharedConfig, atomically: true, encoding: .utf8)
        let resolver = SSHConfigurationResolver(configurationFile: sharedConfig)
        let first = Task { try await resolver.resolve(alias: "fixture", environment: environment) }
        let second = Task { try await resolver.resolve(alias: "fixture", environment: environment.reversed()) }
        try await Task.sleep(for: .milliseconds(40))
        first.cancel()
        let shared = try await second.value
        precondition(shared.user == "shared", "One cancelled subscriber must not cancel another")
        do { _ = try await first.value; fatalError("Cancelled subscriber returned a value") } catch is CancellationError {}
        let once = try String(contentsOf: counter, encoding: .utf8)
        precondition(once == "x", "Concurrent requests must share one ssh process")
        _ = try await resolver.resolve(alias: "fixture", environment: environment)
        let twice = try String(contentsOf: counter, encoding: .utf8)
        precondition(twice == "xx", "Finished requests must not cache stale configuration")
        print("PASS: system ssh -G handles Include, wildcard, Match and spaced paths; bounds output, times out and cancels")
    }
}
