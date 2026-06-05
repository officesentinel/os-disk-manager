import Foundation
import Combine
import AppKit

struct SmartAttr: Identifiable {
    let id: Int
    let name: String
    let value: Int
    let worst: Int
    let thresh: Int
    let raw: Int
    let rawString: String
    let whenFailed: String
    let status: String   // ok / warn / fail
}

struct SmartReport {
    var model = "—"
    var serial = ""
    var firmware = ""
    var sizeBytes: Int64 = 0
    var isSSD = true
    var proto = ""
    var healthPassed: Bool?
    var temperatureC = 0
    var temperatureMaxC: Int?
    var lifeLeftPercent: Int?
    var wearPercentUsed: Int?
    var powerOnHours = 0
    var powerCycles = 0
    var trimSupported: Bool?      // nil = no data
    var trimDetail: String?       // e.g. "deterministic, zeroed"
    var trimLevel: String?        // "DZAT" | "DRAT" | "basic" | nil
    var tier: String?             // "enterprise" | "consumer" | "unknown" | nil
    var tierReason: String?       // human-readable signal that led to the classification
    var formFactor: String?
    var discardMechanism: String? // "TRIM" / "Deallocate" / "UNMAP"
    var sanitizeMethods: [String] = []
    var dramCache: Bool?          // nil = unknown
    var dramCacheReason: String?
    var nandType: String?         // "TLC" / "MLC" / "QLC" / "SLC" / null
    var controller: String?
    var plp: Bool?                // power-loss protection
    var tbwPerTb: Int?            // rated TBW per 1 TB of capacity
    var family: String?           // marketing family from DB
    var dataSource: String?       // "OurDB" / "smartctl" / "none"
    var attributes: [SmartAttr] = []
}

@MainActor
final class DiskHealth: ObservableObject {
    @Published var disks: [DiskItem] = []
    @Published var selected: DiskItem? { didSet { if oldValue != selected { load() } } }
    private var watcherId: UUID?
    @Published var report: SmartReport?
    @Published var partitions: [PartItem] = []
    @Published var scheme = "—"
    @Published var totalBytes: Int64 = 0
    @Published var loading = false
    @Published var lastError: String?
    @Published var exporting = false
    @Published var exportMessage: String?

    // Engine path resolved once; the actual spawning is delegated to EngineClient. (P1.2)
    private var enginePath: String { EngineClient.shared.enginePath }

    func refreshDisks() {
        guard let arr = EngineClient.shared.array(["list"]) else { return }
        disks = arr.map { d in
            DiskItem(id: d["id"] as? String ?? "?", model: d["model"] as? String ?? "?",
                     serial: d["serial"] as? String ?? "", sizeGB: d["sizeGB"] as? Double ?? 0,
                     busProtocol: d["busProtocol"] as? String ?? "?", isSSD: d["isSSD"] as? Bool ?? false)
        }
        // Auto-switch selection if the previous disk was ejected.
        if selected == nil || !disks.contains(where: { $0.id == selected?.id }) {
            selected = disks.first
        } else {
            load()
        }
    }

    func startPolling() {
        guard watcherId == nil else { return }
        watcherId = DiskWatcher.shared.register { [weak self] in
            guard let self, !self.loading, !self.exporting else { return }
            self.refreshDisks()
        }
    }
    func stopPolling() { DiskWatcher.shared.unregister(watcherId); watcherId = nil }

    func load() {
        guard let disk = selected else { report = nil; partitions = []; return }
        loading = true
        // Fire an auto-snapshot whenever the dashboard inspects a disk. The engine
        // throttles to 1/day/serial — duplicate calls are cheap and harmless.
        let diskID = disk.id
        Task.detached {
            _ = EngineClient.shared.runRaw(["snapshot", "--disk", diskID, "--kind", "snapshot"], sudo: true)
        }
        Task.detached { [weak self] in
            guard let self else { return }
            // Retry up to 3 attempts with exponential backoff. First attempt sometimes
            // returns empty: USB bridge waking, sudo session setting up, or transient
            // smartctl flakiness. Backoff stays short so the success case is instant.
            var smart: [String: Any]? = nil
            for attempt in 1...3 {
                smart = EngineClient.shared.object(["smart", "--disk", disk.id], sudo: true)
                let ok = ((smart?["model"] as? String).map { $0 != "—" && !$0.isEmpty }) ?? false
                if ok {
                    if attempt > 1 {
                        AppLog.shared.info("dash.load", "smart ok on attempt \(attempt) for disk=\(disk.id)")
                    }
                    break
                }
                AppLog.shared.warn("dash.load",
                    "smart attempt \(attempt) returned empty/invalid for disk=\(disk.id) — retrying")
                if attempt < 3 { Thread.sleep(forTimeInterval: 0.5 * Double(attempt)) }
            }
            let layout = EngineClient.shared.object(["partlist", "--disk", disk.id])
            await MainActor.run {
                if let s = smart, (s["model"] as? String).map({ $0 != "—" }) ?? false {
                    self.report = Self.parse(s); self.lastError = nil
                } else {
                    self.report = nil
                    self.lastError = Loc.shared.t("dash.fdaHint")
                    AppLog.shared.error("dash.load", "smart returned empty for disk=\(disk.id) — likely missing Full Disk Access")
                }
                if let l = layout {
                    self.scheme = l["scheme"] as? String ?? "—"
                    self.totalBytes = l["sizeBytes"] as? Int64 ?? 0
                    let raw = l["partitions"] as? [[String: Any]] ?? []
                    self.partitions = raw.map { p in
                        PartItem(id: p["id"] as? String ?? "?", name: p["name"] as? String ?? "",
                                 fs: p["fs"] as? String ?? "—", sizeBytes: p["sizeBytes"] as? Int64 ?? 0,
                                 mount: p["mount"] as? String ?? "", apfsVolume: p["apfsVolume"] as? Bool ?? false)
                    }
                }
                self.loading = false
            }
        }
    }

