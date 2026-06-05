import Foundation

/// Heuristically classify a disk as enterprise/datacenter, consumer, or unknown
/// based on model-name patterns, interface protocol, form factor and capacity numerology.
///
/// There is no single SMART bit that says "this is a server drive" — vendors use
/// distinct product lines (Samsung PM883 vs 870 EVO, Micron 7450 vs Crucial MX,
/// Intel D3 vs 660p, etc.). This is a best-effort classifier; it returns "unknown"
/// when no strong signal is present rather than guessing.
enum DiskTier: String {
    case enterprise   // datacenter / server / professional NAS
    case consumer     // retail or OEM-client (incl. budget)
    case unknown
}

enum TierClassifier {
    /// Classification priority:
    ///   1. OurDB.tier — explicit and most reliable
    ///   2. SAS interface → enterprise (almost universal sign)
    ///   3. Model substring heuristics (legacy hardcoded lists, kept as safety net)
    ///   4. Capacity numerology (480/960/1920/3840/7680/15360 GB = enterprise sizing)
    ///   5. Form factor (U.2 / U.3 / M.2 22110 = enterprise)
    ///   6. .unknown — UI shows "не определено" rather than guessing
    static func classify(model: String?, proto: String?, formFactor: String?, sizeBytes: Int64?) -> (tier: DiskTier, reason: String) {
        // 1. Database lookup — wins when present.
        if let spec = DiskDatabase.match(model), let tierStr = spec.tier {
            let tier: DiskTier = {
                switch tierStr {
                case "enterprise": return .enterprise
                case "consumer": return .consumer
                case "prosumer": return .consumer   // collapse to two states for now
                default: return .unknown
                }
            }()
            return (tier, "OurDB: \(spec.brand) \(spec.family)")
        }
        let m = (model ?? "").lowercased()
        let p = (proto ?? "").uppercased()

        // SAS → almost always enterprise.
        if p == "SCSI" || p == "SAS" {
            return (.enterprise, "SAS/SCSI interface")
        }

        // High-confidence enterprise model patterns.
        let entKeys: [String] = [
            "ultrastar", "exos", "ironwolf pro", "nytro",                  // HDD / SSD enterprise
            "wd gold", "wd red pro", "hgst", "solidigm",
            // Samsung datacenter SSDs (PM883/PM893 mainstream DC; PM9A3+/PM17xx newer NVMe DC; SM86x SAS DC)
            "pm883", "pm893", "pm897", "pm9a3", "pm9a4", "pm1733", "pm1735", "pm1743",
            "sm863", "sm883", "sm953",
            // Micron datacenter
            "m500dc", "m510dc", "5100", "5200", "5210", "5300", "5400 pro",
            "7300", "7400", "7450", "7500",
            // Intel / Solidigm DC
            "dc p3", "dc p4", "dc p5", "ssdsc2b", "ssdpe", "ssdpf",
            "d3-s4", "d3-s5", "d5-p", "d7-p",
            // Kioxia / Toshiba enterprise
            "kxg6", "kxg7", "ck5", "cm5", "cm6", "cm7", "cd5", "cd6", "cd7", "cd8",
            // WDC / SanDisk enterprise
            "ss530", "ss540", "sn650", "skhynix pe",
            // Generic enterprise tells
            "enterprise", "datacenter"
        ]
        for key in entKeys where m.contains(key) {
            return (.enterprise, "model matches \"\(key)\"")
        }

        // High-confidence consumer patterns.
        let conKeys: [String] = [
            "evo", "mx500", "mx100", "mx200", "mx300", "mx400", "bx500", "bx200",
            "p2", "p3 plus", "p5", "p5 plus", "t700",
            "wd blue", "wd black", "wd green", "wd elements", "wd my passport",
            "barracuda", "firecuda", "ironwolf ",   // note: trailing space distinguishes from "ironwolf pro"
            "samsung ssd 8", "samsung ssd 9", "samsung ssd 7", "samsung ssd 6",
            "samsung t7", "samsung t9", "samsung x5",
            "kingston a4", "kingston a2000", "kingston nv", "kc3000", "kc600",
            "adata", "team", "patriot", "transcend", "silicon power", "spcc",
            "kingdian", "neo forza", "hikvision", "vaseky"
        ]
        for key in conKeys where m.contains(key) {
            return (.consumer, "model matches \"\(key)\"")
        }

        // Capacity numerology — soft signal only (overridden by model match above).
        if let bytes = sizeBytes {
            let gb = Int((Double(bytes) / 1_000_000_000.0).rounded())
            // 480 / 960 / 1920 / 3840 / 7680 / 15360 = ent
            let entSizes: Set<Int> = [480, 960, 1920, 3840, 7680, 15360, 30720]
            if entSizes.contains(gb) {
                return (.enterprise, "capacity \(gb) GB matches enterprise sizing")
            }
        }

        // Form factor — U.2 or 15mm 2.5" suggests enterprise; M.2 22110 is enterprise/server.
        let ff = (formFactor ?? "").lowercased()
        if ff.contains("u.2") || ff.contains("u.3") || ff.contains("22110") {
            return (.enterprise, "form factor \(ff)")
        }

        return (.unknown, "no strong signal")
    }
}
