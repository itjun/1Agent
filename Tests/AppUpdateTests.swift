import CryptoKit
import Foundation

@main
enum AppUpdateTests {
    struct Failure: Error { let message: String }

    static func main() {
        do { try run() }
        catch {
            fputs("AppUpdateTests failed: \(error)\n", stderr)
            exit(1)
        }
        print("AppUpdateTests passed")
    }

    static func run() throws {
        let parsed: [(String, String, Bool, Bool)] = [
            ("v1.0.3", "v1.0.3", false, true),
            ("1.0.3", "v1.0.3", false, true),
            ("v1.0.3-rc1", "v1.0.3-rc1", false, true),
            ("v1.0.3-5-gabc1234", "v1.0.3", true, true),
            ("v1.0.3-5-gabc1234-dirty", "v1.0.3", true, true),
            ("开发构建", "", true, false),
            ("abc1234", "", true, false),
        ]
        for item in parsed {
            let got = AppVersionParser.parseCurrent(item.0)
            try check(got.base == item.1 && got.dev == item.2 && got.ok == item.3, "ParseCurrent(\(item.0))")
        }

        let manifest = AppUpdateManifest(version: "v1.2.0", minSupportedVersion: "v1.1.0")
        let decisions: [(String, Bool, Bool, Bool)] = [
            ("v1.2.0", false, false, false),
            ("v1.3.0", false, false, false),
            ("v1.1.5", false, true, false),
            ("v1.1.0", false, true, false),
            ("v1.0.9", false, true, true),
            ("v1.1.0-rc1", false, true, true),
            ("v1.0.9", true, true, false),
        ]
        for item in decisions {
            let got = AppVersionParser.evaluate(current: item.0, dev: item.1, manifest: manifest)
            try check(got.hasUpdate == item.2 && got.mandatory == item.3, "Evaluate(\(item.0), dev: \(item.1))")
        }
        let optional = AppVersionParser.evaluate(current: "v1.0.0", dev: false, manifest: AppUpdateManifest(version: "v1.2.0"))
        try check(optional.hasUpdate && !optional.mandatory, "No minimum version stays optional")

        let invalid = AppUpdateManifest(version: "v1.0.0", minSupportedVersion: "v1.1.0")
        if case .success = invalid.validated() { try check(false, "Minimum above release must fail") }
        let prefixed = AppUpdateManifest(version: "1.2.0", minSupportedVersion: "1.0.0", assets: [
            "darwin-arm64": AppUpdateAsset(name: "a.zip", url: "https://example.com/a.zip", sha256: String(repeating: "a", count: 64), size: 1),
        ])
        switch prefixed.validated() {
        case .success(let value):
            try check(value.version == "v1.2.0" && value.minSupportedVersion == "v1.0.0", "Versions gain a v prefix")
        case .failure:
            try check(false, "Valid manifest should pass")
        }

        try check(AppVersionParser.platformKey() == "darwin-arm64" || AppVersionParser.platformKey().isEmpty, "Platform key is arm64 or unsupported")
        try check(AppUpdateFiles.assetFileName(AppUpdateAsset(name: "../../etc/passwd", url: "", sha256: "", size: 0)) == "passwd", "Asset name keeps the last path piece")
        try check(AppUpdateFiles.assetFileName(AppUpdateAsset(name: ".hidden", url: "", sha256: "", size: 0)) == nil, "Hidden names are rejected")

        let now = Date(timeIntervalSince1970: 1_000_000)
        try check(AppVersionParser.shouldPrompt(hasUpdate: true, mandatory: true, autoCheck: false, latest: "v2", skipped: "v2", remindVersion: "", remindAfter: nil, now: now), "Required updates still prompt")
        try check(!AppVersionParser.shouldPrompt(hasUpdate: true, mandatory: false, autoCheck: false, latest: "v2", skipped: "", remindVersion: "", remindAfter: nil, now: now), "Optional updates stay quiet when automatic checks are off")
        try check(!AppVersionParser.shouldPrompt(hasUpdate: true, mandatory: false, autoCheck: true, latest: "v2", skipped: "v2", remindVersion: "", remindAfter: nil, now: now), "A skipped version stays quiet")
        try check(!AppVersionParser.shouldPrompt(hasUpdate: true, mandatory: false, autoCheck: true, latest: "v2", skipped: "", remindVersion: "v2", remindAfter: now.addingTimeInterval(10), now: now), "A reminder still inside 24 hours stays quiet")
        try check(AppVersionParser.shouldPrompt(hasUpdate: true, mandatory: false, autoCheck: true, latest: "v2", skipped: "", remindVersion: "v2", remindAfter: now.addingTimeInterval(-10), now: now), "An expired reminder prompts again")

        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let body = Data("{\"version\":\"v1.2.0\"}".utf8)
        let signature = try key.signature(for: body).base64EncodedString().data(using: .utf8)!
        try check(AppUpdateCrypto.verify(publicKey: publicKey, data: body, signatureText: signature) == nil, "A matching signature is accepted")
        let other = Curve25519.Signing.PrivateKey()
        let wrong = try other.signature(for: body).base64EncodedString().data(using: .utf8)!
        try check(AppUpdateCrypto.verify(publicKey: publicKey, data: body, signatureText: wrong) == .badSignature, "A foreign signature is rejected")
        guard let stored = Data(base64Encoded: AppUpdate.publicKey), stored.count == 32 else {
            try check(false, "The built-in public key must be 32 bytes")
            return
        }
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
}
