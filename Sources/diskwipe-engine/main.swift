import Foundation

// diskwipe-engine — root-side worker. Emits newline-delimited JSON events.
//
// Usage:
//   diskwipe-engine list
//   diskwipe-engine run --disk diskN --mode full|quick
//        [--no-verify] [--no-smart-long] [--no-eject] [--force-internal] [--text]

func parseArgs(_ args: [String]) -> [String: String] {
    var out: [String: String] = [:]
    var i = 0
    while i < args.count {
        let a = args[i]
        if a.hasPrefix("--") {
            let key = String(a.dropFirst(2))
            if i + 1 < args.count && !args[i+1].hasPrefix("--") {
                out[key] = args[i+1]; i += 2
            } else { out[key] = "true"; i += 1 }
        } else { i += 1 }
    }
    return out
}

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else {
    FileHandle.standardError.write("usage: diskwipe-engine <list|run> [opts]\n".data(using: .utf8)!)
    exit(2)
}
let opts = parseArgs(Array(argv.dropFirst()))
Logger.info("engine", "start command=\(command) opts=\(opts) euid=\(geteuid())")
if opts["text"] == "true" { Emit.jsonMode = false }

func verdict(post: SmartSnapshot, disk: DiskInfo) -> String {
    if post.healthPassed == false { return "🔴 FAILING — do not use" }
    let bad = (post.reallocated ?? 0) + (post.pending ?? 0)
            + (post.offlineUncorrectable ?? 0) + (post.reportedUncorrect ?? 0)
    if bad > 0 { return "🟠 Caution — \(bad) bad sectors, monitor closely" }
    let hours = post.powerOnHours ?? 0
    if hours > 30000 { return "🟢 Healthy (aged) — high uptime, use as expendable" }
    return "🟢 Healthy"
}

