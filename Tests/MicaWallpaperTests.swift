import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
enum MicaWallpaperTests {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MicaWallpaperTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Semi-transparent colored pixels next to transparent ones must keep their hue.
        let url = folder.appendingPathComponent("wallpaper.png")
        var pixels: [UInt8] = [128, 0, 0, 128, 0, 0, 0, 0]
        let image = pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!.makeImage()!
        }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        expect(CGImageDestinationFinalize(destination), "write fixture")
        let sampled = MicaWallpaper.sample(url)!
        expect(abs(sampled.red - 1) < 0.01 && sampled.green < 0.01 && sampled.blue < 0.01, "thumbnail color is alpha weighted")
        expect(MicaWallpaper.sample(folder.appendingPathComponent("missing.heic")) == nil, "missing wallpaper can fall back")
        let invalid = folder.appendingPathComponent("unsupported.mov")
        try Data("unsupported wallpaper".utf8).write(to: invalid)
        expect(MicaWallpaper.sample(invalid) == nil, "unsupported wallpaper can fall back")
        expect(MicaWallpaper.sample(URL(string: "https://example.com/wallpaper.png")!) == nil, "wallpaper sampling stays local")

        let base = MicaColor(red: 0.1, green: 0.1, blue: 0.1)
        let active = MicaColor.background(base: base, wallpaper: sampled, active: true)
        let inactive = MicaColor.background(base: base, wallpaper: sampled, active: false)
        expect(active.red > base.red && active.red < 0.25, "active windows have a subtle wallpaper tint")
        expect(inactive == base, "inactive windows use the neutral theme background")
        expect(active != inactive, "focus has a visible material state")
        print("ok")
    }

    static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            fputs("FAIL \(message)\n", stderr)
            exit(1)
        }
    }
}
