import Foundation
import Combine

/// Mutable line-assembly buffer for the stdout reader (accessed serially by the readability handler).
private final class LineBuffer { var data = Data() }

/// A disk as reported by `diskwipe-engine list`.
struct DiskItem: Identifiable, Hashable {
    let id: String
    let model: String
    let serial: String
    let sizeGB: Double
    let busProtocol: String
    let isSSD: Bool
    var label: String {
        String(format: "%@ — %@ (%.0f GB, %@%@)",
               id, model, sizeGB, busProtocol, isSSD ? ", SSD" : "")
    }
}

/// One phase of the pipeline, with progress + live speeds.
struct PhaseState: Identifiable {
    let id: String
    var title: String
    var status: String = "pending"   // pending / running / done / failed
    var percent: Double = 0
    var instMBps: Double = 0
    var avgMBps: Double = 0
    var etaSec: Double = 0
    var detail: String = ""
}

@MainActor
final class EngineRunner: ObservableObject {
    @Published var disks: [DiskItem] = []
    @Published var selected: DiskItem? { didSet { handleSelectionChanged(old: oldValue) } }
    @Published var mode: String = "full"          // full / quick
    @Published var doVerify = true
    @Published var doSmartLong = true
    @Published var doEject = true
    @Published var running = false
    @Published var phases: [PhaseState] = []
    @Published var log: [String] = []
    @Published var verdict: String = ""
    @Published var finished = false
    @Published var hasPastRun = false   // shows hint that this disk has a stored prior run

    /// Serials seen during this app session — used to trigger one auto-snapshot per insertion.
    private var seenSerials: Set<String> = []
    private var pollTimer: Timer?

    /// Canonical install path; falls back to local build for dev.
    private let enginePath: String = {
        let candidates = [
            "/usr/local/bin/diskwipe-engine",
            FileManager.default.currentDirectoryPath + "/.build/debug/diskwipe-engine",
            (NSHomeDirectory() as NSString).appendingPathComponent("src/diskwipe/.build/debug/diskwipe-engine")
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/usr/local/bin/diskwipe-engine"
    }()

    private var process: Process?

    /// Phase IDs in pipeline order. The user-visible titles come from `Loc` via
    /// `loc.t("phase.<id>")` in `PhaseRow`, so this list only carries identifiers
    /// — no hard-coded language here.
    private static let phaseTitles: [(String, String)] = [
        ("smart_pre", ""), ("unmount", ""), ("erase_full", ""), ("erase_quick", ""),
        ("verify", ""), ("smart_long", ""), ("finalize", ""), ("report", ""), ("eject", "")
    ]

    func refreshDisks() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: enginePath)
        p.arguments = ["list"]
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { appendLog("list failed: \(error)"); return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        let new = arr.map { d in
            DiskItem(
                id: d["id"] as? String ?? "?",
                model: d["model"] as? String ?? "?",
                serial: d["serial"] as? String ?? "",
                sizeGB: d["sizeGB"] as? Double ?? 0,
                busProtocol: d["busProtocol"] as? String ?? "?",
                isSSD: d["isSSD"] as? Bool ?? false
            )
        }
        if new != disks { disks = new }
        // If the currently-selected disk is no longer present (swapped/removed), pick the first available.
        if selected == nil || !disks.contains(where: { $0 == selected }) {
            selected = disks.first
        }
    }

