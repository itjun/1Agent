import CryptoKit
import Foundation

/// 根据安装包生成 latest.json，并用 UPDATE_SIGN_KEY 做 ed25519 签名。
/// 签名必须能被 Sources/GooseAgent/AppUpdate.swift 里的公钥验过，否则客户端会拒绝这份清单。

struct Args {
    var version = ""
    var zip = ""
    var baseURL = ""
    var notesFile = ""
    var minimum = ""
    var out = ""
}

var args = Args()
var index = 1
let command = CommandLine.arguments
while index < command.count {
    let flag = command[index]
    index += 1
    guard index < command.count else {
        fputs("缺少 \(flag) 的参数\n", stderr)
        exit(1)
    }
    let value = command[index]
    index += 1
    switch flag {
    case "--version": args.version = value
    case "--zip": args.zip = value
    case "--base-url": args.baseURL = value
    case "--notes-file": args.notesFile = value
    case "--min": args.minimum = value
    case "--out": args.out = value
    default:
        fputs("未知参数 \(flag)\n", stderr)
        exit(1)
    }
}
if args.version.isEmpty || args.zip.isEmpty || args.baseURL.isEmpty || args.out.isEmpty {
    fputs("用法: update-manifest.swift --version vX.Y.Z --zip app.zip --base-url URL --out dist [--notes-file notes.txt] [--min vX.Y.Z]\n", stderr)
    exit(1)
}

let seedText = ProcessInfo.processInfo.environment["UPDATE_SIGN_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
guard let seed = Data(base64Encoded: seedText), seed.count == 32 else {
    fputs("UPDATE_SIGN_KEY 不是 32 字节的 ed25519 种子\n", stderr)
    exit(1)
}
let privateKey: Curve25519.Signing.PrivateKey
do {
    privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
} catch {
    fputs("无法读取签名私钥\n", stderr)
    exit(1)
}

let zipURL = URL(fileURLWithPath: args.zip)
guard let zipData = try? Data(contentsOf: zipURL) else {
    fputs("无法读取安装包 \(args.zip)\n", stderr)
    exit(1)
}
let digest = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
let name = zipURL.lastPathComponent
let base = args.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
var notes = ""
if !args.notesFile.isEmpty {
    notes = (try? String(contentsOfFile: args.notesFile, encoding: .utf8)) ?? ""
}
let released = ISO8601DateFormatter().string(from: Date())
let manifest: [String: Any] = [
    "version": args.version,
    "minSupportedVersion": args.minimum,
    "releasedAt": released,
    "notes": notes,
    "assets": [
        "darwin-arm64": [
            "name": name,
            "url": base + "/" + name,
            "sha256": digest,
            "size": zipData.count,
        ],
    ],
]
guard let body = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) else {
    fputs("无法生成清单\n", stderr)
    exit(1)
}
let signature = try privateKey.signature(for: body)
let signatureText = Data((signature.base64EncodedString() + "\n").utf8)

let source = (try? String(contentsOfFile: "Sources/GooseAgent/AppUpdate.swift", encoding: .utf8)) ?? ""
guard let match = source.range(of: #"static let publicKey = "([A-Za-z0-9+/=]+)""#, options: .regularExpression) else {
    fputs("找不到内置公钥\n", stderr)
    exit(1)
}
let quoted = source[match]
guard let keyStart = quoted.range(of: "\""), let keyEnd = quoted[keyStart.upperBound...].range(of: "\"") else {
    fputs("内置公钥格式不对\n", stderr)
    exit(1)
}
let embedded = String(quoted[keyStart.upperBound..<keyEnd.lowerBound])
guard let embeddedData = Data(base64Encoded: embedded),
      let embeddedKey = try? Curve25519.Signing.PublicKey(rawRepresentation: embeddedData),
      embeddedKey.isValidSignature(signature, for: body),
      embedded == privateKey.publicKey.rawRepresentation.base64EncodedString() else {
    fputs("签名私钥与客户端内置公钥不配对\n", stderr)
    exit(1)
}

let out = URL(fileURLWithPath: args.out, isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
try body.write(to: out.appendingPathComponent("latest.json"))
try signatureText.write(to: out.appendingPathComponent("latest.json.sig"))
fputs("已签名 \(args.version) \(name) \(digest)\n", stderr)
