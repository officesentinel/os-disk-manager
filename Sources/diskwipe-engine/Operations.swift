import Foundation

enum OpError: Error, CustomStringConvertible {
    case openFailed(String, Int32)
    case ioFailed(String, Int32)
    case notRoot
    case verifyMismatch(offset: Int64, byte: UInt8)
    var description: String {
        switch self {
        case .openFailed(let n, let e): return "open(\(n)) failed: errno \(e) (\(String(cString: strerror(e))))"
        case .ioFailed(let what, let e): return "\(what) failed: errno \(e) (\(String(cString: strerror(e))))"
        case .notRoot: return "must run as root (euid 0)"
        case .verifyMismatch(let off, let b): return "non-zero byte 0x\(String(b, radix: 16)) at offset \(off)"
        }
    }
}

/// Aggregate speed statistics for a single I/O phase.
struct SpeedSnapshot {
    let minBps: Double
    let avgBps: Double
    let maxBps: Double
    let elapsedSec: Double
    let totalBytes: Int64
    var dictionary: [String: Any] {
        [
            "minBps": minBps.isFinite ? minBps : 0,
            "avgBps": avgBps,
            "maxBps": maxBps,
            "minMBps": (minBps.isFinite ? minBps : 0) / 1_000_000,
            "avgMBps": avgBps / 1_000_000,
            "maxMBps": maxBps / 1_000_000,
            "elapsedSec": elapsedSec,
            "totalBytes": totalBytes
        ]
    }
    var summary: String {
        let minV = minBps.isFinite ? minBps / 1_000_000 : 0
        return String(format: "min %.1f / avg %.1f / max %.1f MB/s",
                      minV, avgBps / 1_000_000, maxBps / 1_000_000)
    }
}

enum Operations {
    static let chunkSize = 8 * 1024 * 1024   // 8 MiB, multiple of 512

    /// Full zero-fill of the raw device with live progress + speed.
    /// Returns aggregate min/avg/max throughput captured across the run.
    @discardableResult
    static func fullErase(_ disk: DiskInfo) throws -> SpeedSnapshot {
        Emit.phase("erase_full", status: "start", detail: "zero-fill \(disk.rawNode)")
        let fd = open(disk.rawNode, O_WRONLY)
        guard fd >= 0 else { throw OpError.openFailed(disk.rawNode, errno) }
        defer { close(fd) }

        let total = disk.sizeBytes
        let buf = [UInt8](repeating: 0, count: chunkSize)
        var written: Int64 = 0
        let meter = SpeedMeter(total: total, phase: "erase_full")
        let started = Date()

        try buf.withUnsafeBytes { rawBuf in
            let base = rawBuf.baseAddress!
            while written < total {
                let remaining = total - written
                let toWrite = Int(min(Int64(chunkSize), remaining))
                var off = 0
                while off < toWrite {
                    let n = write(fd, base + off, toWrite - off)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw OpError.ioFailed("write", errno)
                    }
                    off += n
                    written += Int64(n)
                }
                meter.update(done: written)
            }
        }
        fsync(fd)
        meter.finish(done: written)
        let snap = SpeedSnapshot(minBps: meter.minBps, avgBps: meter.lastAvgBps,
                                 maxBps: meter.maxBps,
                                 elapsedSec: Date().timeIntervalSince(started),
                                 totalBytes: written)
        Emit.phase("erase_full", status: "done",
                   detail: "wrote \(written) bytes in \(meter.elapsedString) — \(snap.summary)")
        return snap
    }

    /// Quick erase: destroy partition tables + GPT primary/backup, then TRIM via diskutil.
    /// Fast (seconds) but does not overwrite every sector. Suitable for SSDs where
    /// TRIM (deterministic-zeroed) makes prior data unrecoverable.
    static func quickErase(_ disk: DiskInfo) throws {
        Emit.phase("erase_quick", status: "start", detail: "zap headers + TRIM")
        let fd = open(disk.rawNode, O_WRONLY)
        guard fd >= 0 else { throw OpError.openFailed(disk.rawNode, errno) }
        let zapSize = Int64(64 * 1024 * 1024)   // 64 MiB head & tail
        let buf = [UInt8](repeating: 0, count: Int(min(zapSize, disk.sizeBytes)))
        buf.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            // Head
            lseek(fd, 0, SEEK_SET)
            _ = write(fd, base, buf.count)
            // Tail (GPT backup lives at the very end)
            let tailStart = max(0, disk.sizeBytes - zapSize)
            // align down to block size
            let aligned = tailStart - (tailStart % disk.blockSize)
            lseek(fd, off_t(aligned), SEEK_SET)
            _ = write(fd, base, Int(disk.sizeBytes - aligned))
        }
        fsync(fd)
        close(fd)
        Emit.phase("erase_quick", status: "progress", detail: "headers zeroed, issuing TRIM")
        // Rebuild empty GPT (also discards/Trims the whole SSD on APFS-aware diskutil).
        _ = Shell.run(Shell.diskutil, ["eraseDisk", "free", "EMPTY", "GPT", disk.id])
        Emit.phase("erase_quick", status: "done", detail: "headers zeroed + empty GPT")
    }

    /// Sector-by-sector read of the whole device verifying every byte is zero.
    /// Returns aggregate min/avg/max read throughput.
    @discardableResult
    static func verifyZero(_ disk: DiskInfo) throws -> SpeedSnapshot {
        Emit.phase("verify", status: "start", detail: "read \(disk.rawNode), expect all-zero")
        let fd = open(disk.rawNode, O_RDONLY)
        guard fd >= 0 else { throw OpError.openFailed(disk.rawNode, errno) }
        defer { close(fd) }

        let total = disk.sizeBytes
        var readBytes: Int64 = 0
        var buf = [UInt8](repeating: 0, count: chunkSize)
        let zero = [UInt8](repeating: 0, count: chunkSize)
        var nonZero: Int64 = 0
        var firstBadOffset: Int64 = -1
        let meter = SpeedMeter(total: total, phase: "verify")

        try buf.withUnsafeMutableBytes { rawBuf in
            let base = rawBuf.baseAddress!
            while readBytes < total {
                let remaining = total - readBytes
                let want = Int(min(Int64(chunkSize), remaining))
                var got = 0
                while got < want {
                    let n = read(fd, base + got, want - got)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw OpError.ioFailed("read", errno)
                    }
                    if n == 0 { break }   // EOF
                    got += n
                }
                // Compare the bytes we got against zero.
                let mismatch = zero.withUnsafeBytes { zp in
                    memcmp(base, zp.baseAddress!, got)
                }
                if mismatch != 0 {
                    // Locate first non-zero within this chunk.
                    let p = base.assumingMemoryBound(to: UInt8.self)
                    for i in 0..<got where p[i] != 0 {
                        if firstBadOffset < 0 { firstBadOffset = readBytes + Int64(i) }
                        nonZero += 1
                    }
                }
                readBytes += Int64(got)
                meter.update(done: readBytes)
                if got < want { break }
            }
        }
        meter.finish(done: readBytes)
        let snap = SpeedSnapshot(minBps: meter.minBps, avgBps: meter.lastAvgBps,
                                 maxBps: meter.maxBps,
                                 elapsedSec: Date().timeIntervalSince(meter.start),
                                 totalBytes: readBytes)
        if nonZero == 0 {
            Emit.phase("verify", status: "done",
                       detail: "read \(readBytes) bytes, 0 non-zero, \(meter.elapsedString) — \(snap.summary)")
            return snap
        } else {
            Emit.phase("verify", status: "failed",
                       detail: "\(nonZero) non-zero bytes, first at offset \(firstBadOffset)")
            throw OpError.verifyMismatch(offset: firstBadOffset, byte: 1)
        }
    }
}

