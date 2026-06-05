import Foundation
import DiskArbitration

/// Observes macOS disk insertion / removal events via the DiskArbitration
/// framework. Runners register a callback once; the watcher fires it on each
/// `kDADiskAppeared` / `kDADiskDisappeared` event.
///
/// This replaces 3-second polling timers in each runner — idle CPU drops to
/// effectively zero and `/var/log/system.log` is no longer flooded with
/// `sudo: TTY=unknown` lines.
///
/// A low-frequency safety-net poll (every 30 s) is still scheduled so that
/// pathological cases (e.g. a USB-SATA bridge that never raises an event)
/// still see disk-list updates eventually.
@MainActor
final class DiskWatcher {
    static let shared = DiskWatcher()

    private var session: DASession?
    private var callbacks: [UUID: () -> Void] = [:]
    private var safetyTimer: Timer?

    private init() {
        guard let s = DASessionCreate(kCFAllocatorDefault) else {
            AppLog.shared.error("diskwatcher", "DASessionCreate failed — falling back to polling only")
            startSafetyPoll()
            return
        }
        session = s
        DASessionScheduleWithRunLoop(s, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let ctx = Unmanaged.passUnretained(self).toOpaque()

        // Disk appeared
        DARegisterDiskAppearedCallback(s, nil, { _, ctx in
            guard let ctx else { return }
            let watcher = Unmanaged<DiskWatcher>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in watcher.fireAll() }
        }, ctx)

        // Disk disappeared
        DARegisterDiskDisappearedCallback(s, nil, { _, ctx in
            guard let ctx else { return }
            let watcher = Unmanaged<DiskWatcher>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in watcher.fireAll() }
        }, ctx)

        AppLog.shared.info("diskwatcher", "DiskArbitration session running on main RunLoop")
        startSafetyPoll()
    }

    /// Register a callback that will be invoked on every disk hot-plug event
    /// plus once every 30 s as a safety-net poll. Returns a token to pass back
    /// to `unregister`.
    @discardableResult
    func register(_ callback: @escaping () -> Void) -> UUID {
        let id = UUID()
        callbacks[id] = callback
        return id
    }

    func unregister(_ id: UUID?) {
        guard let id else { return }
        callbacks.removeValue(forKey: id)
    }

    /// Manually trigger all registered callbacks (e.g. on app foregrounding).
    func refresh() { fireAll() }

    // MARK: - private

    private func fireAll() {
        let cbs = Array(callbacks.values)
        cbs.forEach { $0() }
    }

    private func startSafetyPoll() {
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.fireAll() }
        }
    }
}