    /// Export full analytics (md + html) to ~/disk-reports, then reveal in Finder.
    func exportReport() {
        guard let disk = selected, !exporting else { return }
        exporting = true; exportMessage = Loc.shared.t("export.saving")
        Task.detached { [weak self] in
            guard let self else { return }
            let r = EngineClient.shared.object(["export", "--disk", disk.id, "--format", "all"], sudo: true)
            await MainActor.run {
                self.exporting = false
                if let r {
                    let written = [r["md"], r["html"], r["json"]].compactMap { $0 as? String }
                    let errors = r["errors"] as? [String] ?? []
                    if !written.isEmpty && errors.isEmpty {
                        // Full success — show file names + reveal in Finder.
                        self.exportMessage = "✓ " + Loc.shared.t("export.saved",
                            written.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                        if let preferred = (r["html"] as? String) ?? (r["md"] as? String) ?? (r["json"] as? String) {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: preferred)])
                        }
                    } else if !written.isEmpty {
                        // Partial success — saved some, failed others. (P1.3)
                        self.exportMessage = "⚠️ partial: saved \(written.count), failed " + errors.joined(separator: " · ")
                        AppLog.shared.warn("dash.export", "partial save: errors=\(errors)")
                    } else {
                        // Full failure — show details from engine, not just generic "failed".
                        let details = errors.isEmpty ? Loc.shared.t("export.failed") : errors.joined(separator: " · ")
                        self.exportMessage = "✗ " + details
                        AppLog.shared.error("dash.export", "failed: \(errors)")
                    }
                } else {
                    self.exportMessage = "✗ " + Loc.shared.t("export.failed")
                    AppLog.shared.error("dash.export", "no JSON reply from engine")
                }
            }
        }
    }

    private static func parse(_ d: [String: Any]) -> SmartReport {
        var r = SmartReport()
        r.model = d["model"] as? String ?? "—"
        r.serial = d["serial"] as? String ?? ""
        r.firmware = d["firmware"] as? String ?? ""
        r.sizeBytes = d["sizeBytes"] as? Int64 ?? 0
        r.isSSD = d["isSSD"] as? Bool ?? true
        r.proto = d["protocol"] as? String ?? ""
        r.healthPassed = d["healthPassed"] as? Bool
        r.temperatureC = d["temperatureC"] as? Int ?? 0
        r.temperatureMaxC = d["temperatureMaxC"] as? Int
        r.lifeLeftPercent = d["lifeLeftPercent"] as? Int
        r.wearPercentUsed = d["wearPercentUsed"] as? Int
        r.powerOnHours = d["powerOnHours"] as? Int ?? 0
        r.powerCycles = d["powerCycles"] as? Int ?? 0
        r.trimSupported = d["trimSupported"] as? Bool
        r.trimDetail = d["trimDetail"] as? String
        r.trimLevel = d["trimLevel"] as? String
        r.tier = d["tier"] as? String
        r.tierReason = d["tierReason"] as? String
        r.formFactor = d["formFactor"] as? String
        r.discardMechanism = d["discardMechanism"] as? String
        r.sanitizeMethods = d["sanitizeMethods"] as? [String] ?? []
        r.dramCache = d["dramCache"] as? Bool
        r.dramCacheReason = d["dramCacheReason"] as? String
        r.nandType = d["nandType"] as? String
        r.controller = d["controller"] as? String
        r.plp = d["plp"] as? Bool
        r.tbwPerTb = d["tbwPerTb"] as? Int
        r.family = d["family"] as? String
        r.dataSource = d["dataSource"] as? String
        let attrs = d["attributes"] as? [[String: Any]] ?? []
        r.attributes = attrs.map { a in
            SmartAttr(id: a["id"] as? Int ?? 0, name: a["name"] as? String ?? "",
                      value: a["value"] as? Int ?? 0, worst: a["worst"] as? Int ?? 0,
                      thresh: a["thresh"] as? Int ?? 0, raw: a["raw"] as? Int ?? 0,
                      rawString: a["rawString"] as? String ?? "", whenFailed: a["whenFailed"] as? String ?? "",
                      status: a["status"] as? String ?? "ok")
        }
        return r
    }

    // (P1.2) Process spawn helpers used to live here; they now live in EngineClient.
}
