import Foundation

/// Append-only diagnostic log for the engine. One file per day:
///   ~/disk-reports/.logs/engine-yyyy-MM-dd.log
/// Owned by the invoking user (handled via Paths.chownToUser). Thread-safe.
enum Logger {
    static var enabled = true

    static func info(_ source: String, _ msg: String) { write("INFO", source, msg) }
    static func warn(_ source: String, _ msg: String) { write("WARN", source, msg) }
    static func error(_ source: String, _ msg: String) { write("ERROR", source, msg) }

    private static let lock = NSLock()

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func logsDir() -> String {
        let dir = (Paths.reportsDir as NSString).appendingPathComponent(".logs")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        Paths.chownToUser(dir)
        return dir
    }

    private static func logPath() -> String {
        let day = dayFmt.string(from: Date())
        let path = (logsDir() as NSString).appendingPathComponent("engine-\(day).log")
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: Data())
            Paths.chownToUser(path)
        }
        return path
    }

    private static func write(_ level: String, _ source: String, _ msg: String) {
        guard enabled else { return }
        let line = "[\(timeFmt.string(from: Date()))] [\(level)] [\(source)] \(msg)\n"
        lock.lock(); defer { lock.unlock() }
        let path = logPath()
        rotateIfNeeded(path)
        guard let data = line.data(using: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            defer { try? fh.close() }
            try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
        }
    }

    /// Maximum size of a single log file before rotation (5 MB).
    /// Keep 3 generations: .log, .log.1, .log.2. Older are deleted.
    private static let maxFileBytes: Int = 5 * 1024 * 1024
    private static let keepGenerations = 3

    private static func rotateIfNeeded(_ path: String) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              size > maxFileBytes else { return }
        let fm = FileManager.default
        // Shift: .2 → delete, .1 → .2, current → .1
        for gen in stride(from: keepGenerations - 1, through: 1, by: -1) {
            let src = "\(path).\(gen)"
            let dst = "\(path).\(gen + 1)"
            if gen + 1 > keepGenerations - 1 {
                try? fm.removeItem(atPath: src)
            } else {
                try? fm.removeItem(atPath: dst)
                try? fm.moveItem(atPath: src, toPath: dst)
            }
        }
        try? fm.moveItem(atPath: path, toPath: "\(path).1")
        Paths.chownToUser("\(path).1")
        // New empty file will be created on first FileHandle write attempt next call.
        fm.createFile(atPath: path, contents: Data())
        Paths.chownToUser(path)
    }
}
