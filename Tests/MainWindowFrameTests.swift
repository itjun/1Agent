import CoreGraphics
import Foundation

@main
enum MainWindowFrameTests {
    static func main() {
        let visible = CGRect(x: 100, y: 80, width: 2000, height: 1200)
        let opened = MainWindowFrame.frame(screen: visible, visible: visible)
        expect(opened.width == 1600 && opened.height == 960, "80% of the screen, got \(opened)")
        expect(opened.midX == visible.midX && opened.midY == visible.midY, "centered on the screen, got \(opened)")

        let aboveMinimum = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let fitted = MainWindowFrame.frame(screen: aboveMinimum, visible: aboveMinimum)
        expect(fitted.width == 800 && fitted.height == 480, "80% of a small screen, got \(fitted)")
        expect(fitted.midX == aboveMinimum.midX && fitted.midY == aboveMinimum.midY, "small window stays centered, got \(fitted)")

        let short = CGRect(x: 0, y: 0, width: 2000, height: 560)
        let raised = MainWindowFrame.frame(screen: short, visible: short)
        expect(raised.width == 1600 && raised.height == 448, "80% of a short screen, got \(raised)")
        expect(abs((raised.minY - short.minY) - (short.maxY - raised.maxY)) <= 1, "short window stays vertically centered")

        let tiny = CGRect(x: 20, y: 30, width: 800, height: 400)
        let capped = MainWindowFrame.frame(screen: tiny, visible: tiny)
        expect(capped.width == 640 && capped.height == 320, "80% of a tiny screen, got \(capped)")

        let screen = CGRect(x: -2560, y: 0, width: 2560, height: 1440)
        let belowMenuBar = CGRect(x: -2560, y: 0, width: 2560, height: 1410)
        let placed = MainWindowFrame.frame(screen: screen, visible: belowMenuBar)
        expect(placed.width == 2048 && placed.height == 1152, "80% of the full screen, got \(placed)")
        expect(abs((placed.minX - screen.minX) - (screen.maxX - placed.maxX)) <= 1, "horizontally centered on the screen")
        expect(abs((placed.minY - screen.minY) - (screen.maxY - placed.maxY)) <= 1, "vertically centered on the screen, got \(placed)")
        expect(belowMenuBar.contains(placed), "centered window still stays below the menu bar")

        let aboveDock = CGRect(x: 0, y: 80, width: 2000, height: 1120)
        let docked = MainWindowFrame.frame(screen: CGRect(x: 0, y: 0, width: 2000, height: 1200), visible: aboveDock)
        expect(abs((docked.minY - 0) - (1200 - docked.maxY)) <= 1, "vertically centered when the Dock leaves room")
        expect(aboveDock.contains(docked), "centered window still stays above the Dock")

        let largeDock = CGRect(x: 0, y: 150, width: 2000, height: 1050)
        let shifted = MainWindowFrame.frame(screen: CGRect(x: 0, y: 0, width: 2000, height: 1200), visible: largeDock)
        expect(shifted.width == 1600 && shifted.height == 960 && shifted.minY == 150, "shift above a large Dock without changing size, got \(shifted)")
        print("ok")
    }

    static func expect(_ condition: Bool, _ message: String) {
        if !condition { fail(message) }
    }

    static func fail(_ message: String) {
        fputs("FAIL \(message)\n", stderr)
        exit(1)
    }
}
