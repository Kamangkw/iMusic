#if os(iOS)
import Combine
import Foundation
import Network

/// Only what the download gate needs: whether the current path is cellular.
/// Every other interface (Wi-Fi, wired, unknown) is treated as allowed.
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isOnCellular = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.moumusic.network-monitor")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let cellular = path.usesInterfaceType(.cellular)
            Task { @MainActor in
                guard let self, self.isOnCellular != cellular else { return }
                self.isOnCellular = cellular
            }
        }
        monitor.start(queue: queue)
    }
}
#endif
