import CryptoKit
import Foundation

/// 应用内更新。清单格式、验签和版本判定与 1Panel 的 `internal/updater` 一致。
/// 公钥随客户端发布。私钥在发布者本机 `~/.config/1agent-release/update_sign.key`，CI 从 Secret `UPDATE_SIGN_KEY` 读取。
enum AppUpdate {
    static let publicKey = "cVxxNzGpRLlj1jDqpLBs/bZS7/baKVlfzu0T9HZUpas="
    static let defaultBaseURL = "https://github.com/itjun/1Agent/releases/latest/download"
    static let manifestName = "latest.json"
    static let signatureName = "latest.json.sig"
    /// 签名清单失败时，仍从这里读取最新发布的标题和说明。不走 api.github.com，避免未登录的接口限额。
    static let releaseFeedURL = "https://github.com/itjun/1Agent/releases.atom"
    static let notificationKey = "oneagentUpdate"
    static let maxManifestBytes = 1 << 20

    static let firstCheckDelay: TimeInterval = 10
    static let checkInterval: TimeInterval = 6 * 60 * 60
    static let checkJitter: TimeInterval = 10 * 60
    static let remindLater: TimeInterval = 24 * 60 * 60
    static let pokeMinInterval: TimeInterval = 10 * 60
}

enum AppUpdateStatus: String, Equatable {
    case idle
    case checking
    case downloading
    case installing
    case error
}

enum AppUpdateFailure: Equatable, Error {
    case noSource
    case badPublicKey
    case badSignature
    case signatureFormat
    case manifestParse
    case manifestTooLarge
    case badVersion
    case minVersionTooHigh
    case badAssetURL
    case missingChecksum
    case httpStatus(Int)
    case unreachable
    case sizeMismatch
    case checksumMismatch
    case badFileName
    case noDownloadDirectory
    case notAnApp
    case incompleteApp
    case noAppInArchive
    case extractFailed
    case replaceFailed
    case cancelledAdmin
    case adminFailed
    case noAsset
    case alreadyLatest
    case cannotSkip
    case cannotDelay
    case downloadInterrupted
    case unsupportedPlatform
    case incomparableVersion

    var message: String {
        switch self {
        case .noSource:
            String(localized: "This build has no update source.")
        case .badPublicKey:
            String(localized: "This build has no update signing key.")
        case .badSignature:
            String(localized: "The update manifest signature is invalid.")
        case .signatureFormat:
            String(localized: "The update manifest signature is malformed.")
        case .manifestParse:
            String(localized: "The update manifest could not be read.")
        case .manifestTooLarge:
            String(localized: "The update manifest is too large.")
        case .badVersion:
            String(localized: "The update manifest version is invalid.")
        case .minVersionTooHigh:
            String(localized: "The update manifest minimum version is higher than the release.")
        case .badAssetURL:
            String(localized: "The update package address is invalid.")
        case .missingChecksum:
            String(localized: "The update package is missing a checksum.")
        case .httpStatus(let code):
            String(format: String(localized: "The update server returned HTTP %lld."), Int64(code))
        case .unreachable:
            String(localized: "Could not reach the update server.")
        case .sizeMismatch:
            String(localized: "The update package size does not match.")
        case .checksumMismatch:
            String(localized: "The update package checksum does not match.")
        case .badFileName:
            String(localized: "The update package file name is invalid.")
        case .noDownloadDirectory:
            String(localized: "The update download folder is unavailable.")
        case .notAnApp:
            String(localized: "This copy is not running as an app, so it cannot update itself.")
        case .incompleteApp:
            String(localized: "The update package does not contain a complete app.")
        case .noAppInArchive:
            String(localized: "The update package does not contain an app.")
        case .extractFailed:
            String(localized: "The update package could not be extracted.")
        case .replaceFailed:
            String(localized: "The update could not be installed.")
        case .cancelledAdmin:
            String(localized: "Administrator approval was cancelled. The update was not installed.")
        case .adminFailed:
            String(localized: "The update could not be installed with administrator approval.")
        case .noAsset:
            String(localized: "The new version has no package for this Mac.")
        case .alreadyLatest:
            String(localized: "1Agent is up to date.")
        case .cannotSkip:
            String(localized: "A required update cannot be skipped.")
        case .cannotDelay:
            String(localized: "A required update cannot be postponed.")
        case .downloadInterrupted:
            String(localized: "The download was interrupted.")
        case .unsupportedPlatform:
            String(localized: "Automatic updates are not available on this Mac.")
        case .incomparableVersion:
            String(localized: "This build version cannot be compared.")
        }
    }