switch command {
case "list":
    let disks = DiskInfo.listExternal().map { $0.dictionary }
    if let data = try? JSONSerialization.data(withJSONObject: disks),
       let s = String(data: data, encoding: .utf8) { print(s) }

case "run":
    guard let id = opts["disk"] else { Emit.error("missing --disk"); exit(2) }
    let mode = opts["mode"] ?? "full"
    guard geteuid() == 0 else { Emit.error("must run as root"); exit(1) }
    guard let disk = DiskInfo.load(id) else { Emit.error("cannot load \(id)"); exit(1) }

    // Safety: never touch internal disks unless explicitly forced.
    if disk.isInternal && opts["force-internal"] != "true" {
        Emit.error("refusing internal disk \(id) (use --force-internal to override)")
        exit(1)
    }
    // Safety: BSD disk numbers are reused across unplug/replug, so "disk4" may
    // now be a different physical disk than the one the user selected in the
    // GUI. The GUI pins the expected serial; mismatch aborts before any write.
    if let expected = opts["serial"], !expected.isEmpty, disk.serial != expected {
        Emit.error("serial mismatch on \(id): expected \(expected), found \(disk.serial.isEmpty ? "<none>" : disk.serial) — disk was swapped, aborting")
        exit(1)
    }
    Emit.event("disk", disk.dictionary)
    Emit.phase("start", status: "begin", detail: "\(disk.model) \(disk.serial) — \(mode) erase")

    // Prevent system/display/disk sleep for the whole pipeline.
    // `-w <our pid>` makes caffeinate exit on its own when this process dies
    // for ANY reason — including SIGTERM/SIGKILL, where `defer` never runs.
    // Without it, a cancelled wipe leaves an orphan caffeinate keeping the
    // Mac awake until reboot.
    let caffeinate = Process()
    caffeinate.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
    caffeinate.arguments = ["-dims", "-w", String(ProcessInfo.processInfo.processIdentifier)]
    try? caffeinate.run()
    Logger.info("engine", "caffeinate -dims -w \(ProcessInfo.processInfo.processIdentifier) started pid=\(caffeinate.processIdentifier)")
    defer {
        if caffeinate.isRunning { caffeinate.terminate() }
        Logger.info("engine", "caffeinate stopped")
    }

    // 1. SMART pre
    Emit.phase("smart_pre", status: "start")
    let pre = Smart.snapshot(disk.node)
    Emit.event("smart", ["when": "pre"].merging(pre.dictionary) { _, b in b })
    Emit.phase("smart_pre", status: "done",
               detail: pre.healthPassed == true ? "PASSED" : "see attrs")

    // 2. Unmount — check the result: if a volume stays mounted, the raw-device
    // open below typically fails with EBUSY and the user gets a cryptic errno.
    // Surface the real cause here instead.
    Emit.phase("unmount", status: "start")
    let unmountRes = Shell.run(Shell.diskutil, ["unmountDisk", "force", disk.node])
    if unmountRes.ok {
        Emit.phase("unmount", status: "done")
    } else {
        Emit.phase("unmount", status: "failed",
                   detail: unmountRes.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        Emit.error("unmountDisk failed — volume in use? \(unmountRes.stderr.prefix(200))")
        exit(1)
    }

    var eraseSummary = "—", verifySummary = "skipped", longSummary = "skipped"
    var eraseSpeed: SpeedSnapshot? = nil
    var verifySpeed: SpeedSnapshot? = nil

    do {
        // 3. Erase
        let eraseStart = Date()
        if mode == "quick" {
            try Operations.quickErase(disk)
            eraseSummary = "quick (headers + TRIM)"
        } else {
            let s = try Operations.fullErase(disk)
            eraseSpeed = s
            eraseSummary = "full zero-fill ✓ in \(Emit.formatETA(Date().timeIntervalSince(eraseStart))) — \(s.summary)"
        }

        // 4. Verify (full mode only, unless disabled)
        if mode == "full" && opts["no-verify"] != "true" {
            let s = try Operations.verifyZero(disk)
            verifySpeed = s
            verifySummary = "✓ 0 non-zero bytes — \(s.summary)"
        }
    } catch {
        Emit.error("\(error)")
        exit(1)
    }

    // 5. SMART long self-test — emit speed (estimated MB/s) derived from %-progress over time.
    if opts["no-smart-long"] != "true" {
        Emit.phase("smart_long", status: "start")
        if let mins = Smart.startLongTest(disk.node) {
            Emit.phase("smart_long", status: "running", detail: "~\(mins) min")
            let testStart = Date()
            // Hard deadline: 3× the firmware estimate, floor 1 h. Protects
            // against a wedged USB bridge reporting "in progress" forever.
            let deadline = testStart.addingTimeInterval(max(3600, Double(mins) * 60 * 3))
            var lastRemaining: Int? = nil
            var lastBumpTime = testStart
            var instBps: Double = 0
            var done = false
            var timedOut = false
            while !done {
                Thread.sleep(forTimeInterval: 15)
                if Date() > deadline {
                    Emit.phase("smart_long", status: "failed",
                               detail: "timeout after \(Emit.formatETA(Date().timeIntervalSince(testStart))) — bridge wedged?")
                    longSummary = "timed out (no firmware progress)"
                    timedOut = true
                    break
                }
                let p = Smart.longTestProgress(disk.node)
                if p.inProgress {
                    let now = Date()
                    let pctDone = Double(100 - p.remainingPercent)
                    let bytesDone = Int64(Double(disk.sizeBytes) * pctDone / 100.0)
                    let elapsed = now.timeIntervalSince(testStart)
                    let avgBps = elapsed > 0 ? Double(bytesDone) / elapsed : 0
                    // Update inst on each percent-bump (firmware reports in ~10% steps).
                    if let last = lastRemaining, p.remainingPercent < last {
                        let dPct = Double(last - p.remainingPercent)
                        let dT = now.timeIntervalSince(lastBumpTime)
                        if dT > 0 { instBps = Double(disk.sizeBytes) * (dPct / 100.0) / dT }
                        lastBumpTime = now
                    } else if lastRemaining == nil {
                        instBps = avgBps   // seed
                    }
                    lastRemaining = p.remainingPercent
                    let etaSec = avgBps > 0 ? Double(disk.sizeBytes - bytesDone) / avgBps : 0
                    Emit.progress(phase: "smart_long",
                                  bytesDone: bytesDone,
                                  bytesTotal: disk.sizeBytes,
                                  instBps: instBps, avgBps: avgBps, etaSec: etaSec)
                } else { done = true }
            }
            if !timedOut {
                longSummary = Smart.lastSelfTestResult(disk.node)
                Emit.phase("smart_long", status: "done", detail: longSummary)
            }
        } else {
            longSummary = "could not start"
            Emit.phase("smart_long", status: "failed")
        }
    }

    // 6. Empty GPT
    Emit.phase("finalize", status: "start", detail: "empty GPT")
    _ = Shell.run(Shell.diskutil, ["eraseDisk", "free", "EMPTY", "GPT", disk.id])
    Emit.phase("finalize", status: "done")

    // 7. SMART post + report
    let post = Smart.snapshot(disk.node)
    Emit.event("smart", ["when": "post"].merging(post.dictionary) { _, b in b })
    let v = verdict(post: post, disk: disk)
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
    Reporter.write(.init(disk: disk, mode: mode, pre: pre, post: post,
                         eraseSummary: eraseSummary, verifySummary: verifySummary,
                         longTestSummary: longSummary, verdict: v,
                         date: df.string(from: Date())))
    // Append a wipe entry to history (per-timestamp JSON snapshot for this disk).
    var wipeInfo: [String: Any] = [
        "mode": mode,
        "eraseSummary": eraseSummary,
        "verifySummary": verifySummary,
        "longTestSummary": longSummary
    ]
    if let e = eraseSpeed { wipeInfo["eraseSpeed"] = e.dictionary }
    if let v = verifySpeed { wipeInfo["verifySpeed"] = v.dictionary }
    let snapRes = Snapshot.write(diskID: disk.id, kind: "wipe", wipeInfo: wipeInfo)
    Emit.phase("report", status: "done",
               detail: "~/disk-reports/\(disk.serial).md  +  \(snapRes["path"] ?? "")")

    // 8. Eject
    if opts["no-eject"] != "true" {
        Emit.phase("eject", status: "start")
        _ = Shell.run(Shell.diskutil, ["eject", disk.node])
        Emit.phase("eject", status: "done", detail: "safe to unplug")
    }

    Emit.event("done", ["verdict": v, "report": "\(disk.serial).md"])

case "partlist":
    guard let id = opts["disk"] else { Emit.error("missing --disk"); exit(2) }
    let layout = Partitions.layout(id)
    if let data = try? JSONSerialization.data(withJSONObject: layout),
       let s = String(data: data, encoding: .utf8) { print(s) }

case "smart":
    guard let id = opts["disk"] else { Emit.error("missing --disk"); exit(2) }
    var report = Smart.fullReport(DiskInfo.load(id)?.node ?? "/dev/\(id)")
    report["disk"] = id
    if let data = try? JSONSerialization.data(withJSONObject: report),
       let s = String(data: data, encoding: .utf8) { print(s) }

case "scan":
    guard let id = opts["disk"] else { Emit.error("missing --disk"); exit(2) }
    guard geteuid() == 0 else { Emit.error("must run as root"); exit(1) }
    guard let disk = DiskInfo.load(id) else { Emit.error("cannot load \(id)"); exit(1) }
    let smode = opts["mode"] ?? "read"
    let thresh = Double(opts["threshold"] ?? "200") ?? 200
    let blk = Int(opts["block"] ?? "4") ?? 4
    // Prevent sleep during the scan as well.
    let caffeinateScan = Process()
    caffeinateScan.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
    // `-w <pid>`: self-exit when the engine dies, incl. SIGTERM where defer never runs.
    caffeinateScan.arguments = ["-dims", "-w", String(ProcessInfo.processInfo.processIdentifier)]
    try? caffeinateScan.run()
    defer { if caffeinateScan.isRunning { caffeinateScan.terminate() } }
    do {
        let scanResult = try Scan.surface(disk, mode: smode, thresholdMs: thresh, blockMiB: blk)
        // Persist scan results into history as a "scan" snapshot so they show in the History tab.
        let snapRes = Snapshot.write(diskID: id, kind: "scan", scanInfo: scanResult)
        Emit.phase("scan_history", status: "done",
                   detail: "saved snapshot: \(snapRes["path"] ?? "")")
    } catch { Emit.error("\(error)"); exit(1) }

case "export":
    guard let id = opts["disk"] else { Emit.error("missing --disk"); exit(2) }
    let fmt = opts["format"] ?? "both"
    let written = ReportExport.export(diskID: id, format: fmt)
    Emit.event("exported", written)

case "snapshot":
    guard let id = opts["disk"] else { Emit.error("missing --disk"); exit(2) }
    let result = Snapshot.write(diskID: id, kind: opts["kind"] ?? "snapshot")
    if let data = try? JSONSerialization.data(withJSONObject: result),
       let s = String(data: data, encoding: .utf8) { print(s) }

case "history":
    if let serial = opts["serial"] {
        let list = Snapshot.listSnapshots(serial: serial)
        if let data = try? JSONSerialization.data(withJSONObject: list),
           let s = String(data: data, encoding: .utf8) { print(s) }
    } else if let path = opts["path"] {
        if let d = Snapshot.loadSnapshot(path: path),
           let data = try? JSONSerialization.data(withJSONObject: d),
           let s = String(data: data, encoding: .utf8) { print(s) }
    } else {
        let list = Snapshot.listDisks()
        if let data = try? JSONSerialization.data(withJSONObject: list),
           let s = String(data: data, encoding: .utf8) { print(s) }
    }

case "repartition", "format", "resize", "addvolume", "delpart":
    func finish(_ r: ShellResult, _ label: String) {
        if r.ok {
            Emit.event("opresult", ["op": label, "ok": true,
                                    "output": r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)])
        } else {
            Emit.event("opresult", ["op": label, "ok": false,
                                    "error": (r.stderr + r.stdout).trimmingCharacters(in: .whitespacesAndNewlines)])
            exit(1)
        }
    }
    // Safety: the engine sits behind a NOPASSWD sudoers grant, so IT is the
    // privilege boundary — not the GUI. Without this guard, any process could
    // run `sudo -n diskwipe-engine repartition --disk disk0 …` and destroy
    // the boot disk's partition table. Volume ids ("disk4s2") resolve to
    // their parent whole-disk ("disk4") before the check.
    func refuseInternal(_ target: String) {
        let parent: String
        if let r = target.range(of: #"^disk\d+"#, options: .regularExpression) {
            parent = String(target[r])
        } else {
            parent = target
        }
        guard let info = DiskInfo.load(parent) else {
            Emit.error("cannot load \(parent) to verify it is external — refusing")
            exit(1)
        }
        if info.isInternal && opts["force-internal"] != "true" {
            Emit.error("refusing \(command) on internal disk \(parent) (use --force-internal to override)")
            exit(1)
        }
    }
    switch command {
    case "repartition":
        guard let disk = opts["disk"], let spec = opts["specs"] else { Emit.error("need --disk --specs"); exit(2) }
        refuseInternal(disk)
        let scheme = opts["scheme"] ?? "GPT"
        finish(Partitions.repartition(disk: disk, scheme: scheme,
                                      specs: spec.split(separator: ";").map(String.init)), "repartition")
    case "format":
        guard let vol = opts["volume"], let fs = opts["fs"] else { Emit.error("need --volume --fs"); exit(2) }
        refuseInternal(vol)
        finish(Partitions.format(volume: vol, fs: fs, name: opts["name"] ?? "Untitled"), "format")
    case "resize":
        guard let vol = opts["volume"], let size = opts["size"] else { Emit.error("need --volume --size"); exit(2) }
        refuseInternal(vol)
        let add = (opts["add"] ?? "").isEmpty ? [] : opts["add"]!.split(separator: ";").map(String.init)
        finish(Partitions.resize(volume: vol, size: size, add: add), "resize")
    case "addvolume":
        guard let vol = opts["volume"], let shrink = opts["shrinkto"], let fs = opts["fs"]
        else { Emit.error("need --volume --shrinkto --fs"); exit(2) }
        refuseInternal(vol)
        finish(Partitions.addVolume(volume: vol, shrinkTo: shrink, fs: fs, name: opts["name"] ?? "Untitled"), "addvolume")
    case "delpart":
        guard let vol = opts["volume"] else { Emit.error("need --volume"); exit(2) }
        refuseInternal(vol)
        finish(Partitions.delete(volume: vol), "delpart")
    default: break
    }

default:
    Emit.error("unknown command \(command)")
    exit(2)
}
