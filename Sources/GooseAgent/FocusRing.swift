import SwiftUI

/// 兼容现有调用点，按钮的绘制、键盘激活及焦点由系统负责。
struct FamilyButtonStyle: PrimitiveButtonStyle {
    enum Kind { case plain, secondary, primary }
    var kind: Kind = .plain

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        switch kind {
        case .plain: Button(configuration).buttonStyle(.borderless)
        case .secondary: Button(configuration).buttonStyle(.bordered)
        case .primary: Button(configuration).buttonStyle(.borderedProminent)
        }
    }
}
