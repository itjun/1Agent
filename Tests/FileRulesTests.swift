import Foundation

@main
enum FileRulesTests {
    static func main() {
        expect(FileRules.normalize("/a//b/./c/") == "/a/b/c", "normalize")
        expect(FileRules.normalize("/a/../..") == "/", "nothing above the root")
        expect(FileRules.parent(of: "/a/b") == "/a", "parent")
        expect(FileRules.parent(of: "/") == "/", "parent of the root")

        expect(FileRules.deleteRefusal("/", remote: true, home: nil) != nil, "root is refused")
        expect(FileRules.deleteRefusal("/etc", remote: true, home: nil) != nil, "remote /etc is refused")
        expect(FileRules.deleteRefusal("/etc/nginx", remote: true, home: nil) == nil, "below /etc is allowed")
        expect(FileRules.deleteRefusal("/Users/me", remote: false, home: "/Users/me/") != nil, "local home is refused")
        expect(FileRules.deleteRefusal("/Applications", remote: false, home: nil) != nil, "local /Applications is refused")
        expect(FileRules.deleteRefusal("/srv", remote: true, home: nil) == nil, "/srv is allowed")

        expect(FileRules.numberedName("a.txt", 1) == "a 1.txt", "numbered with extension")
        expect(FileRules.numberedName("Makefile", 2) == "Makefile 2", "numbered without extension")
        expect(FileRules.numberedName(".env", 1) == ".env 1", "a dot file has no extension")

        let renamed = FileRules.targetNames(for: ["a.txt", "a.txt", "b"], existing: ["a.txt", "a 1.txt"], choice: .rename)
        expect(renamed.map(\.name) == ["a 2.txt", "a 3.txt", "b"], "rename skips taken names and the batch's own")
        expect(renamed.allSatisfy { !$0.replace }, "rename never replaces")
        let overwritten = FileRules.targetNames(for: ["a.txt", "b"], existing: ["a.txt"], choice: .overwrite)
        expect(overwritten.map(\.replace) == [true, false], "overwrite replaces only what exists")
        let kept = FileRules.targetNames(for: ["a.txt", "b"], existing: ["a.txt", "b"], choice: .overwrite, keep: ["a.txt"])
        expect(kept.map(\.name) == ["a 1.txt", "b"] && kept.map(\.replace) == [false, true], "kept names are never replaced")

        let holder = FileRules.protectedNames(["x"], sources: ["/srv/x/y/x"], into: "/srv")
        expect(holder == ["x"], "a folder holding the source is never replaced")
        expect(FileRules.protectedNames(["a.png"], sources: ["/tmp/a/a.png"], into: "/tmp/b").isEmpty, "another folder may replace")
        expect(FileRules.protectedNames(["ab"], sources: ["/tmp/a/b"], into: "/tmp").isEmpty, "a prefix is not a parent")
        expect(FileRules.sameSideRefusal(sources: [("/srv/x", true)], into: "/srv/x/sub") != nil, "folder into its subfolder")
        expect(FileRules.sameSideRefusal(sources: [("/srv/x", true)], into: "/srv/x") != nil, "folder into itself")
        expect(FileRules.sameSideRefusal(sources: [("/srv/x", true)], into: "/srv/") != nil, "folder into its own folder")
        expect(FileRules.sameSideRefusal(sources: [("/tmp/dz/a.png", false)], into: "/tmp/dz") != nil, "file into its own folder")
        expect(FileRules.sameSideRefusal(sources: [("/srv/x", true)], into: "/") == nil, "folder into another folder")
        expect(FileRules.sameSideRefusal(sources: [("/srv/x/y", false)], into: "/srv") == nil, "file into another folder")

        expect(FileRules.shellQuote("it's") == "'it'\\''s'", "single quote")

        let find = "d\td\t4096\tdrwxr-xr-x\t1700000000.5\tsrc\0f\tf\t12\t-rw-r--r--\t1700000000\ta b.txt\0l\td\t7\tlrwxrwxrwx\t1700000000\tlink\0"
        let found = FileRules.parseFind(find, in: "/home/me")
        expect(found.count == 3, "find rows")
        expect(found[0].isDirectory && found[0].path == "/home/me/src", "find folder")
        expect(found[1].name == "a b.txt" && found[1].size == 12, "find file with a space")
        expect(found[2].isDirectory, "a link to a folder is a folder")

        let ls = """
        total 8
        drwxr-xr-x    2 root     root          4096 Jan  3 12:30 conf.d
        -rw-r--r--    1 root     root           120 Mar  1  2023 my file.conf
        lrwxrwxrwx    1 root     root             4 Jan  3 12:30 cur -> v1/
        """
        let listed = FileRules.parseLs(ls, in: "/etc", now: Date(timeIntervalSince1970: 1_750_000_000))
        expect(listed.count == 3, "ls rows")
        expect(listed[0].isDirectory && listed[0].name == "conf.d", "ls folder")
        expect(listed[1].name == "my file.conf" && listed[1].size == 120, "ls file with a space")
        expect(listed[2].name == "cur" && listed[2].isDirectory, "ls link to a folder")
        print("ok")
    }

    static func expect(_ condition: Bool, _ message: String) {
        if !condition { fail(message) }
    }

    static func fail(_ message: String) -> Never {
        fputs("FAIL \(message)\n", stderr)
        exit(1)
    }
}
