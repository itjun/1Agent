import AppKit
import UserNotifications

/// 通知中心不使用运行中的 Dock 图标；每条通知携带发送时的主题图标。
@MainActor
enum SystemNotificationIcon {
    @discardableResult
    static func apply(to content: UNMutableNotificationContent, icon: ApplicationIcon, bundle: Bundle = .main) -> Bool {
        // macOS 的通知图标接口尚未公开。先检查能力，旧系统继续使用包内的普通图标。
        let factory = NSSelectorFromString("iconWithData:")
        let setter = NSSelectorFromString("setIcon:")
        guard let iconClass = NSClassFromString("UNNotificationIcon") as? NSObject.Type,
              iconClass.responds(to: factory), content.responds(to: setter) else { return false }
        guard let image = icon.image(in: bundle),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]),
              let notificationIcon = iconClass.perform(factory, with: data)?.takeUnretainedValue() else {
            NSLog("1Agent notification icon unavailable: %@", icon.rawValue)
            return false
        }
        content.perform(setter, with: notificationIcon)
        return true
    }
}
