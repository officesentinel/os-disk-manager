import Foundation

/// Single point of contact for engine invocations from the GUI.
///
/// Replaces five ad-hoc copies of the `Process + Pipe + sudo -n` pattern that
/// used to live in `DiskHealth`, `EngineRunner`, `ScanRunner`,
/// `PartitionManager` and `HistoryManager`. Future infrastructure changes
/// (e.g. moving from `sudo -n` to an XPC privileged helper for Phase 3) now
/// touch one file instead of five. (P1.2 refactor.)
///
/// All synchronous calls are nonisolated so they can be invoked from any
/// queue / actor; do not call from the main thread for long-running engine
/// commands.
final class EngineClient: @unchecked Sendable {
    static let shared = EngineClient()

    /// Canonical install path; falls back to local build for development.
    let enginePath: String = {
        let candidates = [
            "/usr/local/bin/diskwipe-engine",
            (NSHomeDirectory() as NSString).appendingPathComponent("src/diskwipe/.build/release/diskwipe-engine"),
            (NSHomeDirectory() as NSString).appendingPathComponent("src/diskwipe/.build/debug/diskwipe-engine"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/usr/local/bin/diskwipe-engine"
    }()

    /// Run engine with given args. If `sudo` is true, prepends `sudo -n`.
    /// Returns raw stdout `Data`, captured stderr, and exit code.
    func runRaw(_ args: [String], sudo: Bool = false, timeout: TimeInterval = 60) -> (stdout: Data, stderr: Data, exit: Int32) {
        let p = Process()
        if sudo {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            p.arguments = ["-n", enginePath] + args
        } else {
            p.executableURL = URL(fileURLWithPath: enginePath)
            p.arguments = args
        }
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        do {
            try p.run()
        } catch {
            AppLog.shared.error("engine.client", "spawn failed: \(error) args=\(args)")
            return (Data(), Data(), -1)
        }

        // Read fully before waitUntilExit to avoid pipe-buffer deadlock on big outputs.
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        if p.terminationStatus != 0 {
            let errStr = String(data: err, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            AppLog.shared.warn("engine.client",
                "non-zero exit \(p.terminationStatus) args=\(args) stderr=\(errStr.prefix(200))")
        }
        return (out, err, p.terminationStatus)
    }

    /// Run engine and return the most recent valid JSON object on stdout.
    /// The engine may emit several events; we keep the last parseable line —
    /// engine command results (snapshot, opresult, exported) are always the
    /// final line.
    func object(_ args: [String], sudo: Bool = false) -> [String: Any]? {
        let r = runRaw(args, sudo: sudo)
        let text = String(data: r.stdout, encoding: .utf8) ?? ""
        for line in text.split(separator: "\n").reversed() {
            if let ld = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: ld) as? [String: Any] {
                return obj
            }
        }
        return nil
    }

    /// Run engine and return its stdout as a JSON array (for `list` / `partlist.partitions`).
    func array(_ args: [String], sudo: Bool = false) -> [[String: Any]]? {
        let r = runRaw(args, sudo: sudo)
        return (try? JSONSerialization.jsonObject(with: r.stdout)) as? [[String: Any]]
    }
}
