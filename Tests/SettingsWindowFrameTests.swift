import CoreGraphics
import Foundation

@main
enum SettingsWindowFrameTests {
    static func main() {
        let screen = CGRect(x: 0, y: 0, width: 4000, height: 2400)
        let minSize = CGSize(width: 880, height: 720)

        let main = CGRect(x: 100, y: 100, width: 3000, height: 2000)
        let onMain = SettingsWindowFrame.frame(anchor: main, visible: screen, minSize: minSize)
        expect(onMain.width == 1500 && onMain.height == 1000, "50% of the main window")
        expect(onMain.midX == main.midX && onMain.midY == main.midY, "centered on the main window")

        let small = CGRect(x: 0, y: 0, width: 600, height: 500)
        let floored = SettingsWindowFrame.frame(anchor: small, visible: screen, minSize: minSize)
        expect(floored.width == 880 && floored.height == 720, "never below the minimum size")
        expect(floored.minX >= screen.minX && floored.minY >= screen.minY, "pushed back onto the screen")

        let onScreen = SettingsWindowFrame.frame(anchor: screen, visible: screen, minSize: minSize)
        expect(onScreen.width == 2000 && onScreen.height == 1200, "50% of the screen without a main window")
        expect(onScreen.midX == screen.midX && onScreen.midY == screen.midY, "centered on the screen")

        let tinyScreen = CGRect(x: 0, y: 0, width: 800, height: 600)
        let capped = SettingsWindowFrame.frame(anchor: tinyScreen, visible: tinyScreen, minSize: minSize)
        expect(capped.width == 800 && capped.height == 600, "never larger than the visible screen")
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
