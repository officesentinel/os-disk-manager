import Foundation

/// Per-disk history: each insertion or wipe creates a timestamped JSON snapshot
/// in ~/disk-reports/<serial>/<iso>.json. Latest-pointer files (<serial>.md/.html)
/// keep working in parallel as quick-access summaries.
enum Snapshot {
    static let schemaVersion = 1

    static var rootDir: String { Paths.reportsDir }
    static func diskDir(_ serial: String) -> String {
        (rootDir as NSString).appendingPathComponent(serial.isEmpty ? "unknown" : serial)
    }
    static func isoStamp() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return df.string(from: Date())
    }

    /// Capture current SMART + partition state for the given disk and persist as a snapshot.
    /// `kind` is "snapshot", "wipe", or "scan".
    /// Auto-snapshots ("snapshot") are throttled to once per local calendar day per disk
    /// to avoid noise from every program launch / disk re-insertion. Wipes and scans always write.
    @discardableResult
    static func write(diskID: String, kind: String,
                      wipeInfo: [String: Any]? = nil,
                      scanInfo: [String: Any]? = nil) -> [String: Any] {
        let info = DiskInfo.load(diskID)
        let node = info?.node ?? "/dev/\(diskID)"
        let smart = Smart.fullReport(node)
        let layout = Partitions.layout(diskID)

        // Bail out if SMART couldn't read anything — prevents "ghost" folders
        // named by deviceID (e.g. "disk4") with empty model/serial/attributes.
        let smartAttrs = (smart["attributes"] as? [Any]) ?? []
        let smartModel = (smart["model"] as? String) ?? ""
        let smartSerial = (smart["serial"] as? String) ?? ""
        if smartAttrs.isEmpty && (smartModel.isEmpty || smartModel == "—") && smartSerial.isEmpty {
            Logger.warn("snapshot",
                "skipped — SMART read returned no data for \(diskID) (bridge not ready or no FDA)")
            return ["skipped": true, "reason": "no-smart-data", "diskID": diskID]
        }

        // Authoritative serial AFTER the full SMART read (not the preliminary one
        // from smartctl -i, which may be empty when the bridge is half-awake and
        // falsely cause the throttle to look at the wrong folder).
        let serial = smartSerial.isEmpty ? diskID : smartSerial
        let dir = diskDir(serial)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        Paths.chownToUser(dir)

        // Throttle: any same-day record (snapshot/scan/wipe) means we already
        // have today's data for this disk. A redundant dashboard snapshot right
        // after a scan or wipe is noise. Wipe and Scan kinds are explicit user
        // events and always write; only auto-"snapshot" is throttled.
        if kind == "snapshot",
           let latest = latestSnapshotPath(serial: serial),
           let data = loadJSON(latest),
           let stamp = data["timestamp"] as? String,
           isSameLocalDay(stamp) {
            let prevKind = (data["kind"] as? String) ?? "?"
            Logger.info("snapshot",
                "skipped — same-day \(prevKind) already exists for serial=\(serial) at \(stamp)")
            return [
                "path": latest, "serial": serial, "kind": kind,
                "timestamp": stamp, "skipped": true, "reason": "already-snapshotted-today"
            ]
        }

        // Race protection: advisory flock on a per-day lock file. Multiple concurrent
        // tabs all spawn the engine; without this lock, two engine instances can both
        // see "no today file" and both write a dup.
        //
        // flock is preferred over mkdir(O_EXCL) because the kernel releases it
        // automatically when the process exits — even on SIGKILL — so a crashed
        // engine leaves no stale lock behind. (P1.1 fix.)
        let dayFmt2 = DateFormatter()
        dayFmt2.locale = Locale(identifier: "en_US_POSIX"); dayFmt2.dateFormat = "yyyy-MM-dd"
        let lockPath = (dir as NSString).appendingPathComponent(".lock-\(dayFmt2.string(from: Date()))")
        let lockFd = open(lockPath, O_CREAT | O_WRONLY, 0o644)
        if lockFd < 0 {
            // Can't even create the lock file — proceed without locking rather than
            // failing the whole snapshot. Worst case: rare concurrent dup.
            Logger.warn("snapshot", "couldn't open lock file \(lockPath): errno=\(errno)")
        } else if flock(lockFd, LOCK_EX | LOCK_NB) != 0 {
            close(lockFd)
            // Another live process is writing today's snapshot right now.
            Logger.info("snapshot", "skipped — flock held by concurrent writer for serial=\(serial)")
            let latest = latestSnapshotPath(serial: serial) ?? ""
            return ["skipped": true, "reason": "concurrent-write", "path": latest, "serial": serial]
        }
        defer {
            if lockFd >= 0 {
                _ = flock(lockFd, LOCK_UN)
                close(lockFd)
                // Best-effort cleanup of the lock file itself; harmless if it stays.
                _ = unlink(lockPath)
            }
        }

        var snap: [String: Any] = [
            "schemaVersion": schemaVersion,
            "timestamp": isoStamp(),
            "timestampEpoch": Date().timeIntervalSince1970,
            "kind": kind,
            "disk": diskBlock(info: info, smart: smart),
            "smart": smartBlock(smart),
            "partitions": layout,
            "verdict": verdictFor(smart: smart)
        ]
        if let wi = wipeInfo { snap["wipe"] = wi }
        if let si = scanInfo { snap["scan"] = si }

        let path = (dir as NSString).appendingPathComponent("\(isoStamp()).json")
        if let data = try? JSONSerialization.data(withJSONObject: snap, options: [.prettyPrinted, .sortedKeys]) {
            FileManager.default.createFile(atPath: path, contents: data)
            Paths.chownToUser(path)
        }
        return ["path": path, "serial": serial, "kind": kind, "timestamp": snap["timestamp"] ?? ""]
    }

    /// Compact disk identity block.
    private static func diskBlock(info: DiskInfo?, smart: [String: Any]) -> [String: Any] {
        return [
            "id": info?.id ?? "",
            "model": (smart["model"] as? String) ?? info?.model ?? "—",
            "serial": (smart["serial"] as? String) ?? info?.serial ?? "",
            "firmware": (smart["firmware"] as? String) ?? info?.firmware ?? "",
            "sizeBytes": (smart["sizeBytes"] as? Int64) ?? info?.sizeBytes ?? 0,
            "isSSD": (smart["isSSD"] as? Bool) ?? info?.isSSD ?? true,
            "interface": (smart["protocol"] as? String) ?? info?.busProtocol ?? ""
        ]
    }
    /// Carry the entire SMART dict into the snapshot. Earlier versions filtered to a small set,
    /// which meant new fields (dramCache, nand, plp, tbwPerTb, dataSource, family, tier,
    /// trim/discard/sanitize info, formFactor, …) were silently dropped. We now keep everything
    /// so historical snapshots are visually complete after later code additions too.
    private static func smartBlock(_ smart: [String: Any]) -> [String: Any] {
        return smart
    }

    private static func verdictFor(smart: [String: Any]) -> String {
        let passed = smart["healthPassed"] as? Bool ?? true
        if !passed { return "🔴 FAILING — do not use" }
        let attrs = smart["attributes"] as? [[String: Any]] ?? []
        let bad = attrs.filter { [5, 187, 197, 198].contains($0["id"] as? Int ?? 0) }
            .reduce(0) { $0 + ($1["raw"] as? Int ?? 0) }
        if bad > 0 { return "🟠 Caution — \(bad) bad sectors" }
        let hours = smart["powerOnHours"] as? Int ?? 0
        if hours > 30000 { return "🟢 Healthy (aged) — use as expendable" }
        return "🟢 Healthy"
    }

    // MARK: history queries

    /// All disks ever recorded (each = a serial subdirectory containing at least one snapshot).
    static func listDisks() -> [[String: Any]] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: rootDir) else { return [] }
        var disks: [[String: Any]] = []
        for entry in entries {
            let full = (rootDir as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }
            if entry.hasPrefix(".") { continue }
            let snaps = snapshotFiles(in: full)
            guard let latest = snaps.last, let latestData = loadJSON(latest) else { continue }
            let disk = latestData["disk"] as? [String: Any] ?? [:]
            let smart = latestData["smart"] as? [String: Any] ?? [:]
            disks.append([
                "serial": entry,
                "model": disk["model"] ?? "—",
                "interface": disk["interface"] ?? "",
                "sizeBytes": disk["sizeBytes"] ?? 0,
                "isSSD": disk["isSSD"] ?? true,
                "lastSeen": latestData["timestamp"] ?? "",
                "lastSeenEpoch": latestData["timestampEpoch"] ?? 0,
                "snapshotCount": snaps.count,
                "latestVerdict": latestData["verdict"] ?? "—",
                "latestHealth": smart["healthPassed"] ?? true,
                "latestLife": smart["lifeLeftPercent"] ?? NSNull(),
                "latestTemp": smart["temperatureC"] ?? 0,
                "latestPOH": smart["powerOnHours"] ?? 0
            ])
        }
        // Sort by last seen descending
        disks.sort { ($0["lastSeenEpoch"] as? Double ?? 0) > ($1["lastSeenEpoch"] as? Double ?? 0) }
        return disks
    }

    /// All snapshots for one serial, sorted oldest -> newest. Returns compact summary objects.
    static func listSnapshots(serial: String) -> [[String: Any]] {
        let dir = diskDir(serial)
        let files = snapshotFiles(in: dir)
        return files.compactMap { path -> [String: Any]? in
            guard let d = loadJSON(path) else { return nil }
            let smart = d["smart"] as? [String: Any] ?? [:]
            let attrs = smart["attributes"] as? [[String: Any]] ?? []
            let defects = attrs.filter { [5, 187, 197, 198].contains($0["id"] as? Int ?? 0) }
                .reduce(0) { $0 + ($1["raw"] as? Int ?? 0) }
            return [
                "path": path,
                "timestamp": d["timestamp"] ?? "",
                "timestampEpoch": d["timestampEpoch"] ?? 0,
                "kind": d["kind"] ?? "snapshot",
                "verdict": d["verdict"] ?? "—",
                "healthPassed": smart["healthPassed"] ?? true,
                "lifeLeftPercent": smart["lifeLeftPercent"] ?? NSNull(),
                "wearPercentUsed": smart["wearPercentUsed"] ?? NSNull(),
                "temperatureC": smart["temperatureC"] ?? 0,
                "temperatureMaxC": smart["temperatureMaxC"] ?? NSNull(),
                "powerOnHours": smart["powerOnHours"] ?? 0,
                "powerCycles": smart["powerCycles"] ?? 0,
                "defects": defects
            ]
        }
    }

    /// Load a single snapshot file's full JSON.
    static func loadSnapshot(path: String) -> [String: Any]? { loadJSON(path) }

    /// Newest snapshot file path for a given serial (or nil if none).
    private static func latestSnapshotPath(serial: String) -> String? {
        snapshotFiles(in: diskDir(serial)).last
    }

    /// True if the snapshot's timestamp ("yyyy-MM-dd_HH-mm-ss") is in the same
    /// local calendar day as `Date()`.
    private static func isSameLocalDay(_ stamp: String) -> Bool {
        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.dateFormat = "yyyy-MM-dd"
        return stamp.hasPrefix(dayFmt.string(from: Date()))
    }

    private static func snapshotFiles(in dir: String) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        return entries.filter { $0.hasSuffix(".json") }
            .sorted()
            .map { (dir as NSString).appendingPathComponent($0) }
    }
    private static func loadJSON(_ path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
