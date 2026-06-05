import Foundation

/// Thin wrapper around DiskDatabase for DRAM-cache detection.
/// Kept as a separate file so the lookup site stays self-documenting.
enum CacheInfo {
    /// Returns (hasDram, reason). Both are nil when no DB entry matches.
    static func detect(model: String?) -> (dram: Bool?, reason: String?) {
        guard let spec = DiskDatabase.match(model) else { return (nil, nil) }
        let reason = "\(spec.brand) \(spec.family)".trimmingCharacters(in: .whitespaces)
        return (spec.dram, reason.isEmpty ? nil : reason)
    }
}
