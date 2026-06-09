import Foundation
import Combine

struct PartCaps: Hashable {
    var canFormat = true
    var canResize = false
    var canDelete = false
    var canAddNext = false
    var formatReason: String?
    var resizeReason: String?
    var deleteReason: String?
    var addReason: String?
}

struct PartItem: Identifiable, Hashable {
    let id: String
    let name: String
    let fs: String
    let sizeBytes: Int64
    let mount: String
    let apfsVolume: Bool
    var caps: PartCaps = PartCaps()
    var sizeGB: Double { Double(sizeBytes) / 1_000_000_000.0 }
    var display: String {
        let n = name.isEmpty ? "—" : name
        return "\(id)  ·  \(n)  ·  \(fs)  ·  \(String(format: "%.1f GB", sizeGB))"
    }
}

@MainActor
final class PartitionManager: ObservableObject {
    @Published var disks: [DiskItem] = []
    @Published var selectedDisk: DiskItem? { didSet { if oldValue?.id != selectedDisk?.id { handleDiskChanged() } } }
    private var watcherId: UUID?
    @Published var scheme: String = "—"
    @Published var partitions: [PartItem] = []
    @Published var selectedPart: PartItem?
    @Published var busy = false
    @Published var lastResult: String = ""
    @Published var lastOK = true

    static let filesystems = ["APFS", "HFS+", "ExFAT", "FAT32", "ext4", "ext3", "ext2"]
    static let schemes = ["GPT", "MBR", "APM"]

    private var enginePath: String { EngineClient.shared.enginePath }

    /// Engine `list` runs on a background task — a synchronous Process spawn
    /// (~200-500 ms) on the main actor freezes the UI on every hot-plug event.
    func refreshDisks() {
        Task.detached { [weak self] in
            let arr = EngineClient.shared.array(["list"]) ?? []
            await MainActor.run {
                guard let self else { return }
                self.disks = arr.map { d in
                    DiskItem(id: d["id"] as? String ?? "?", model: d["model"] as? String ?? "?",
                             serial: d["serial"] as? String ?? "", sizeGB: d["sizeGB"] as? Double ?? 0,
                             busProtocol: d["busProtocol"] as? String ?? "?", isSSD: d["isSSD"] as? Bool ?? false)
                }
                // Auto-switch when the previous disk is gone.
                if self.selectedDisk == nil || !self.disks.contains(where: { $0.id == self.selectedDisk?.id }) {
                    self.selectedDisk = self.disks.first
                }
                self.loadLayout()
            }
        }
    }

    /// Reset per-disk volatile state when the disk changes (auto or manual).
    private func handleDiskChanged() {
        scheme = "—"
        partitions = []
        selectedPart = nil
        lastResult = ""
        loadLayout()
    }

    func startPolling() {
        guard watcherId == nil else { return }
        watcherId = DiskWatcher.shared.register { [weak self] in
            guard let self, !self.busy else { return }
            self.refreshDisks()
        }
    }
    func stopPolling() { DiskWatcher.shared.unregister(watcherId); watcherId = nil }

    func loadLayout() {
        guard let disk = selectedDisk else { partitions = []; return }
        let diskID = disk.id
        Task.detached { [weak self] in
            let obj = EngineClient.shared.object(["partlist", "--disk", diskID])
            await MainActor.run {
                guard let self, let obj,
                      self.selectedDisk?.id == diskID   // user may have switched while we worked
                else { return }
                self.applyLayout(obj)
            }
        }
    }

    private func applyLayout(_ obj: [String: Any]) {
        scheme = obj["scheme"] as? String ?? "—"
        let raw = obj["partitions"] as? [[String: Any]] ?? []
        partitions = raw.map { p in
            let capsRaw = p["capabilities"] as? [String: Any] ?? [:]
            let caps = PartCaps(
                canFormat: capsRaw["canFormat"] as? Bool ?? true,
                canResize: capsRaw["canResize"] as? Bool ?? false,
                canDelete: capsRaw["canDelete"] as? Bool ?? false,
                canAddNext: capsRaw["canAddNext"] as? Bool ?? false,
                formatReason: capsRaw["formatReason"] as? String,
                resizeReason: capsRaw["resizeReason"] as? String,
                deleteReason: capsRaw["deleteReason"] as? String,
                addReason: capsRaw["addReason"] as? String
            )
            return PartItem(id: p["id"] as? String ?? "?", name: p["name"] as? String ?? "",
                            fs: p["fs"] as? String ?? "—", sizeBytes: p["sizeBytes"] as? Int64 ?? 0,
                            mount: p["mount"] as? String ?? "", apfsVolume: p["apfsVolume"] as? Bool ?? false,
                            caps: caps)
        }
    }

