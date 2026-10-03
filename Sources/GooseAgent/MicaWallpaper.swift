import CoreGraphics
import Foundation
import ImageIO

struct MicaColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    /// A subtle opaque color, not a wallpaper image or live desktop blur. Inactive windows
    /// return to the theme's neutral base. Foreground and ANSI palette are left alone.
    static func background(base: Self, wallpaper: Self, active: Bool) -> Self {
        let amount = active ? 0.12 : 0
        return Self(red: base.red + (wallpaper.red - base.red) * amount,
                    green: base.green + (wallpaper.green - base.green) * amount,
                    blue: base.blue + (wallpaper.blue - base.blue) * amount)
    }
}

enum MicaWallpaper {
    /// Decode only a tiny thumbnail, including HEIC wallpaper assets. Alpha is weighted so
    /// transparent pixels cannot incorrectly darken the sampled color.
    static func sample(_ url: URL) -> MicaColor? {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 32,
                  kCGImageSourceShouldCache: false,
              ] as CFDictionary) else { return nil }
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            red += Double(bytes[offset])
            green += Double(bytes[offset + 1])
            blue += Double(bytes[offset + 2])
            alpha += Double(bytes[offset + 3])
        }
        guard alpha > 0 else { return nil }
        return MicaColor(red: min(red / alpha, 1), green: min(green / alpha, 1), blue: min(blue / alpha, 1))
    }
}
