import Foundation

/// Fetches the model database from a remote URL and caches it under
/// ~/disk-reports/.config/.cache/models.json. The engine then loads it
/// automatically via its standard search path (user-override directory).
///
/// Update strategy:
///   • On app launch, if cached file is older than 7 days → refresh in background.
///   • Manual "Refresh DB" button triggers immediate fetch.
///   • Failure (offline, 404) is silent — bundled DB stays in effect.
final class DatabaseUpdater: @unchecked Sendable {
    static let shared = DatabaseUpdater()

    /// Default URL for community-curated database. User can override via
    /// `~/disk-reports/.config/db_source.txt` containing a single URL.
    private let defaultURL = "https://raw.githubusercontent.com/officesentinel/os-disk-manager-models/main/models.json"
    private let refreshIntervalSec: TimeInterval = 7 * 24 * 60 * 60

    var cacheDir: String {
        let dir = (NSHomeDirectory() as NSString)
            .appendingPathComponent("disk-reports/.config")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Cache file lives at .config/models.json so the engine picks it up via its
        // standard user-override lookup. We don't shadow user-edited files: if a
        // sibling `db_user_override.json` exists, we leave it alone.
        return dir
    }
    private var cachedDbPath: String { (cacheDir as NSString).appendingPathComponent("models.json") }
    private var sourceURLPath: String { (cacheDir as NSString).appendingPathComponent("db_source.txt") }
    private var lastFetchPath: String { (cacheDir as NSString).appendingPathComponent("db_last_fetch.txt") }

    /// Resolves the URL to fetch from: file override or default.
    private var sourceURL: URL? {
        if let s = try? String(contentsOfFile: sourceURLPath, encoding: .utf8) {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let u = URL(string: trimmed) { return u }
        }
        return URL(string: defaultURL)
    }

    enum Result { case updated, upToDate, failed(String) }

    /// Decide whether to auto-refresh. Returns true if cache is missing or stale.
    func needsRefresh() -> Bool {
        guard FileManager.default.fileExists(atPath: cachedDbPath) else { return true }
        guard let stamp = try? String(contentsOfFile: lastFetchPath, encoding: .utf8),
              let last = TimeInterval(stamp.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return true
        }
        return Date().timeIntervalSince1970 - last > refreshIntervalSec
    }

    /// Trigger fetch in the background; calls `completion` on the main queue.
    func fetch(force: Bool = false, completion: ((Result) -> Void)? = nil) {
        if !force && !needsRefresh() {
            DispatchQueue.main.async { completion?(.upToDate) }
            return
        }
        guard let url = sourceURL else {
            DispatchQueue.main.async { completion?(.failed("no source URL")) }
            return
        }
        AppLog.shared.info("db.update", "fetching \(url.absoluteString)")
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self else { return }
            if let error = error {
                AppLog.shared.error("db.update", "\(error)")
                DispatchQueue.main.async { completion?(.failed(error.localizedDescription)) }
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data = data else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                AppLog.shared.error("db.update", "HTTP \(code)")
                DispatchQueue.main.async { completion?(.failed("HTTP \(code)")) }
                return
            }
            // Sanity check — should be valid JSON with "models" array.
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["models"] is [[String: Any]] else {
                AppLog.shared.error("db.update", "downloaded payload is not a valid model DB")
                DispatchQueue.main.async { completion?(.failed("invalid payload")) }
                return
            }
            try? data.write(to: URL(fileURLWithPath: self.cachedDbPath), options: .atomic)
            try? "\(Date().timeIntervalSince1970)".write(toFile: self.lastFetchPath,
                                                         atomically: true, encoding: .utf8)
            AppLog.shared.info("db.update", "saved \(data.count) bytes to \(self.cachedDbPath)")
            DispatchQueue.main.async { completion?(.updated) }
        }
        task.resume()
    }
}