    // MARK: operations (async, run engine via sudo -n)

    func repartition(scheme: String, specs: [String]) {
        AppLog.shared.info("partition.repartition", "disk=\(selectedDisk?.id ?? "?") scheme=\(scheme) specs=\(specs)")
        op(["repartition", "--disk", selectedDisk?.id ?? "", "--scheme", scheme, "--specs", specs.joined(separator: ";")])
    }
    func format(volume: String, fs: String, name: String) {
        AppLog.shared.info("partition.format", "volume=\(volume) fs=\(fs) name=\(name)")
        op(["format", "--volume", volume, "--fs", fs, "--name", name])
    }
    func resize(volume: String, size: String, add: [String]) {
        let trimmed = size.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            lastOK = false
            lastResult = "✗ \(Loc.shared.t("part.resizeSizeRequired"))"
            AppLog.shared.error("partition.resize", "empty size; rejected before calling diskutil (volume=\(volume))")
            return
        }
        AppLog.shared.info("partition.resize", "volume=\(volume) size=\(trimmed) add=\(add)")
        var a = ["resize", "--volume", volume, "--size", trimmed]
        if !add.isEmpty { a += ["--add", add.joined(separator: ";")] }
        op(a)
    }
    func addVolume(volume: String, shrinkTo: String, fs: String, name: String) {
        let trimmed = shrinkTo.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            lastOK = false
            lastResult = "✗ \(Loc.shared.t("part.resizeSizeRequired"))"
            AppLog.shared.error("partition.addVolume", "empty shrinkTo (volume=\(volume))")
            return
        }
        AppLog.shared.info("partition.addVolume", "volume=\(volume) shrinkTo=\(trimmed) fs=\(fs) name=\(name)")
        op(["addvolume", "--volume", volume, "--shrinkto", trimmed, "--fs", fs, "--name", name])
    }
    func delete(volume: String) {
        AppLog.shared.info("partition.delete", "volume=\(volume)")
        op(["delpart", "--volume", volume])
    }

    private func op(_ args: [String]) {
        guard !busy else { return }
        busy = true; lastResult = Loc.shared.t("status.running")
        Task.detached { [weak self] in
            // operationTimeout (1 h), NOT the 60 s query default: formatting a
            // multi-TB volume routinely exceeds a minute, and the watchdog
            // terminating diskutil mid-write would corrupt the partition table.
            let r = EngineClient.shared.object(args, sudo: true,
                                               timeout: EngineClient.operationTimeout)
            _ = self  // keep weak-self semantics
            await MainActor.run {
                guard let self else { return }
                if let r {
                    self.lastOK = r["ok"] as? Bool ?? false
                    if self.lastOK {
                        let out = r["output"] as? String ?? Loc.shared.t("status.done")
                        self.lastResult = "✓ \(r["op"] as? String ?? "ok"): \(out)"
                        AppLog.shared.info("partition.op.ok", "op=\(r["op"] as? String ?? "?") output=\(out)")
                    } else {
                        let err = r["error"] as? String ?? Loc.shared.t("status.error")
                        self.lastResult = "✗ \(err)"
                        AppLog.shared.error("partition.op.fail", "op=\(r["op"] as? String ?? "?") error=\(err)")
                    }
                } else {
                    self.lastOK = false
                    self.lastResult = "✗ " + Loc.shared.t("status.noreply")
                    AppLog.shared.error("partition.op", "no JSON reply from engine for args=\(args)")
                }
                self.busy = false
                self.loadLayout()
            }
        }
    }

    // (P1.2) Local process helpers removed — see EngineClient.
}
