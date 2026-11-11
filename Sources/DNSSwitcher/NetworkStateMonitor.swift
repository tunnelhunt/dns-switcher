import Foundation
import SystemConfiguration

/// Monitors network changes in real-time (VPN connection/disconnection, interface changes, DNS overrides).
/// Completely event-driven via SCDynamicStore without any polling or background timers.
public final class NetworkStateMonitor: @unchecked Sendable {
    public static let shared = NetworkStateMonitor()

    private let queue = DispatchQueue(label: "com.dnsswitcher.networkmonitor", qos: .utility)
    private var store: SCDynamicStore?
    private var debounceWorkItem: DispatchWorkItem?
    private var onNetworkChanged: (@Sendable () -> Void)?
    private var isStarted = false
    private let lock = NSLock()

    private init() {}

    public func start(onNetworkChanged: @escaping @Sendable () -> Void) {
        lock.lock()
        guard !isStarted else {
            lock.unlock()
            return
        }
        isStarted = true
        self.onNetworkChanged = onNetworkChanged
        lock.unlock()

        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info = info else { return }
            let monitor = Unmanaged<NetworkStateMonitor>.fromOpaque(info).takeUnretainedValue()
            monitor.handleKeysChanged()
        }

        guard let store = SCDynamicStoreCreate(nil, "com.dnsswitcher.networkmonitor" as CFString, callback, &context) else {
            fputs("[NetworkStateMonitor] Failed to create SCDynamicStore\n", stderr)
            return
        }
        self.store = store

        let patterns = [
            "State:/Network/Global/.*",
            "Setup:/Network/Service/.*/DNS",
            "State:/Network/Service/.*/DNS",
            "State:/Network/Interface/.*/Link",
            "State:/Network/Interface/.*/IPv4"
        ] as CFArray

        SCDynamicStoreSetNotificationKeys(store, nil, patterns)
        SCDynamicStoreSetDispatchQueue(store, queue)
    }

    private func handleKeysChanged() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.debounceWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.onNetworkChanged?()
            }
            self.debounceWorkItem = work
            self.queue.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }
}
