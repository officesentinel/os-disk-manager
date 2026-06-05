import Foundation
import Combine

private final class LineBuf2 { var data = Data() }

@MainActor
final class ScanRunner: ObservableObject {
    @Published var disks: [DiskItem] = []
    @Published var selected: DiskItem? { didSet { if oldValue?.id != selected?.id { resetScanState() } } }
    private var pollTimer: Timer?
    @Published var mode = "read"            // read / verify
    @Published var thresholdMs = 200
    @Published var running = false
    @Published var percent = 0.0
    @Published var instMBps = 0.0
    @Published var avgMBps = 0.0
    @Published var maxMs = 0
    @Published var bands = [Int](repeating: 0, count: 7)
    @Published var buckets: [Int] = []      // -1 untested, 0..6 band
    @Published var summary = ""
    @Published var finished = false

    // Band display strings come from `Loc` via `loc.t("band.0")...`. This array
    // is no longer used at runtime — kept blank to avoid stray hard-coded language.
    static let bandNames: [String] = []

    private let enginePath: String = {
        let c = ["/usr/local/bin/diskwipe-engine",
                 (NSHomeDirectory() as NSString).appendingPathComponent("src/diskwipe/.build/debug/diskwipe-engine")]
        return c.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/local/bin/diskwipe-engine"
    }()
    private var process: Process?

    func refreshDisks() {
        let p = Process(); p.executableURL = URL(fileURLWithPath: enginePath); p.arguments = ["list"]
        let pipe = Pipe(); p.standardOutput = pipe
        do { try p.run() } catch { return }
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return }
        let new = arr.map { DiskItem(id: $0["id"] as? String ?? "?", model: $0["model"] as? String ?? "?",
                                     serial: $0["serial"] as? String ?? "", sizeGB: $0["sizeGB"] as? Double ?? 0,
                                     busProtocol: $0["busProtocol"] as? String ?? "?", isSSD: $0["isSSD"] as? Bool ?? false) }
        if new != disks { disks = new }
        // Auto-switch selection if the current disk was removed/swapped.
        if selected == nil || !disks.contains(where: { $0.id == selected?.id }) {
            selected = disks.first
        }
    }

    /// Start polling so insertion/removal updates the UI live.
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

    /// Wipe scan results so the previous disk's map/bands don't bleed onto the new one.
    private func resetScanState() {
        percent = 0
        bands = [Int](repeating: 0, count: 7)
        buckets = []
        summary = ""
        maxMs = 0
        instMBps = 0
        avgMBps = 0
        finished = false
    }

    func start() {
        guard let disk = selected, !running else { return }
        running = true; finished = false; percent = 0; bands = [Int](repeating: 0, count: 7)
        // Pre-fill the surface map with "untested" cells so the grid is visible
        // from t=0 and lights up colour-by-colour as the engine streams updates.
        buckets = [Int](repeating: -1, count: 240); summary = ""; maxMs = 0

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", enginePath, "scan", "--disk", disk.id, "--mode", mode, "--threshold", "\(thresholdMs)"]
        let out = Pipe(); let err = Pipe()
        p.standardOutput = out; p.standardError = err
        process = p
        let lb = LineBuf2()
        out.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let chunk = fh.availableData; guard !chunk.isEmpty else { return }
            lb.data.append(chunk)
            while let nl = lb.data.firstIndex(of: 0x0A) {
                let line = lb.data.subdata(in: lb.data.startIndex..<nl)
                lb.data.removeSubrange(lb.data.startIndex...nl)
                if let s = String(data: line, encoding: .utf8), !s.isEmpty {
                    Task { @MainActor in self?.handle(s) }
                }
            }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                out.fileHandleForReading.readabilityHandler = nil
                self?.running = false; self?.finished = true
            }
        }
        do { try p.run() } catch { running = false }
    }

    func cancel() { process?.terminate() }

    private func handle(_ line: String) {
        guard let d = line.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let ev = o["event"] as? String else { return }
        switch ev {
        case "scanprogress":
            percent = o["percent"] as? Double ?? percent
            instMBps = o["instMBps"] as? Double ?? 0
            avgMBps = o["avgMBps"] as? Double ?? 0
            maxMs = o["maxMs"] as? Int ?? maxMs
            if let b = o["bands"] as? [Int] { bands = b }
            // Live block-map: engine sends the current bucketWorst array every ~0.4s.
            if let bk = o["buckets"] as? [Int] { buckets = bk }
        case "scanresult":
            if let b = o["buckets"] as? [Int] { buckets = b }
            if let b = o["bands"] as? [Int] { bands = b }
            let avg = o["avgMs"] as? Double ?? 0
            let mx = o["maxMs"] as? Int ?? 0
            let slow = (o["slow"] as? [[String: Any]])?.count ?? 0
            let ok = o["ok"] as? Bool ?? true
            let detail = String(format: Loc.shared.t("scan.summary"), "\(avg)", mx, slow, o["elapsed"] as? String ?? "")
            summary = "\(ok ? "✓" : "⚠️") " + detail
            percent = 100
        default: break
        }
    }
}
