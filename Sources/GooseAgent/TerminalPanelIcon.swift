import SwiftUI

/// A miniature of the actual split tree, shared by the sidebar and open-items overview.
struct TerminalPanelIcon: View {
    let layout: PaneNode

    var body: some View {
        if case .leaf = layout {
            Image(systemName: "terminal")
        } else {
            GeometryReader { geometry in
                let bounds = CGRect(origin: .zero, size: geometry.size).insetBy(dx: 0.5, dy: 0.5)
                let frames = PaneLayout.frames(of: layout, in: bounds)
                Path { path in
                    for frame in frames.values {
                        path.addRoundedRect(in: frame.insetBy(dx: 0.5, dy: 0.5), cornerSize: CGSize(width: 0.6, height: 0.6))
                    }
                }.stroke(lineWidth: 1)
            }.frame(width: 18, height: 13).accessibilityHidden(true)
        }
    }
}
