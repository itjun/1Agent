import Foundation

@main
enum SSHConfigTests {
    static func main() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("goose-ssh-config-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let included = root.appendingPathComponent("extra.conf")
        try! """
        Host beta gamma
            HostName beta.internal
            User ops
            Port 2222
        Host *.wild
            User skipped
        """.write(to: included, atomically: true, encoding: .utf8)

        let config = root.appendingPathComponent("config")
        try! """
        # comment
        Include "\(included.path)"
        Host alpha
            HostName alpha.example
            User me
        Host alpha
            HostName ignored.example
            User ignored
        Host quoted
            HostName "name with space"
        Host plain
        Host * !alpha
            Port 2200
        Host *
            User shared
            HostName fallback.example
        """.write(to: config, atomically: true, encoding: .utf8)

        let result = SSHConfig.load(from: config)
        expect(!result.failed, "readable config is not a failure")
        let byAlias = Dictionary(uniqueKeysWithValues: result.hosts.map { ($0.alias, $0) })
        expect(
            result.hosts.map(\.alias) == ["beta", "gamma", "alpha", "quoted", "plain"],
            "alias order \(result.hosts.map(\.alias))"
        )
        expect(byAlias["alpha"]?.hostName == "alpha.example", "first HostName wins")
        expect(byAlias["alpha"]?.user == "me", "first User wins over a later Host *")
        expect(byAlias["alpha"]?.port == nil, "negated wildcard does not give alpha a port")
        expect(byAlias["beta"]?.subtitle == "ops@beta.internal:2222", "subtitle \(byAlias["beta"]?.subtitle ?? "")")
        expect(byAlias["gamma"]?.hostName == "beta.internal", "second alias on the same Host line")
        expect(byAlias["quoted"]?.hostName == "name with space", "quoted hostname")
        expect(byAlias["quoted"]?.user == "shared", "later Host * fills a missing user")
        expect(byAlias["quoted"]?.port == "2200", "later match fills a missing port")
        expect(byAlias["plain"]?.hostName == "fallback.example", "later Host * fills a missing hostname")
        expect(byAlias["plain"]?.port == "2200", "plain picks up the earlier wildcard port")
        expect(byAlias["plain"]?.subtitle == "shared@fallback.example:2200", "plain subtitle \(byAlias["plain"]?.subtitle ?? "")")
        expect(
            byAlias["beta"]?.sessionBadge == "ops@beta · beta.internal:2222",
            "badge \(byAlias["beta"]?.sessionBadge ?? "")"
        )
        expect(byAlias["alpha"]?.sessionBadge == "me@alpha · alpha.example", "alpha badge \(byAlias["alpha"]?.sessionBadge ?? "")")
        expect(!result.hosts.contains { $0.alias.contains("*") }, "wildcard host is not a destination")

        let leading = root.appendingPathComponent("leading.conf")
        try! """
        User shared
        Host only
            HostName only.example
            User mine
        """.write(to: leading, atomically: true, encoding: .utf8)
        let leadingResult = SSHConfig.load(from: leading)
        expect(leadingResult.hosts.first?.user == "shared", "a user before the first Host is the first obtained value")
        expect(leadingResult.hosts.first?.hostName == "only.example", "host name still comes from the Host block")

        let equals = root.appendingPathComponent("equals.conf")
        try! """
        Host eq
        HostName=from-equals
        """.write(to: equals, atomically: true, encoding: .utf8)
        expect(SSHConfig.load(from: equals).hosts.first?.hostName == "from-equals", "Keyword=value form")

        let missing = SSHConfig.load(from: root.appendingPathComponent("missing"))
        expect(missing.failed && missing.hosts.isEmpty, "missing file fails closed")
        print("ok")
    }

    static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            fputs("FAIL \(message)\n", stderr)
            exit(1)
        }
    }
}
