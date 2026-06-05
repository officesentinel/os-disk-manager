import Foundation
import Combine

struct DiskHistoryItem: Identifiable, Hashable {
    var id: String { serial }
    let serial: String
    let model: String
    let sizeGB: Double
    let interface: String
    let isSSD: Bool
    let lastSeen: String
    let snapshotCount: Int
    let latestVerdict: String
    let latestHealth: Bool
    let latestLife: Int?
    let latestTemp: Int
    let latestPOH: Int
}

struct SnapshotSummary: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let timestamp: String
    let timestampEpoch: Double
    var date: Date { Date(timeIntervalSince1970: timestampEpoch) }
    let kind: String
    let verdict: String
    let healthPassed: Bool
    let lifeLeftPercent: Int?
    let wearPercentUsed: Int?
    let temperatureC: Int
    let temperatureMaxC: Int?
    let powerOnHours: Int
    let powerCycles: Int
    let defects: Int
}

@MainActor
final class HistoryManager: ObservableObject {
    @Published var disks: [DiskHistoryItem] = []
    @Published var selectedDisk: DiskHistoryItem? { didSet { if oldValue?.serial != selectedDisk?.serial { loadSnapshotsForSelected() } } }
    @Published var snapshots: [SnapshotSummary] = []
    @Published var selectedSnapshot: SnapshotSummary?
    @Published var fullSnapshot: [String: Any]?
    @Published var compareSelection: [String] = []
    @Published var loading = false

    private let enginePath: String = {
        let c = ["/usr/local/bin/diskwipe-engine",
                 (NSHomeDirectory() as NSString).appendingPathComponent("src/diskwipe/.build/debug/diskwipe-engine")]
        return c.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/local/bin/diskwipe-engine"
    }()

    func refresh() {
        loading = true
        let path = enginePath
        Task.detached { [weak self] in
            guard let self else { return }
            let arr = Self.runArraySync(argv: [path, "history"]) ?? []
            await MainActor.run {
                self.disks = arr.map { Self.parseDisk($0) }
                self.loading = false
                if let sel = self.selectedDisk, !self.disks.contains(where: { $0.serial == sel.serial }) {
                    self.selectedDisk = self.disks.first
                } else if self.selectedDisk == nil {
                    self.selectedDisk = self.disks.first
                } else {
                    self.loadSnapshotsForSelected()  // refresh in place
                }
            }
        }
    }

    func loadSnapshotsForSelected() {
        guard let serial = selectedDisk?.serial else { snapshots = []; fullSnapshot = nil; return }
        let path = enginePath
        Task.detached { [weak self] in
            guard let self else { return }
            let arr = Self.runArraySync(argv: [path, "history", "--serial", serial]) ?? []
            await MainActor.run {
                self.snapshots = arr.map { Self.parseSnap($0) }
                self.selectedSnapshot = self.snapshots.last
                self.compareSelection.removeAll()
                self.loadFullSnapshot(path: self.selectedSnapshot?.path)
            }
        }
    }

    func loadFullSnapshot(path snapPath: String?) {
        guard let snapPath else { fullSnapshot = nil; return }
        let engine = enginePath
        Task.detached { [weak self] in
            guard let self else { return }
            let obj = Self.runObjectSync(argv: [engine, "history", "--path", snapPath])
            await MainActor.run { self.fullSnapshot = obj }
        }
    }

    func toggleCompare(_ path: String) {
        if let i = compareSelection.firstIndex(of: path) {
            compareSelection.remove(at: i)
        } else if compareSelection.count < 2 {
            compareSelection.append(path)
        } else {
            // replace oldest
            compareSelection.removeFirst()
            compareSelection.append(path)
        }
    }

    func loadSnapshotByPath(_ path: String) -> [String: Any]? {
        Self.runObjectSync(argv: [enginePath, "history", "--path", path])
    }

    // MARK: parsing

    private static func parseDisk(_ d: [String: Any]) -> DiskHistoryItem {
        DiskHistoryItem(
            serial: d["serial"] as? String ?? "?",
            model: d["model"] as? String ?? "—",
            sizeGB: Double(d["sizeBytes"] as? Int64 ?? 0) / 1e9,
            interface: d["interface"] as? String ?? "",
            isSSD: d["isSSD"] as? Bool ?? true,
            lastSeen: d["lastSeen"] as? String ?? "",
            snapshotCount: d["snapshotCount"] as? Int ?? 0,
            latestVerdict: d["latestVerdict"] as? String ?? "—",
            latestHealth: d["latestHealth"] as? Bool ?? true,
            latestLife: d["latestLife"] as? Int,
            latestTemp: d["latestTemp"] as? Int ?? 0,
            latestPOH: d["latestPOH"] as? Int ?? 0
        )
    }
    private static func parseSnap(_ d: [String: Any]) -> SnapshotSummary {
        SnapshotSummary(
            path: d["path"] as? String ?? "",
            timestamp: d["timestamp"] as? String ?? "",
            timestampEpoch: d["timestampEpoch"] as? Double ?? 0,
            kind: d["kind"] as? String ?? "snapshot",
            verdict: d["verdict"] as? String ?? "—",
            healthPassed: d["healthPassed"] as? Bool ?? true,
            lifeLeftPercent: d["lifeLeftPercent"] as? Int,
            wearPercentUsed: d["wearPercentUsed"] as? Int,
            temperatureC: d["temperatureC"] as? Int ?? 0,
            temperatureMaxC: d["temperatureMaxC"] as? Int,
            powerOnHours: d["powerOnHours"] as? Int ?? 0,
            powerCycles: d["powerCycles"] as? Int ?? 0,
            defects: d["defects"] as? Int ?? 0
        )
    }

    // MARK: process helpers

    nonisolated private static func runDataSync(argv: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let out = Pipe(); let err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return d
    }
    nonisolated private static func runArraySync(argv: [String]) -> [[String: Any]]? {
        guard let d = runDataSync(argv: argv) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]]
    }
    nonisolated private static func runObjectSync(argv: [String]) -> [String: Any]? {
        guard let d = runDataSync(argv: argv) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}
