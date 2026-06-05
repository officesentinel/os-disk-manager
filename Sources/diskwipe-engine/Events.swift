import Foundation

/// Newline-delimited JSON events emitted on stdout for the GUI to consume.
/// Each event is a single line: {"event": "...", ...}. Human-readable mode
/// prints a compact text form instead.
enum Emit {
    static var jsonMode = true
    private static let lock = NSLock()

    static func event(_ type: String, _ fields: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        if jsonMode {
            var obj: [String: Any] = ["event": type, "ts": Date().timeIntervalSince1970]
            for (k, v) in fields { obj[k] = v }
            if let data = try? JSONSerialization.data(withJSONObject: obj),
               let line = String(data: data, encoding: .utf8) {
                print(line)
            }
        } else {
            printText(type, fields)
        }
        fflush(stdout)
    }

    static func phase(_ name: String, status: String, detail: String? = nil) {
        var f: [String: Any] = ["phase": name, "status": status]
        if let d = detail { f["detail"] = d }
        event("phase", f)
    }

    static func progress(phase: String, bytesDone: Int64, bytesTotal: Int64,
                         instBps: Double, avgBps: Double, etaSec: Double) {
        event("progress", [
            "phase": phase,
            "bytesDone": bytesDone,
            "bytesTotal": bytesTotal,
            "percent": bytesTotal > 0 ? Double(bytesDone) / Double(bytesTotal) * 100.0 : 0,
            "instMBps": instBps / 1_000_000.0,
            "avgMBps": avgBps / 1_000_000.0,
            "etaSec": etaSec
        ])
    }

    static func error(_ message: String) {
        event("error", ["message": message])
        Logger.error("emit", message)
    }

    // Fallback human-readable output.
    private static func printText(_ type: String, _ fields: [String: Any]) {
        switch type {
        case "progress":
            let pct = fields["percent"] as? Double ?? 0
            let inst = fields["instMBps"] as? Double ?? 0
            let avg = fields["avgMBps"] as? Double ?? 0
            let eta = fields["etaSec"] as? Double ?? 0
            let phase = fields["phase"] as? String ?? ""
            let bar = progressBar(pct)
            // \r overwrites the line in place.
            print(String(format: "\r[%@] %@ %5.1f%%  inst %6.1f MB/s  avg %6.1f MB/s  ETA %@   ",
                         phase, bar, pct, inst, avg, formatETA(eta)), terminator: "")
        case "phase":
            let phase = fields["phase"] as? String ?? ""
            let status = fields["status"] as? String ?? ""
            let detail = fields["detail"] as? String
            print("\n[\(phase)] \(status)\(detail != nil ? ": \(detail!)" : "")")
        case "error":
            print("\nERROR: \(fields["message"] as? String ?? "")")
        default:
            print("\n[\(type)] \(fields)")
        }
    }

    private static func progressBar(_ pct: Double, width: Int = 24) -> String {
        let filled = Int((pct / 100.0) * Double(width))
        return "[" + String(repeating: "#", count: max(0, min(width, filled)))
             + String(repeating: "-", count: max(0, width - filled)) + "]"
    }

    static func formatETA(_ sec: Double) -> String {
        guard sec.isFinite, sec >= 0 else { return "--:--" }
        let s = Int(sec)
        let h = s / 3600, m = (s % 3600) / 60, sx = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sx)
                     : String(format: "%02d:%02d", m, sx)
    }
}