    /// Start polling diskutil/engine list every 2 s so insertion/removal updates the UI live.
    func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.running else { return }
                self.refreshDisks()
            }
        }
    }
    func stopPolling() { pollTimer?.invalidate(); pollTimer = nil }

    /// Called when `selected` changes (manual pick or auto-pick on insertion).
    /// Resets stale run state, restores last persisted run for this disk, and
    /// triggers a one-shot history snapshot the first time this serial appears.
    private func handleSelectionChanged(old: DiskItem?) {
        guard !running else { return }
        // Reset live state (the previous disk's last-run is replaced below if present)
        phases = []; verdict = ""; log = []; finished = false
        hasPastRun = false
        guard let disk = selected else { return }
        loadLastRunIfAny(for: disk.serial)
        // Auto-snapshot — always ask the engine; its own throttle (1 per local day per serial,
        // file-existence-based) is the source of truth. The previous in-memory `seenSerials`
        // gate was a stale-cache trap: cleaning the history dir didn't reset it, so insertions
        // post-clean were silently skipped here without ever reaching the engine.
        if !disk.serial.isEmpty {
            let enginePath = self.enginePath
            let diskID = disk.id
            Task.detached { _ = Self.runSnapshotSync(enginePath: enginePath, diskID: diskID) }
        }
    }

    /// Fire a `snapshot` engine call in the background; result discarded (file already on disk).
    nonisolated static func runSnapshotSync(enginePath: String, diskID: String) -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", enginePath, "snapshot", "--disk", diskID, "--kind", "snapshot"]
        let pipe = Pipe(); let err = Pipe()
        p.standardOutput = pipe; p.standardError = err
        do { try p.run() } catch { return nil }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// Load most recent run log for the given serial (if any) into phases/log/verdict
    /// so re-inserting a disk shows what we did last time.
    private func loadLastRunIfAny(for serial: String) {
        guard !serial.isEmpty else { return }
        let dir = (NSHomeDirectory() as NSString)
            .appendingPathComponent("disk-reports/\(serial)/runlogs")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir),
              let latest = files.filter({ $0.hasSuffix(".json") }).sorted().last else { return }
        let path = (dir as NSString).appendingPathComponent(latest)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let v = obj["verdict"] as? String, !v.isEmpty { verdict = v }
        if let l = obj["log"] as? [String] { log = l }
        if let phaseArr = obj["phases"] as? [[String: Any]] {
            phases = phaseArr.map { p in
                PhaseState(id: p["id"] as? String ?? "?",
                           title: p["title"] as? String ?? "",
                           status: p["status"] as? String ?? "done",
                           percent: p["percent"] as? Double ?? 100,
                           detail: p["detail"] as? String ?? "")
            }
        }
        hasPastRun = !log.isEmpty || !phases.isEmpty
        if hasPastRun {
            appendLog("— Loaded prior run from \(obj["timestamp"] as? String ?? latest) —")
        }
    }

    /// Persist the just-finished run so it can be reloaded next time this disk is inserted.
    private func persistRun() {
        guard let serial = selected?.serial, !serial.isEmpty else { return }
        let dir = (NSHomeDirectory() as NSString)
            .appendingPathComponent("disk-reports/\(serial)/runlogs")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stamp = df.string(from: Date())
        let path = (dir as NSString).appendingPathComponent("\(stamp).json")
        let payload: [String: Any] = [
            "timestamp": stamp,
            "serial": serial,
            "mode": mode,
            "verdict": verdict,
            "phases": phases.map {
                ["id": $0.id, "title": $0.title, "status": $0.status,
                 "percent": $0.percent, "detail": $0.detail] as [String: Any]
            },
            "log": log
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private func buildPhases() {
        let relevantErase = mode == "full" ? "erase_full" : "erase_quick"
        phases = Self.phaseTitles.compactMap { key, title in
            if key == "erase_full" && mode != "full" { return nil }
            if key == "erase_quick" && mode != "quick" { return nil }
            if key == "verify" && (mode != "full" || !doVerify) { return nil }
            if key == "smart_long" && !doSmartLong { return nil }
            if key == "eject" && !doEject { return nil }
            _ = relevantErase
            return PhaseState(id: key, title: title)
        }
    }

    func start() {
        guard let disk = selected, !running else { return }
        running = true; finished = false; verdict = ""; log = []
        buildPhases()
        appendLog("→ \(disk.label)  [\(mode) erase]")

        var args = ["-n", enginePath, "run", "--disk", disk.id, "--mode", mode]
        if !doVerify { args += ["--no-verify"] }
        if !doSmartLong { args += ["--no-smart-long"] }
        if !doEject { args += ["--no-eject"] }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = args
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        process = p

        let lineBuf = LineBuffer()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let chunk = fh.availableData
            guard !chunk.isEmpty else { return }
            lineBuf.data.append(chunk)
            while let nl = lineBuf.data.firstIndex(of: 0x0A) {
                let lineData = lineBuf.data.subdata(in: lineBuf.data.startIndex..<nl)
                lineBuf.data.removeSubrange(lineBuf.data.startIndex...nl)
                if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                    Task { @MainActor in self?.handle(line: line) }
                }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            if let s = String(data: fh.availableData, encoding: .utf8), !s.isEmpty {
                Task { @MainActor in self?.appendLog("⚠️ " + s.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                self?.running = false
                self?.finished = true
                if proc.terminationStatus != 0 && self?.verdict.isEmpty == true {
                    self?.appendLog("engine exited \(proc.terminationStatus)")
                    AppLog.shared.error("engine.terminated", "exit=\(proc.terminationStatus)")
                }
            }
        }
        do { try p.run() } catch {
            appendLog("spawn failed: \(error)")
            AppLog.shared.error("engine.spawn", "failed: \(error) args=\(args)")
            running = false
        }
        AppLog.shared.info("engine.start", "disk=\(disk.id) mode=\(mode)")
    }

    func cancel() {
        process?.terminate()
    }

    // MARK: - Event handling

    private func handle(line: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["event"] as? String else {
            appendLog(line); return
        }
        switch type {
        case "phase":
            let name = obj["phase"] as? String ?? ""
            let status = obj["status"] as? String ?? ""
            let detail = obj["detail"] as? String ?? ""
            updatePhase(name) { ph in
                ph.status = status
                if !detail.isEmpty { ph.detail = detail }
                if status == "done" { ph.percent = 100 }
            }
            if !detail.isEmpty { appendLog("[\(name)] \(status): \(detail)") }
            else { appendLog("[\(name)] \(status)") }

        case "progress":
            let name = obj["phase"] as? String ?? ""
            updatePhase(name) { ph in
                ph.status = "running"
                ph.percent = obj["percent"] as? Double ?? ph.percent
                ph.instMBps = obj["instMBps"] as? Double ?? 0
                ph.avgMBps = obj["avgMBps"] as? Double ?? 0
                ph.etaSec = obj["etaSec"] as? Double ?? 0
            }

        case "done":
            verdict = obj["verdict"] as? String ?? ""
            appendLog("✓ DONE — \(verdict)")
            persistRun()

        case "error":
            let m = obj["message"] as? String ?? ""
            appendLog("ERROR: \(m)")
            AppLog.shared.error("engine.event", m)

        case "disk", "smart":
            break   // captured in report; not needed live

        default:
            appendLog(line)
        }
    }

    private func updatePhase(_ id: String, _ mutate: (inout PhaseState) -> Void) {
        if let i = phases.firstIndex(where: { $0.id == id }) {
            mutate(&phases[i])
        }
    }

    private func appendLog(_ s: String) {
        log.append(s)
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }
}
