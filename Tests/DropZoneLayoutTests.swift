import CoreGraphics
import Foundation

@main
enum DropZoneLayoutTests {
    static func main() {
        let size = CGSize(width: 1000, height: 600)
        expect(DropZoneLayout.zone(at: CGPoint(x: 500, y: 260), in: size, transfer: true) == .insertPath, "upper half of the center circle")
        expect(DropZoneLayout.zone(at: CGPoint(x: 500, y: 340), in: size, transfer: true) == .openInPlace, "lower half of the center circle")
        expect(DropZoneLayout.zone(at: CGPoint(x: 10, y: 300), in: size, transfer: true) == .splitLeft, "left edge")
        expect(DropZoneLayout.zone(at: CGPoint(x: 990, y: 300), in: size, transfer: true) == .splitRight, "right edge")
        expect(DropZoneLayout.zone(at: CGPoint(x: 500, y: 5), in: size, transfer: true) == .newTab, "top edge")
        expect(DropZoneLayout.zone(at: CGPoint(x: 500, y: 595), in: size, transfer: true) == .transfer, "bottom edge")
        expect(DropZoneLayout.zone(at: CGPoint(x: 500, y: 595), in: size, transfer: false) != .transfer, "no transfer zone when it is off")
        expect(DropZoneLayout.zone(at: CGPoint(x: 120, y: 60), in: size, transfer: true) == .splitLeft || DropZoneLayout.zone(at: CGPoint(x: 120, y: 60), in: size, transfer: true) == .newTab, "a corner goes to the nearest circle")
        expect(DropZoneLayout.outline(of: .insertPath, in: size).allSatisfy { $0.y <= 300.001 }, "Insert Path is the upper half")
        expect(DropZoneLayout.outline(of: .openInPlace, in: size).allSatisfy { $0.y >= 299.999 }, "Open in Place is the lower half")
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
