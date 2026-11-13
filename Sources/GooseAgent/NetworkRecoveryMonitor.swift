import Foundation
import Network
import SystemConfiguration

/// 同时观察可达性与接口地址：VPN 保持在线时，底层 Wi-Fi / 有线网络仍可能切换。
@MainActor
final class NetworkRecoveryMonitor {
    struct State: Equatable {
        var isAvailable: Bool
        var configuration: [String]
    }

    private let onRecovery: () -> Void
    private let monitor = NWPathMonitor()
    private var store: SCDynamicStore?
    private var source: CFRunLoopSource?
    private var previousState: State?
    private var recoveryTask: Task<Void, Never>?

    init(onRecovery: @escaping () -> Void) {
        self.onRecovery = onRecovery
    }

    func start() {
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        store = SCDynamicStoreCreate(nil, "1Agent network recovery" as CFString, { _, _, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<NetworkRecoveryMonitor>.fromOpaque(context).takeUnretainedValue().readState()
            }
        }, &context)
        if let store {
            SCDynamicStoreSetNotificationKeys(store, Self.globalKeys as CFArray, Self.interfacePatterns as CFArray)
            source = SCDynamicStoreCreateRunLoopSource(nil, store, 0)
            if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        }
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.readState() }
        }
        monitor.start(queue: .main)
    }

    private static let globalKeys = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"]
    private static let interfacePatterns = ["State:/Network/Interface/.*/IPv4", "State:/Network/Interface/.*/IPv6"]

    private func readState() {
        let path = monitor.currentPath
        var configuration = path.availableInterfaces.map { $0.name }.sorted()
        if let store,
           let values = SCDynamicStoreCopyMultiple(store, Self.globalKeys as CFArray,
                                                   Self.interfacePatterns as CFArray) as? [String: [String: Any]] {
            for key in values.keys.sorted() {
                guard let value = values[key] else { continue }
                // 只比较连接相关字段，排除租约刷新等不改变网络的通知。
                for field in ["Addresses", "Router", "PrimaryInterface"] {
                    if let text = value[field] as? String { configuration.append("\(key)/\(field)=\(text)") }
                    if let addresses = value[field] as? [String] {
                        configuration.append("\(key)/\(field)=\(addresses.sorted().joined(separator: ","))")
                    }
                }
            }
        }
        receive(State(isAvailable: path.status == .satisfied, configuration: configuration))
    }

    /// 与系统回调共用的入口，允许测试离线、恢复和 VPN 下的接口切换。
    func receive(_ state: State) {
        let previous = previousState
        previousState = state
        guard state != previous else { return }
        recoveryTask?.cancel()
        recoveryTask = nil
        guard let previous, state.isAvailable,
              !previous.isAvailable || previous.configuration != state.configuration else { return }
        recoveryTask = Task { [weak self] in
            // 等地址、路由与 VPN 的连续通知稳定下来，只恢复一次。
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.recoveryTask = nil
            self.onRecovery()
        }
    }

    deinit {
        recoveryTask?.cancel()
        monitor.cancel()
        if let source { CFRunLoopSourceInvalidate(source) }
    }
}