    var isUnreachable: Bool {
        if case .unreachable = self { return true }
        return false
    }
}

enum AppUpdateCrypto {
    static func verify(publicKey: String, data: Data, signatureText: Data) -> AppUpdateFailure? {
        guard let keyData = Data(base64Encoded: publicKey.trimmingCharacters(in: .whitespacesAndNewlines)),
              keyData.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            return .badPublicKey
        }
        let text = String(data: signatureText, encoding: .utf8) ?? ""
        guard let signature = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              signature.count == 64 else {
            return .signatureFormat
        }
        if key.isValidSignature(signature, for: data) {
            return nil
        }
        return .badSignature
    }
}

struct AppVersion: Equatable {
    var major: String
    var minor: String
    var patch: String
    var prerelease: [String]

    var canonical: String {
        var text = "v\(major).\(minor).\(patch)"
        if !prerelease.isEmpty {
            text += "-" + prerelease.joined(separator: ".")
        }
        return text
    }
}

enum AppVersionParser {
    private static let describeSuffix: NSRegularExpression? = try? NSRegularExpression(pattern: #"-[0-9]+-g[0-9a-f]+$"#)

    static func canonical(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("v") {
            return trimmed
        }
        return "v" + trimmed
    }

    static func parse(_ raw: String) -> AppVersion? {
        var text = canonical(raw)
        guard text.hasPrefix("v") else { return nil }
        text.removeFirst()
        if let plus = text.firstIndex(of: "+") {
            let build = String(text[text.index(after: plus)...])
            if !isValidBuild(build) { return nil }
            text = String(text[..<plus])
        }
        let prerelease: [String]
        if let dash = text.firstIndex(of: "-") {
            guard let parts = prereleaseParts(String(text[text.index(after: dash)...])) else { return nil }
            prerelease = parts
            text = String(text[..<dash])
        } else {
            prerelease = []
        }
        let numbers = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard numbers.count == 3,
              let major = numeric(numbers[0]),
              let minor = numeric(numbers[1]),
              let patch = numeric(numbers[2]) else { return nil }
        return AppVersion(major: major, minor: minor, patch: patch, prerelease: prerelease)
    }

    /// 返回可比较的基础版本。`v1.0.3-5-gabc1234` 这种 git describe 结果算开发构建。
    static func parseCurrent(_ raw: String) -> (base: String, dev: Bool, ok: Bool) {
        var text = canonical(raw)
        var dev = false
        if text.hasSuffix("-dirty") {
            text.removeLast("-dirty".count)
            dev = true
        }
        let range = NSRange(text.startIndex..., in: text)
        if let match = describeSuffix?.firstMatch(in: text, range: range), let hit = Range(match.range, in: text) {
            text.removeSubrange(hit)
            dev = true
        }
        guard let version = parse(text) else { return ("", true, false) }
        return (version.canonical, dev, true)
    }

    /// 大于返回正数，小于返回负数。任一版本非法时返回 nil。
    static func compare(_ lhs: String, _ rhs: String) -> Int? {
        guard let left = parse(lhs), let right = parse(rhs) else { return nil }
        let major = compareNumeric(left.major, right.major)
        if major != 0 { return major }
        let minor = compareNumeric(left.minor, right.minor)
        if minor != 0 { return minor }
        let patch = compareNumeric(left.patch, right.patch)
        if patch != 0 { return patch }
        if left.prerelease.isEmpty && right.prerelease.isEmpty { return 0 }
        if left.prerelease.isEmpty { return 1 }
        if right.prerelease.isEmpty { return -1 }
        let count = min(left.prerelease.count, right.prerelease.count)
        for index in 0..<count {
            let order = compareIdentifier(left.prerelease[index], right.prerelease[index])
            if order != 0 { return order }
        }
        if left.prerelease.count == right.prerelease.count { return 0 }
        if left.prerelease.count < right.prerelease.count { return -1 }
        return 1
    }

    static func evaluate(current: String, dev: Bool, manifest: AppUpdateManifest) -> (hasUpdate: Bool, mandatory: Bool) {
        guard parse(current) != nil, parse(manifest.version) != nil,
              let order = compare(manifest.version, current) else {
            return (false, false)
        }
        let hasUpdate = order > 0
        if !hasUpdate || dev || parse(manifest.minSupportedVersion) == nil {
            return (hasUpdate, false)
        }
        guard let below = compare(current, manifest.minSupportedVersion) else {
            return (hasUpdate, false)
        }
        return (hasUpdate, below < 0)
    }

    static func shouldPrompt(
        hasUpdate: Bool,
        mandatory: Bool,
        autoCheck: Bool,
        latest: String,
        skipped: String,
        remindVersion: String,
        remindAfter: Date?,
        now: Date
    ) -> Bool {
        if !hasUpdate || !autoCheck { return false }
        if mandatory { return true }
        if skipped == latest { return false }
        if remindVersion == latest, let remindAfter, now < remindAfter { return false }
        return true
    }

    static func platformKey() -> String {
        #if arch(arm64)
        return "darwin-arm64"
        #else
        return ""
        #endif
    }

    private static func numeric(_ text: String) -> String? {
        guard !text.isEmpty, text.allSatisfy(\.isNumber) else { return nil }
        if text.count > 1 && text.hasPrefix("0") { return nil }
        return text
    }

    private static func prereleaseParts(_ text: String) -> [String]? {
        if text.isEmpty { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        for part in parts {
            if part.isEmpty || !part.allSatisfy({ $0.isNumber || $0.isLetter || $0 == "-" }) { return nil }
            if part.allSatisfy(\.isNumber), part.count > 1, part.hasPrefix("0") { return nil }
        }
        return parts
    }

    private static func isValidBuild(_ text: String) -> Bool {
        if text.isEmpty { return false }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        for part in parts {
            if part.isEmpty || !part.allSatisfy({ $0.isNumber || $0.isLetter || $0 == "-" }) { return false }
        }
        return true
    }

    private static func compareNumeric(_ lhs: String, _ rhs: String) -> Int {
        if lhs.count != rhs.count { return lhs.count < rhs.count ? -1 : 1 }
        if lhs == rhs { return 0 }
        return lhs < rhs ? -1 : 1
    }

    private static func compareIdentifier(_ lhs: String, _ rhs: String) -> Int {
        let leftNumber = lhs.allSatisfy(\.isNumber)
        let rightNumber = rhs.allSatisfy(\.isNumber)
        if leftNumber && rightNumber { return compareNumeric(lhs, rhs) }
        if leftNumber { return -1 }
        if rightNumber { return 1 }
        if lhs == rhs { return 0 }
        return lhs < rhs ? -1 : 1
    }
}

struct AppUpdateAsset: Codable, Equatable, Sendable {
    var name: String
    var url: String
    var sha256: String
    var size: Int64

    init(name: String, url: String, sha256: String, size: Int64) {
        self.name = name
        self.url = url
        self.sha256 = sha256
        self.size = size
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        name = try box.decodeIfPresent(String.self, forKey: .name) ?? ""
        url = try box.decodeIfPresent(String.self, forKey: .url) ?? ""
        sha256 = try box.decodeIfPresent(String.self, forKey: .sha256) ?? ""
        size = try box.decodeIfPresent(Int64.self, forKey: .size) ?? 0
    }
}

struct AppUpdateManifest: Codable, Equatable, Sendable {
    var version: String
    var minSupportedVersion: String
    var releasedAt: String
    var notes: String
    var assets: [String: AppUpdateAsset]

    init(version: String, minSupportedVersion: String = "", releasedAt: String = "", notes: String = "", assets: [String: AppUpdateAsset] = [:]) {
        self.version = version
        self.minSupportedVersion = minSupportedVersion
        self.releasedAt = releasedAt
        self.notes = notes
        self.assets = assets
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        version = try box.decodeIfPresent(String.self, forKey: .version) ?? ""
        minSupportedVersion = try box.decodeIfPresent(String.self, forKey: .minSupportedVersion) ?? ""
        releasedAt = try box.decodeIfPresent(String.self, forKey: .releasedAt) ?? ""
        notes = try box.decodeIfPresent(String.self, forKey: .notes) ?? ""
        assets = try box.decodeIfPresent([String: AppUpdateAsset].self, forKey: .assets) ?? [:]
    }

    func validated() -> Result<AppUpdateManifest, AppUpdateFailure> {
        var copy = self
        guard let version = AppVersionParser.parse(copy.version) else { return .failure(.badVersion) }
        copy.version = version.canonical
        if !copy.minSupportedVersion.isEmpty {
            guard let minimum = AppVersionParser.parse(copy.minSupportedVersion) else { return .failure(.badVersion) }
            copy.minSupportedVersion = minimum.canonical
            guard let order = AppVersionParser.compare(copy.minSupportedVersion, copy.version), order <= 0 else {
                return .failure(.minVersionTooHigh)
            }
        }
        for asset in copy.assets.values {
            if !asset.url.hasPrefix("https://") && !asset.url.hasPrefix("http://") {
                return .failure(.badAssetURL)
            }
            if asset.sha256.count != 64 {
                return .failure(.missingChecksum)
            }
        }
        return .success(copy)
    }

    func asset(for key: String) -> AppUpdateAsset? {
        if key.isEmpty { return nil }
        return assets[key]
    }
}

enum AppUpdateManifestParser {
    static func parse(data: Data, signature: Data, publicKey: String) -> Result<AppUpdateManifest, AppUpdateFailure> {
        if let error = AppUpdateCrypto.verify(publicKey: publicKey, data: data, signatureText: signature) {
            return .failure(error)
        }
        guard let manifest = try? JSONDecoder().decode(AppUpdateManifest.self, from: data) else {
            return .failure(.manifestParse)
        }
        return manifest.validated()
    }
}

enum AppUpdateFiles {
    static func assetFileName(_ asset: AppUpdateAsset) -> String? {
        var name = asset.name
        if name.isEmpty, let url = URL(string: asset.url) {
            name = url.lastPathComponent
        }
        name = (name as NSString).lastPathComponent
        if name.isEmpty || name == "." || name == ".." || name.hasPrefix(".") {
            return nil
        }
        return name
    }
}

struct AppReleasePost: Equatable, Sendable {
    var version: String
    var notes: String
    var pageURL: String
}

enum AppReleaseFeed {
    static func parse(data: Data) -> Result<AppReleasePost, AppUpdateFailure> {
        let parser = ReleaseFeedParser()
        guard let post = parser.parse(data) else { return .failure(.manifestParse) }
        return .success(post)
    }

    /// GitHub 把发布说明放在 HTML 里。这里只留下段落和列表，供弹窗直接显示。
    static func plainText(html: String) -> String {
        var text = html
        let breaks = ["</p>", "</li>", "</h1>", "</h2>", "</h3>", "<br>", "<br/>", "<br />", "</div>"]
        for tag in breaks {
            text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }
        text = text.replacingOccurrences(of: "<li>", with: "- ", options: .caseInsensitive)
        var output = ""
        var isInsideTag = false
        for character in text {
            if character == "<" {
                isInsideTag = true
                continue
            }
            if character == ">" {
                isInsideTag = false
                continue
            }
            if !isInsideTag { output.append(character) }
        }
        output = output.replacingOccurrences(of: "&nbsp;", with: " ")
        output = output.replacingOccurrences(of: "&amp;", with: "&")
        output = output.replacingOccurrences(of: "&lt;", with: "<")
        output = output.replacingOccurrences(of: "&gt;", with: ">")
        output = output.replacingOccurrences(of: "&quot;", with: "\"")
        output = output.replacingOccurrences(of: "&#39;", with: "'")
        let lines = output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var collapsed: [String] = []
        var isPreviousBlank = false
        for line in lines {
            if line.isEmpty {
                if !isPreviousBlank && !collapsed.isEmpty { collapsed.append("") }
                isPreviousBlank = true
            } else {
                if isPreviousBlank && line.hasPrefix("- ") && collapsed.last == "" {
                    let previous = collapsed.count >= 2 ? collapsed[collapsed.count - 2] : ""
                    if previous.hasPrefix("- ") { collapsed.removeLast() }
                }
                collapsed.append(line)
                isPreviousBlank = false
            }
        }
        return collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class ReleaseFeedParser: NSObject, XMLParserDelegate {
    private var post = AppReleasePost(version: "", notes: "", pageURL: "")
    private var text = ""
    private var isInEntry = false
    private var isDone = false

    func parse(_ data: Data) -> AppReleasePost? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        if !parser.parse() || post.version.isEmpty { return nil }
        post.notes = AppReleaseFeed.plainText(html: post.notes)
        return post
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if isDone { return }
        text = ""
        if elementName == "entry" { isInEntry = true }
        if isInEntry && elementName == "link" && attributeDict["rel"] == "alternate" {
            post.pageURL = attributeDict["href"] ?? ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isDone || !isInEntry { return }
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if isDone || !isInEntry { return }
        if let string = String(data: CDATABlock, encoding: .utf8) { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if isDone || !isInEntry { return }
        if elementName == "title" && post.version.isEmpty {
            post.version = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if elementName == "content" { post.notes += text }
        if elementName == "entry" {
            isDone = true
            isInEntry = false
        }
    }
}

struct AppUpdateClient: Sendable {
    var baseURL: String
    var publicKey: String
    var directory: String

    /// 签名清单拿不到时，用发布页的 Atom 补版本号和说明。不能用来安装。
    func fetchReleasePost() async -> Result<AppReleasePost, AppUpdateFailure> {
        switch await get(AppUpdate.releaseFeedURL, timeout: 8) {
        case .failure(let error):
            return .failure(error)
        case .success(let data):
            return AppReleaseFeed.parse(data: data)
        }
    }

    func fetch() async -> Result<AppUpdateManifest, AppUpdateFailure> {
        if baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure(.noSource)
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let manifestURL = endpoint(AppUpdate.manifestName) + "?t=\(stamp)"
        let signatureURL = endpoint(AppUpdate.signatureName) + "?t=\(stamp)"
        let data: Data
        switch await get(manifestURL) {
        case .success(let body): data = body
        case .failure(let error): return .failure(error)
        }
        let signature: Data
        switch await get(signatureURL) {
        case .success(let body): signature = body
        case .failure(let error): return .failure(error)
        }
        let parsed = AppUpdateManifestParser.parse(data: data, signature: signature, publicKey: publicKey)
        if case .success = parsed {
            saveCache(data: data, signature: signature)
        }
        return parsed
    }

    func loadCached() -> Result<AppUpdateManifest, AppUpdateFailure> {
        if directory.isEmpty { return .failure(.noDownloadDirectory) }
        let folder = URL(fileURLWithPath: directory)
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(AppUpdate.manifestName)),
              let signature = try? Data(contentsOf: folder.appendingPathComponent(AppUpdate.signatureName)) else {
            return .failure(.manifestParse)
        }
        return AppUpdateManifestParser.parse(data: data, signature: signature, publicKey: publicKey)
    }

    func download(_ asset: AppUpdateAsset, progress: @escaping @Sendable (Int64, Int64) -> Void) async -> Result<String, AppUpdateFailure> {
        if directory.isEmpty { return .failure(.noDownloadDirectory) }
        guard let name = AppUpdateFiles.assetFileName(asset) else { return .failure(.badFileName) }
        let folder = URL(fileURLWithPath: directory).appendingPathComponent("download")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return .failure(.noDownloadDirectory)
        }
        let finalURL = folder.appendingPathComponent(name)
        if let existing = hashFile(finalURL), existing.sum.caseInsensitiveCompare(asset.sha256) == .orderedSame {
            progress(existing.size, existing.size)
            return .success(finalURL.path)
        }
        guard let remote = URL(string: asset.url) else { return .failure(.badAssetURL) }
        var request = URLRequest(url: remote)
        request.timeoutInterval = 600
        let box = AppUpdateDownload(progress: progress)
        let session = URLSession(configuration: .default, delegate: box, delegateQueue: nil)
        let downloaded: URL
        let status: Int
        let received: Int64
        do {
            let result = try await withTaskCancellationHandler {
                try await box.start(session: session, request: request)
            } onCancel: {
                session.invalidateAndCancel()
            }
            downloaded = result.file
            status = result.status
            received = result.received
        } catch {
            session.invalidateAndCancel()
            return .failure(mapNetwork(error))
        }
        session.finishTasksAndInvalidate()
        if status != 200 {
            try? FileManager.default.removeItem(at: downloaded)
            return .failure(.httpStatus(status))
        }
        guard let hashed = hashFile(downloaded) else {
            try? FileManager.default.removeItem(at: downloaded)
            return .failure(.downloadInterrupted)
        }
        if asset.size > 0 && hashed.size != asset.size {
            try? FileManager.default.removeItem(at: downloaded)
            return .failure(.sizeMismatch)
        }
        if hashed.sum.caseInsensitiveCompare(asset.sha256) != .orderedSame {
            try? FileManager.default.removeItem(at: downloaded)
            return .failure(.checksumMismatch)
        }
        progress(received > 0 ? received : hashed.size, hashed.size)
        try? FileManager.default.removeItem(at: finalURL)
        do {
            try FileManager.default.moveItem(at: downloaded, to: finalURL)
        } catch {
            try? FileManager.default.removeItem(at: downloaded)
            return .failure(.downloadInterrupted)
        }
        return .success(finalURL.path)
    }

    func pruneDownloads(keeping name: String) {
        let folder = URL(fileURLWithPath: directory).appendingPathComponent("download")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for item in names where item != name {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(item))
        }
    }

    private func endpoint(_ name: String) -> String {
        baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + name
    }

    private func get(_ raw: String, timeout: TimeInterval = 20) async -> Result<Data, AppUpdateFailure> {
        if Task.isCancelled { return .failure(.downloadInterrupted) }
        guard let url = URL(string: raw) else { return .failure(.badAssetURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return .failure(.httpStatus(http.statusCode))
            }
            if data.count > AppUpdate.maxManifestBytes { return .failure(.manifestTooLarge) }
            return .success(data)
        } catch {
            return .failure(mapNetwork(error))
        }
    }

    private func saveCache(data: Data, signature: Data) {
        if directory.isEmpty { return }
        let folder = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent(AppUpdate.manifestName), options: .atomic)
        try? signature.write(to: folder.appendingPathComponent(AppUpdate.signatureName), options: .atomic)
    }

    private func hashFile(_ url: URL) -> (sum: String, size: Int64)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while true {
            let chunk = try? handle.read(upToCount: 64 * 1024)
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            size += Int64(chunk.count)
        }
        let sum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (sum, size)
    }

    private func mapNetwork(_ error: Error) -> AppUpdateFailure {
        if error is CancellationError { return .downloadInterrupted }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff, .callIsActive, .dataNotAllowed:
                return .unreachable
            case .cancelled:
                return .downloadInterrupted
            default:
                return .unreachable
            }
        }
        return .unreachable
    }
}

/// URLSession 把安装包下到临时文件，并按已写入的字节回报进度。
final class AppUpdateDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Result {
        var file: URL
        var status: Int
        var received: Int64
    }

    private let progress: @Sendable (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<Result, Error>?
    private var file: URL?
    private var status = 0
    private var received: Int64 = 0
    private let lock = NSLock()

    init(progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.progress = progress
    }

    func start(session: URLSession, request: URLRequest) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        received = totalBytesWritten
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("1agent-update-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            file = dest
        } catch {
            file = nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        if let error {
            if let file { try? FileManager.default.removeItem(at: file) }
            continuation?.resume(throwing: error)
            return
        }
        guard let file else {
            continuation?.resume(throwing: URLError(.cannotCreateFile))
            return
        }
        continuation?.resume(returning: Result(file: file, status: status, received: received))
    }
}
