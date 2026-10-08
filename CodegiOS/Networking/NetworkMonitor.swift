import Foundation
import Network

/// Shares one system path monitor. All snapshots and observers live on `queue`.
final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()

    struct Snapshot: Equatable, Sendable {
        let status: NWPath.Status
        let primaryInterface: NWInterface.InterfaceType?
        var isExpensive = false
        var isConstrained = false
    }

    final class Observation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancellation: (() -> Void)?

        fileprivate init(cancellation: @escaping () -> Void) {
            self.cancellation = cancellation
        }

        func cancel() {
            let action = lock.withLock {
                let action = cancellation
                cancellation = nil
                return action
            }
            action?()
        }

        deinit { cancel() }
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.codeg.network-monitor", qos: .utility)
    private var snapshot: Snapshot?
    private var pendingSnapshot: Snapshot?
    private var pendingUpdate: DispatchWorkItem?
    private var observers: [UUID: @Sendable (Snapshot?, Snapshot) -> Void] = [:]

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.schedule(Snapshot(
                status: path.status,
                // NWPath lists the available interfaces in order of preference.
                primaryInterface: path.availableInterfaces.first?.type,
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained
            ))
        }
        monitor.start(queue: queue)
    }

    func observe(_ observer: @escaping @Sendable (Snapshot?, Snapshot) -> Void) -> Observation {
        let id = UUID()
        queue.async { [self] in
            observers[id] = observer
            if let snapshot { observer(nil, snapshot) }
        }
        return Observation { [weak self] in
            guard let self else { return }
            self.queue.async { self.observers.removeValue(forKey: id) }
        }
    }

    static func isMeaningfulChange(old: Snapshot?, new: Snapshot) -> Bool {
        guard let old, new.status == .satisfied else { return false }
        return old.status == .unsatisfied
            || (old.status == .satisfied && old.primaryInterface != new.primaryInterface)
    }

    private func schedule(_ newSnapshot: Snapshot) {
        guard pendingSnapshot != newSnapshot else { return }
        pendingUpdate?.cancel()
        pendingUpdate = nil
        pendingSnapshot = nil
        guard snapshot != newSnapshot else { return }

        pendingSnapshot = newSnapshot
        let update = DispatchWorkItem { [weak self] in
            guard let self, self.pendingSnapshot == newSnapshot else { return }
            let old = self.snapshot
            self.snapshot = newSnapshot
            self.pendingSnapshot = nil
            self.pendingUpdate = nil
            for observer in self.observers.values { observer(old, newSnapshot) }
        }
        pendingUpdate = update
        queue.asyncAfter(deadline: .now() + 1, execute: update)
    }

    deinit {
        pendingUpdate?.cancel()
        monitor.cancel()
    }
}
