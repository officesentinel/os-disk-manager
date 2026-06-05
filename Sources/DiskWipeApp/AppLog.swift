import Foundation

/// Thread-safe append-only log for the GUI process.
/// One file per day at ~/disk-reports/.logs/gui-yyyy-MM-dd.log.
/// Mirrors the engine's logger layout so they can be read together.
final class AppLog: @unchecked Sendable {
    static let shared = AppLog()

    private let lock = NSLock()
    private let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    private let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func info(_ source: String, _ msg: String) { write("INFO", source, msg) }
    func warn(_ source: String, _ msg: String) { write("WARN", source, msg) }
    func error(_ source: String, _ msg: String) { write("ERROR", source, msg) }

    var logsDir: String {
        let dir = (NSHomeDirectory() as NSString)
            .appendingPathComponent("disk-reports/.logs")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
    private var path: String {
        let day = dayFmt.string(from: Date())
        let p = (logsDir as NSString).appendingPathComponent("gui-\(day).log")
        if !FileManager.default.fileExists(atPath: p) {
            FileManager.default.createFile(atPath: p, contents: Data())
        }
        return p
    }

    private func write(_ level: String, _ source: String, _ msg: String) {
        let line = "[\(timeFmt.string(from: Date()))] [\(level)] [\(source)] \(msg)\n"
        lock.lock(); defer { lock.unlock() }
        guard let data = line.data(using: .utf8) else { return }
        let p = path
        if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: p)) {
            defer { try? fh.close() }
            try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
        }
    }

    /// Read recent lines from today's GUI log + engine log, sorted by timestamp.
    /// Lightweight: tails up to `maxBytes` per file.
    func recentLines(maxBytes: Int = 64 * 1024) -> [String] {
        let day = dayFmt.string(from: Date())
        let gui = (logsDir as NSString).appendingPathComponent("gui-\(day).log")
        let eng = (logsDir as NSString).appendingPathComponent("engine-\(day).log")
        var lines: [String] = []
        for p in [gui, eng] {
            guard let url = URL(string: "file://\(p)") ?? Optional.some(URL(fileURLWithPath: p)),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: p),
                  let size = (attrs[.size] as? NSNumber)?.intValue,
                  let fh = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? fh.close() }
            let offset = max(0, size - maxBytes)
            try? fh.seek(toOffset: UInt64(offset))
            if let data = try? fh.readToEnd(),
               let text = String(data: data, encoding: .utf8) {
                lines.append(contentsOf: text.split(separator: "\n").map(String.init))
            }
        }
        return lines.sorted()  // ISO-style timestamps sort chronologically as strings
    }
}
