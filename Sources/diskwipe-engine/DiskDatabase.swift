import Foundation

/// Resolved disk-spec entry (one model family).
struct DiskSpec {
    let brand: String
    let family: String
    let dram: Bool?
    let nand: String?
    let controller: String?
    let tier: String?     // "consumer" | "enterprise" | "prosumer" | "unknown"
    let tbwPerTb: Int?
    let plp: Bool?
    let note: String?
}

/// Loads model database from:
///   1. Bundled `models.json` (Bundle.module / Resources)
///   2. User override at ~/disk-reports/.config/models.json (entries here win)
///   3. Optional remote-cached file (future)
/// Entries are matched by case-insensitive substring (`patterns` array per entry).
enum DiskDatabase {
    private static var entries: [(patterns: [String], spec: DiskSpec)] = {
        loadAll()
    }()
    private static var loadedFiles: [String] = []

    /// Look up a disk by smartctl model_name string.
    static func match(_ model: String?) -> DiskSpec? {
        guard let m = model?.lowercased(), !m.isEmpty else { return nil }
        for e in entries {
            for p in e.patterns where m.contains(p) { return e.spec }
        }
        return nil
    }

    /// Force-reload (useful after the GUI writes a custom override).
    static func reload() { entries = loadAll(); }

    /// Diagnostics: list which DB files were loaded and how many entries each contributed.
    static func loadSources() -> [String] { loadedFiles }

    // MARK: Loaders

    private static func loadAll() -> [(patterns: [String], spec: DiskSpec)] {
        var combined: [(patterns: [String], spec: DiskSpec)] = []
        loadedFiles.removeAll()

        // 1. User override — first so its entries win on substring match.
        let userPath = (Paths.userHome as NSString)
            .appendingPathComponent("disk-reports/.config/models.json")
        if FileManager.default.fileExists(atPath: userPath),
           let entries = parseFile(path: userPath) {
            combined.append(contentsOf: entries)
            loadedFiles.append("\(userPath) (\(entries.count) entries)")
        }

        // 2. Bundled — shipped with the app.
        if let url = Bundle.module.url(forResource: "models", withExtension: "json"),
           let entries = parseFile(path: url.path) {
            combined.append(contentsOf: entries)
            loadedFiles.append("bundled (\(entries.count) entries)")
        }
        return combined
    }

    private static func parseFile(path: String) -> [(patterns: [String], spec: DiskSpec)]? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        // Strip line comments (`// ...`) so the file stays readable but parses as JSON.
        let lines = raw.components(separatedBy: "\n").map { (line: String) -> String in
            if let r = line.range(of: "//") {
                return String(line[..<r.lowerBound])
            }
            return line
        }
        let stripped = lines.joined(separator: "\n")
        guard let data = stripped.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else {
            Logger.warn("diskdb", "failed to parse \(path)")
            return nil
        }
        return models.compactMap { entry in
            guard let patterns = entry["patterns"] as? [String] else { return nil }
            let spec = DiskSpec(
                brand: (entry["brand"] as? String) ?? "",
                family: (entry["family"] as? String) ?? "",
                dram: entry["dram"] as? Bool,
                nand: entry["nand"] as? String,
                controller: entry["controller"] as? String,
                tier: entry["tier"] as? String,
                tbwPerTb: entry["tbwPerTb"] as? Int,
                plp: entry["plp"] as? Bool,
                note: entry["_note"] as? String
            )
            return (patterns.map { $0.lowercased() }, spec)
        }
    }
}
