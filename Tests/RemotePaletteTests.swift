import AppKit
import SwiftUI

@main enum RemotePaletteTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let expected = WindowChrome(isDark: dark)
            for icon in ApplicationIcon.allCases {
                precondition(WindowChrome(isDark: dark, icon: icon) == expected, "App icons must not recolor UI")
            }
            precondition(NSColor(expected.text) == NSColor.labelColor, "Native label color")
            precondition(NSColor(expected.accent) == NSColor.controlAccentColor, "System accent color")
            precondition(NSColor(expected.background) == NSColor.textBackgroundColor, "System content background")
        }
        print("RemotePaletteTests passed: system colors independent of icon and connection type")
    }
}
