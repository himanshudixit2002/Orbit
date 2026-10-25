import Foundation
import OrbitCore
import OrbitShared
import WidgetKit

/// Keeps the snapshot Orbit's widgets and Control Center switches read: written when what they show
/// changes (and then they're told to reload), rewritten every ten minutes so they can tell Orbit is
/// still running, and marked "not running" when Orbit quits.
final class SnapshotPublisher {
    let store: SharedStore
    private var last: OrbitSnapshot?
    private var heartbeat: Task<Void, Never>?
    /// Writes in order, off the main thread.
    private let queue = DispatchQueue(label: "com.himanshudixit.orbit.snapshot", qos: .utility)
    private let reload: @MainActor () -> Void

    init(store: SharedStore, reload: @escaping @MainActor () -> Void = SnapshotPublisher.reloadWidgets) {
        self.store = store
        self.reload = reload
    }

    func publish(_ snapshot: OrbitSnapshot) {
        let changed = last.map { !$0.sameContent(as: snapshot) } ?? true
        let due = last.map { snapshot.written.timeIntervalSince($0.written) >= OrbitSnapshot.heartbeat - 5 } ?? true
        guard changed || due else { return }
        last = snapshot
        queue.async { [store, reload] in
            store.save(snapshot)
            guard changed else { return }
            Task { @MainActor in reload() }
        }
    }

    /// Rewrites the snapshot every ten minutes, for as long as Orbit runs.
    func startHeartbeat(_ snapshot: @escaping () -> OrbitSnapshot?) {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(OrbitSnapshot.heartbeat), tolerance: .seconds(30))
                guard !Task.isCancelled, let fresh = snapshot() else { continue }
                self?.publish(fresh)
            }
        }
    }

    /// Orbit is quitting: the widgets show it isn't running.
    func stopped() {
        heartbeat?.cancel()
        guard var final = last else { return }
        final.running = false
        final.written = Date()
        last = final
        queue.sync { [store] in _ = store.save(final) }
        reload()
    }

    static func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
    }
}
