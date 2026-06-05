import Foundation

/// Non-destructive surface scan: reads the device block-by-block, times each
/// access, classifies into latency bands (Victoria/HDDScan-style), and emits
/// a coarse block-map for visualization.
enum Scan {
    // Latency band thresholds in ms. Index 0..<5 use these; >= threshold -> band 5; error -> 6.
    // bands: 0 <5ms, 1 <20ms, 2 <50ms, 3 <150ms, 4 <threshold, 5 >=threshold, 6 error
    static func classify(ms: Double, thresholdMs: Double, error: Bool) -> Int {
        if error { return 6 }
        if ms < 5 { return 0 }
        if ms < 20 { return 1 }
        if ms < 50 { return 2 }
        if ms < 150 { return 3 }
        if ms < thresholdMs { return 4 }
        return 5
    }

    /// Returns the same payload that is emitted as `scanresult` so the caller can persist it.
    @discardableResult
    static func surface(_ disk: DiskInfo, mode: String, thresholdMs: Double,
                        blockMiB: Int = 4, buckets: Int = 240) throws -> [String: Any] {
        Emit.phase("scan", status: "start",
                   detail: "\(mode), порог \(Int(thresholdMs)) мс, блок \(blockMiB) MiB")
        let fd = open(disk.rawNode, O_RDONLY)
        guard fd >= 0 else { throw OpError.openFailed(disk.rawNode, errno) }
        fcntl(fd, F_NOCACHE, 1)
        defer { close(fd) }

        let block = blockMiB * 1024 * 1024
        let total = disk.sizeBytes
        let totalBlocks = Int((total + Int64(block) - 1) / Int64(block))
        var buf = [UInt8](repeating: 0, count: block)
        var bucketWorst = [Int](repeating: -1, count: buckets)
        var counts = [Int](repeating: 0, count: 7)
        var slow: [[String: Any]] = []
        var maxMs = 0.0
        var sumMs = 0.0
        var timed = 0

        var readBytes: Int64 = 0
        var blockIndex = 0
        let meter = SpeedMeter(total: total, phase: "scan")
        var lastEmit = Date(timeIntervalSince1970: 0)

        try buf.withUnsafeMutableBytes { rawBuf in
            let base = rawBuf.baseAddress!
            while readBytes < total {
                let want = Int(min(Int64(block), total - readBytes))
                let t0 = Date()
                var got = 0
                var hadError = false
                while got < want {
                    let n = read(fd, base + got, want - got)
                    if n < 0 {
                        if errno == EINTR { continue }
                        hadError = true
                        break
                    }
                    if n == 0 { break }
                    got += n
                }
                let dtMs = Date().timeIntervalSince(t0) * 1000.0
                let band = classify(ms: dtMs, thresholdMs: thresholdMs, error: hadError)
                counts[band] += 1
                if !hadError { sumMs += dtMs; timed += 1; if dtMs > maxMs { maxMs = dtMs } }

                let bIdx = totalBlocks > 0 ? min(buckets - 1, blockIndex * buckets / totalBlocks) : 0
                if band > bucketWorst[bIdx] { bucketWorst[bIdx] = band }

                if band >= 4 && slow.count < 1000 {
                    slow.append(["offsetBytes": readBytes, "ms": Int(dtMs), "band": band])
                }

                if hadError {
                    // Skip this block and continue scanning the rest.
                    readBytes += Int64(want)
                    lseek(fd, off_t(readBytes), SEEK_SET)
                } else {
                    readBytes += Int64(got)
                    if got < want { break }
                }
                blockIndex += 1
                meter.update(done: readBytes)

                let now = Date()
                if now.timeIntervalSince(lastEmit) >= 0.4 {
                    Emit.event("scanprogress", [
                        "percent": Double(readBytes) / Double(total) * 100.0,
                        "instMBps": meter.lastInstBps / 1_000_000.0,
                        "avgMBps": meter.lastAvgBps / 1_000_000.0,
                        "bands": counts,
                        "maxMs": Int(maxMs),
                        "blockIndex": blockIndex,
                        "totalBlocks": totalBlocks,
                        // Live block-map: GUI re-renders the surface map on each update.
                        "buckets": bucketWorst
                    ])
                    lastEmit = now
                }
            }
        }

        let avgMs = timed > 0 ? sumMs / Double(timed) : 0
        let payload: [String: Any] = [
            "mode": mode,
            "thresholdMs": Int(thresholdMs),
            "blockMiB": blockMiB,
            "buckets": bucketWorst,
            "bands": counts,
            "slow": slow,
            "maxMs": Int(maxMs),
            "avgMs": Double(Int(avgMs * 100)) / 100.0,
            "blocksScanned": blockIndex,
            "elapsed": meter.elapsedString,
            "ok": counts[5] == 0 && counts[6] == 0
        ]
        Emit.event("scanresult", payload)
        Emit.phase("scan", status: "done",
                   detail: "blocks \(blockIndex), >threshold \(counts[5]), errors \(counts[6]), max \(Int(maxMs)) ms")
        return payload
    }
}
