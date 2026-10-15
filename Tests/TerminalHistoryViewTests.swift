import AppKit
@main struct HistoryFontRepro {
 @MainActor static func main() {
  let app = NSApplication.shared
  let snapshot = TerminalHistorySnapshot(mainText: "\u{e0b6} 中文 itjun \u{f179}", lastScreenText: "\u{e0b6} 中文 itjun \u{f179}", mainViewportTop: 0, visibleRows: 24, wasAlternateScreen: false)
  var expected = TerminalSettings.defaults
  expected.fontFamily = "Menlo"
  expected.fontSize = 18
  let view = TerminalHistoryView(snapshot: snapshot, settings: expected)
  func texts(_ v: NSView) -> [NSTextView] { (v as? NSTextView).map { [$0] } ?? v.subviews.flatMap(texts) }
  let font = texts(view).first!.font!
  print("history font=\(font.familyName ?? "nil") \(font.pointSize), configured=\(expected.fontFamily) \(expected.fontSize)")
  guard font.familyName == expected.fontFamily, font.pointSize == expected.fontSize else { exit(1) }
  print("ok: history uses configured font family and size")
  _ = app
 }
}
