import Foundation

@main
enum TextFileTests {
    static func main() {
        expect(TextFile.isTextName("nginx.conf"), "conf is text")
        expect(TextFile.isTextName("Dockerfile"), "Dockerfile is text")
        expect(TextFile.isTextName(".env.local"), ".env files are text")
        expect(!TextFile.isTextName("a.tar.gz"), "archives are not text")
        expect(!TextFile.isTextName("photo.png"), "images are not text")
        expect(!TextFile.isTextName("noext"), "no extension is not text")

        let lf = TextFile.decode(Data("a\nb\n".utf8))
        expect(lf?.encoding == .utf8 && lf?.lineEnding == .lf && lf?.isUTF8LF == true, "utf-8 lf")
        let crlf = TextFile.decode(Data("a\r\nb\r\n".utf8))
        expect(crlf?.lineEnding == .crlf && crlf?.isUTF8LF == false, "crlf")
        expect(TextFile.decode(Data("a\r\nb\n".utf8))?.lineEnding == .mixed, "mixed")
        expect(TextFile.decode(Data("a\rb".utf8))?.lineEnding == .cr, "cr")
        expect(TextFile.decode(Data("abc".utf8))?.lineEnding == TextFile.LineEnding.none, "one line")
        expect(TextFile.decode(Data([0xEF, 0xBB, 0xBF] + Array("hi\n".utf8)))?.encoding == .utf8BOM, "bom")
        expect(TextFile.decode(Data([0x00, 0x01, 0x02])) == nil, "binary")
        let gbBytes: [UInt8] = [0xC4, 0xE3, 0xBA, 0xC3, 0x0A]
        let gb = TextFile.decode(Data(gbBytes))
        expect(gb?.encoding == .gb18030 && gb?.text == "你好\n", "gb18030")

        expect(TextFile.utf8LF("a\r\nb\rc\n") == Data("a\nb\nc\n".utf8), "convert to lf")

        expect(TextFile.uploadConversion(name: "a.txt", data: Data("a\nb\n".utf8)) == nil, "utf-8 lf uploads as is")
        expect(TextFile.uploadConversion(name: "a.bat", data: Data("a\r\nb\r\n".utf8))?.lineEnding == .crlf, "crlf converts")
        expect(TextFile.uploadConversion(name: "a.sql", data: Data(gbBytes))?.encoding == .gb18030, "gb18030 converts")
        expect(TextFile.uploadConversion(name: "deploy", data: Data("x\r\n".utf8)) != nil, "script without extension converts")
        expect(TextFile.uploadConversion(name: "a.png", data: Data("x\r\n".utf8)) == nil, "images are skipped")
        expect(TextFile.uploadConversion(name: "blob", data: Data([0xFF, 0x80, 0x0D, 0x0A])) == nil,
               "latin-1 only without a text name is binary")
        expect(TextFile.uploadConversion(name: "a.txt", data: Data()) == nil, "empty file is skipped")
        expect(gb?.isInferred == true, "legacy detection is labelled an inference")
        expect(TextFile.decode(Data(gbBytes), using: .utf8) == nil, "manual reading does not silently fallback")
        expect(TextFile.decode(Data(gbBytes), using: .gb18030)?.isInferred == false, "manual reading is explicit")
        let chinese = Data("hello 你好".utf8)
        for missing in 1...2 {
            let preview = TextFile.decodePreview(chinese.dropLast(missing), truncated: true)
            expect(preview?.encoding == .utf8 && preview?.text == "hello 你", "truncated UTF8 boundary \(missing)")
        }
        let mixed = "a\r\nb\nc\r"
        expect((try? TextFile.encode(mixed, encoding: .utf8BOM, lineEnding: nil)) == Data([0xEF, 0xBB, 0xBF]) + Data(mixed.utf8), "encoding-only preserves mixed newlines")
        let utf16 = try! TextFile.encode("你好\r\n", encoding: .utf16LE, lineEnding: .lf)
        expect(utf16.starts(with: [0xFF, 0xFE]), "UTF16 explicit BOM")
        expect(TextFile.decode(utf16)?.text == "你好\n", "UTF16 line endings independent")
        expect((try? TextFile.encode("中文", encoding: .latin1, lineEnding: nil)) == nil, "unrepresentable conversion must fail instead of losing data")
        expect((try? TextFile.encode("a\r\nb\nc\r", encoding: .utf8, lineEnding: .crlf)) == Data("a\r\nb\r\nc\r\n".utf8), "newline-only normalizes all varieties")
        let bomReading = TextFile.decode(Data([0xEF, 0xBB, 0xBF]) + Data("hello\r\n".utf8), using: .utf8)!
        expect(bomReading.encoding == .utf8BOM && bomReading.hasBOM, "reading UTF8 preserves detected BOM identity")
        expect((try! TextFile.encode(bomReading.text, encoding: bomReading.encoding, lineEnding: .lf,
                                     includeBOM: bomReading.hasBOM)).starts(with: [0xEF, 0xBB, 0xBF]), "newline-only keeps UTF8 BOM")
        let noBom16 = "hello\r\n".data(using: .utf16LittleEndian)!
        let read16 = TextFile.decode(noBom16, using: .utf16LE)!
        expect(!read16.hasBOM, "manual UTF16 without BOM records actual format")
        expect(try! TextFile.encode(read16.text, encoding: read16.encoding, lineEnding: .lf,
                                    includeBOM: read16.hasBOM) == "hello\n".data(using: .utf16LittleEndian)!, "newline-only does not add UTF16 BOM")
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