/// Tracks instantaneous (last window) and average (cumulative) throughput,
/// plus min and max observed throughput across all sampling windows.
/// Emits a progress event at a fixed cadence.
final class SpeedMeter {
    private let total: Int64
    private let phase: String
    let start = Date()
    private var windowStart = Date()
    private var windowStartBytes: Int64 = 0
    private var lastEmit = Date(timeIntervalSince1970: 0)
    private let emitInterval = 0.4
    private(set) var lastInstBps: Double = 0
    private(set) var lastAvgBps: Double = 0
    private(set) var minBps: Double = .infinity   // smallest non-zero sample
    private(set) var maxBps: Double = 0

    init(total: Int64, phase: String) { self.total = total; self.phase = phase }

    func update(done: Int64) {
        let now = Date()
        guard now.timeIntervalSince(lastEmit) >= emitInterval else { return }
        let winElapsed = now.timeIntervalSince(windowStart)
        let inst = winElapsed > 0 ? Double(done - windowStartBytes) / winElapsed : 0
        let totalElapsed = now.timeIntervalSince(start)
        let avg = totalElapsed > 0 ? Double(done) / totalElapsed : 0
        let eta = avg > 0 ? Double(total - done) / avg : Double.infinity
        lastInstBps = inst; lastAvgBps = avg
        // Track min/max only on real samples (skip the very first window which has
        // tiny denominators and inflated/zero numbers).
        if inst > 0 {
            if inst > maxBps { maxBps = inst }
            if inst < minBps { minBps = inst }
        }
        Emit.progress(phase: phase, bytesDone: done, bytesTotal: total,
                      instBps: inst, avgBps: avg, etaSec: eta)
        lastEmit = now
        windowStart = now
        windowStartBytes = done
    }

    func finish(done: Int64) {
        let totalElapsed = Date().timeIntervalSince(start)
        lastAvgBps = totalElapsed > 0 ? Double(done) / totalElapsed : 0
        Emit.progress(phase: phase, bytesDone: done, bytesTotal: total,
                      instBps: lastAvgBps, avgBps: lastAvgBps, etaSec: 0)
    }

    var elapsedString: String {
        Emit.formatETA(Date().timeIntervalSince(start))
    }
    var avgMBpsString: String {
        String(format: "%.1f", lastAvgBps / 1_000_000.0)
    }
}
