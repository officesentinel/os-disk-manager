import Foundation

/// Generates the per-disk analytics report (Markdown + HTML + JSON) from live SMART + partition data.
/// Mirrors what the dashboard shows: identity + static specs (DRAM/NAND/PLP/TBW/discard/sanitize/tier)
/// + dynamic state (POH/cycles/temp/wear/health) + SMART attributes + partition map.
enum ReportExport {
    static var dir: String { Paths.reportsDir }

    /// Format = "md" | "html" | "json" | "both" (md+html) | "all" (md+html+json).
    /// Returns paths of written files keyed by format.
    static func export(diskID: String, format: String) -> [String: Any] {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        Paths.chownToUser(dir)
        let node = DiskInfo.load(diskID)?.node ?? "/dev/\(diskID)"
        let smart = Smart.fullReport(node)
        let layout = Partitions.layout(diskID)

        let serial = (smart["serial"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? diskID
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
        let stamp = df.string(from: Date())

        let wantMd = format == "md" || format == "both" || format == "all"
        let wantHtml = format == "html" || format == "both" || format == "all"
        let wantJson = format == "json" || format == "all"

        var written: [String: Any] = [:]
        if wantMd {
            let path = (dir as NSString).appendingPathComponent("\(serial).md")
            try? markdown(smart: smart, layout: layout, when: stamp)
                .write(toFile: path, atomically: true, encoding: .utf8)
            Paths.chownToUser(path); written["md"] = path
        }
        if wantHtml {
            let path = (dir as NSString).appendingPathComponent("\(serial).html")
            try? htmlReport(smart: smart, layout: layout, when: stamp)
                .write(toFile: path, atomically: true, encoding: .utf8)
            Paths.chownToUser(path); written["html"] = path
        }
        if wantJson {
            let path = (dir as NSString).appendingPathComponent("\(serial).json")
            let bundle: [String: Any] = [
                "generatedAt": stamp,
                "schema": "report.v2",
                "smart": smart,
                "partitions": layout
            ]
            if let data = try? JSONSerialization.data(withJSONObject: bundle,
                                                     options: [.prettyPrinted, .sortedKeys]),
               let s = String(data: data, encoding: .utf8) {
                try? s.write(toFile: path, atomically: true, encoding: .utf8)
                Paths.chownToUser(path); written["json"] = path
            }
        }
        return written
    }

    // MARK: - Markdown

    private static func markdown(smart: [String: Any], layout: [String: Any], when: String) -> String {
        let gb = Double(smart["sizeBytes"] as? Int64 ?? 0) / 1e9
        let health = (smart["healthPassed"] as? Bool).map { $0 ? "PASSED" : "FAILED" } ?? "—"
        let tier = (smart["tier"] as? String) ?? "—"
        let dram = (smart["dramCache"] as? Bool).map { $0 ? "yes" : "no" } ?? "no data"
        let nand = (smart["nandType"] as? String) ?? "—"
        let plp = (smart["plp"] as? Bool).map { $0 ? "yes" : "no" } ?? "no data"
        let discardMech = (smart["discardMechanism"] as? String) ?? "TRIM"
        let trimSupp = (smart["trimSupported"] as? Bool).map { $0 ? "yes" : "no" } ?? "no data"
        let trimLevel = (smart["trimLevel"] as? String) ?? ""
        let sanitize = (smart["sanitizeMethods"] as? [String])?.joined(separator: ", ") ?? "no data"
        let dataSource = (smart["dataSource"] as? String) ?? "—"
        let family = (smart["family"] as? String) ?? ""
        let tbwPerTb = smart["tbwPerTb"] as? Int
        let lifePct = smart["lifeLeftPercent"] as? Int
        let wearPct = smart["wearPercentUsed"] as? Int

        var s = """
        # Disk Analytics — \(smart["model"] as? String ?? "—")

        **Family:** \(family.isEmpty ? "—" : family)  ·  **Source:** \(dataSource)
        **Serial:** \(smart["serial"] as? String ?? "")
        **Firmware:** \(smart["firmware"] as? String ?? "")
        **Generated:** \(when)

        ## Identity

        | Field | Value |
        |-------|-------|
        | Capacity | \(String(format: "%.1f GB", gb)) |
        | Type | \((smart["isSSD"] as? Bool ?? true) ? "SSD" : "HDD") |
        | Interface | \(smart["protocol"] as? String ?? "—") |
        | Form factor | \(smart["formFactor"] as? String ?? "—") |
        | Class | \(tier) |

        ## Static specs

        | Field | Value |
        |-------|-------|
        | DRAM cache | \(dram) |
        | NAND | \(nand) |
        | Power-Loss Protection | \(plp) |
        | Discard (\(discardMech)) | \(trimSupp)\(trimLevel.isEmpty ? "" : " (\(trimLevel))") |
        | Sanitize methods | \(sanitize) |
        | TBW per TB (rated) | \(tbwPerTb.map(String.init) ?? "—") |

        ## Dynamic state

        | Field | Value |
        |-------|-------|
        | SMART health | \(health) |
        | Life left | \(lifePct.map { "\($0)%" } ?? "—") |
        | Wear used | \(wearPct.map { "\($0)%" } ?? "—") |
        | Temperature | \(smart["temperatureC"] as? Int ?? 0)°C\((smart["temperatureMaxC"] as? Int).map { " (max \($0)°C)" } ?? "") |
        | Power-On Hours | \(smart["powerOnHours"] as? Int ?? 0) |
        | Power Cycles | \(smart["powerCycles"] as? Int ?? 0) |

        """
        // Endurance summary, if known.
        if let tbw = tbwPerTb, let wear = wearPct {
            let totalTbw = Double(tbw) * gb / 1000.0
            let usedTb = totalTbw * Double(wear) / 100.0
            s += "\n**Endurance:** \(String(format: "%.1f TB used of %.0f TBW rated (%d%%)", usedTb, totalTbw, wear))\n"
        }

        s += """

        ## SMART attributes

        | Status | ID | Attribute | Value | Worst | Threshold | Raw |
        |--------|----|-----------|-------|-------|-----------|-----|

        """
        for a in (smart["attributes"] as? [[String: Any]] ?? []) {
            let st = a["status"] as? String ?? "ok"
            let mark = st == "ok" ? "🟢" : (st == "warn" ? "🟠" : "🔴")
            s += "| \(mark) | \(a["id"] as? Int ?? 0) | \(a["name"] as? String ?? "") | "
                + "\(a["value"] as? Int ?? 0) | \(a["worst"] as? Int ?? 0) | \(a["thresh"] as? Int ?? 0) | "
                + "\(a["rawString"] as? String ?? "") |\n"
        }
        s += "\n## Partitions — \(layout["scheme"] as? String ?? "—")\n\n"
        s += "| Volume | Name | FS | Size | Mount |\n|--------|------|----|----|------|\n"
        for p in (layout["partitions"] as? [[String: Any]] ?? []) {
            let sz = Double(p["sizeBytes"] as? Int64 ?? 0) / 1e9
            s += "| \(p["id"] as? String ?? "") | \(p["name"] as? String ?? "") | "
                + "\(p["fs"] as? String ?? "") | \(String(format: "%.1f GB", sz)) | \(p["mount"] as? String ?? "") |\n"
        }
        s += "\n_Generated by OS Disk Manager._\n"
        return s
    }

    // MARK: - HTML

    private static func htmlReport(smart: [String: Any], layout: [String: Any], when: String) -> String {
        let gb = Double(smart["sizeBytes"] as? Int64 ?? 0) / 1e9
        let passed = smart["healthPassed"] as? Bool
        let health = passed.map { $0 ? "PASSED" : "FAILED" } ?? "—"
        let healthColor = passed == true ? "#16a34a" : (passed == nil ? "#888" : "#dc2626")
        let life = smart["lifeLeftPercent"] as? Int ?? 100
        let temp = smart["temperatureC"] as? Int ?? 0
        let model = smart["model"] as? String ?? "—"
        let family = smart["family"] as? String ?? ""
        let dataSource = smart["dataSource"] as? String ?? "—"
        let tier = smart["tier"] as? String ?? "—"
        let dramVal = smart["dramCache"] as? Bool
        let nand = smart["nandType"] as? String ?? "—"
        let plpVal = smart["plp"] as? Bool
        let discardMech = smart["discardMechanism"] as? String ?? "TRIM"
        let trimSupp = smart["trimSupported"] as? Bool
        let trimLevel = smart["trimLevel"] as? String ?? ""
        let sanitize = (smart["sanitizeMethods"] as? [String]) ?? []
        let tbwPerTb = smart["tbwPerTb"] as? Int
        let wearPct = smart["wearPercentUsed"] as? Int

        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        }
        // Spec-chip helper: 3-state (true/false/nil) with colour and label.
        func chip(_ label: String, _ state: Bool?, yes: String = "yes", no: String = "no", help: String = "") -> String {
            let (color, value): (String, String) = {
                switch state {
                case .some(true):  return ("#16a34a", yes)
                case .some(false): return ("#dc2626", no)
                case .none:        return ("#94a3b8", "no data")
                }
            }()
            return "<span class=\"chip\" style=\"background:\(color)1a;color:\(color)\" title=\"\(esc(help))\">\(esc(label)): <b>\(esc(value))</b></span>"
        }
        func chipText(_ label: String, _ value: String, color: String = "#3b82f6") -> String {
            return "<span class=\"chip\" style=\"background:\(color)1a;color:\(color)\">\(esc(label)): <b>\(esc(value))</b></span>"
        }

        var attrRows = ""
        for a in (smart["attributes"] as? [[String: Any]] ?? []) {
            let st = a["status"] as? String ?? "ok"
            let c = st == "ok" ? "#16a34a" : (st == "warn" ? "#f59e0b" : "#dc2626")
            attrRows += """
            <tr><td><span class="dot" style="background:\(c)"></span></td>
            <td>\(a["id"] as? Int ?? 0)</td><td>\(esc(a["name"] as? String ?? ""))</td>
            <td class="n">\(a["value"] as? Int ?? 0)</td><td class="n">\(a["worst"] as? Int ?? 0)</td>
            <td class="n">\(a["thresh"] as? Int ?? 0)</td><td class="n">\(esc(a["rawString"] as? String ?? ""))</td></tr>
            """
        }
        var partRows = "", bar = ""
        let palette = ["#3b82f6","#22c55e","#f59e0b","#a855f7","#ec4899","#14b8a6","#6366f1"]
        for (i, p) in (layout["partitions"] as? [[String: Any]] ?? []).enumerated() {
            let sz = Double(p["sizeBytes"] as? Int64 ?? 0)
            let col = palette[i % palette.count]
            partRows += """
            <tr><td><span class="dot" style="background:\(col)"></span>\(esc(p["id"] as? String ?? ""))</td>
            <td>\(esc(p["name"] as? String ?? ""))</td><td>\(esc(p["fs"] as? String ?? ""))</td>
            <td class="n">\(String(format: "%.1f GB", sz/1e9))</td><td>\(esc(p["mount"] as? String ?? ""))</td></tr>
            """
            bar += "<div style=\"flex:\(sz);background:\(col)\"></div>"
        }

        // Endurance bar HTML if data available.
        var enduranceBlock = ""
        if let tbw = tbwPerTb {
            let total = Double(tbw) * gb / 1000.0
            let pct = wearPct ?? 0
            let used = total * Double(pct) / 100.0
            let bcol = pct > 80 ? "#dc2626" : (pct > 50 ? "#f59e0b" : "#16a34a")
            enduranceBlock = """
            <div class="card" style="flex:1;min-width:300px">
              <div style="display:flex;justify-content:space-between;align-items:baseline">
                <div><span class="big" style="color:\(bcol)">\(String(format: "%.1f", used)) TB</span> <span style="color:#94a3b8">used of \(String(format: "%.0f", total)) TBW</span></div>
                <div style="color:#94a3b8">\(pct)% used</div>
              </div>
              <div style="height:14px;background:#334155;border-radius:7px;overflow:hidden;margin-top:8px">
                <div style="height:100%;width:\(pct)%;background:linear-gradient(90deg,#16a34a 0%,#84cc16 40%,#f59e0b 70%,#dc2626 100%)"></div>
              </div>
              <div class="lbl">Endurance (rated TBW)</div>
            </div>
            """
        }

        var sanitizeChip: String
        if sanitize.isEmpty {
            sanitizeChip = chip("Sanitize", nil)
        } else {
            sanitizeChip = chipText("Sanitize", "\(sanitize.count) methods", color: "#f59e0b")
        }
        let discardChip = chip("\(discardMech)", trimSupp,
                                yes: trimLevel.isEmpty ? "yes" : "yes (\(trimLevel))")

        let tierColor = tier == "enterprise" ? "#a855f7" : (tier == "consumer" ? "#3b82f6" : "#94a3b8")
        let tierLabel = tier == "enterprise" ? "Enterprise" : (tier == "consumer" ? "Consumer" : "Unknown")
        let sourceColor = dataSource == "OurDB" ? "#16a34a" : (dataSource == "smartctl" ? "#3b82f6" : "#94a3b8")

        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <title>\(esc(model)) — Disk Report</title>
        <style>
        body{font:14px -apple-system,Segoe UI,Roboto,sans-serif;margin:0;background:#0f172a;color:#e2e8f0;padding:28px;max-width:1100px;margin:auto}
        h1{font-size:24px;margin:0 0 4px;font-weight:700}
        h3{margin:24px 0 8px;font-size:16px;color:#cbd5e1}
        .sub{color:#94a3b8;margin-bottom:18px;font-size:13px}
        .cards{display:flex;gap:14px;flex-wrap:wrap;margin-bottom:22px}
        .card{background:#1e293b;border:1px solid #334155;border-radius:14px;padding:16px;min-width:130px;flex:0 0 auto}
        .ring{--p:0;width:96px;height:96px;border-radius:50%;display:grid;place-items:center;margin:auto;
              background:conic-gradient(var(--c) calc(var(--p)*1%),#334155 0)}
        .ring span{background:#1e293b;width:74px;height:74px;border-radius:50%;display:grid;place-items:center;font-weight:700;font-size:18px}
        .lbl{text-align:center;color:#94a3b8;font-size:12px;margin-top:6px}
        .big{font-size:26px;font-weight:700}
        .chip{padding:4px 9px;border-radius:6px;font-size:12px;font-weight:600;display:inline-block;margin:2px}
        .chips{display:flex;flex-wrap:wrap;gap:4px;margin:10px 0 20px}
        table{width:100%;border-collapse:collapse;margin:8px 0 22px;background:#0f172a}
        th,td{text-align:left;padding:6px 8px;border-bottom:1px solid #1e293b;font-size:13px}
        th{color:#94a3b8;font-weight:600}.n{text-align:right;font-variant-numeric:tabular-nums}
        .dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:6px;vertical-align:middle}
        .bar{display:flex;height:30px;border-radius:8px;overflow:hidden;gap:1px;margin:8px 0 16px}
        .badge{padding:6px 12px;border-radius:8px;font-weight:700;color:#fff;display:inline-block}
        </style></head><body>
        <h1>\(esc(model))</h1>
        <div class="sub">
          \(esc(family.isEmpty ? "—" : family))
          <span class="chip" style="background:\(sourceColor)1a;color:\(sourceColor);margin-left:6px">Source: \(esc(dataSource))</span>
          <br>SN \(esc(smart["serial"] as? String ?? "—")) · FW \(esc(smart["firmware"] as? String ?? "")) ·
          \(String(format: "%.1f GB", gb)) · \((smart["isSSD"] as? Bool ?? true) ? "SSD" : "HDD") ·
          \(esc(smart["protocol"] as? String ?? "")) · \(esc(smart["formFactor"] as? String ?? "—")) · \(when)
        </div>

        <h3>Static specs</h3>
        <div class="chips">
          \(chipText("Class", tierLabel, color: tierColor))
          \(chip("DRAM", dramVal))
          \(chipText("NAND", nand, color: "#3b82f6"))
          \(chip("PLP", plpVal))
          \(discardChip)
          \(sanitizeChip)
        </div>

        <h3>Current state</h3>
        <div class="cards">
          <div class="card"><div class="ring" style="--c:\(life>50 ? "#16a34a" : (life>20 ? "#f59e0b":"#dc2626"));--p:\(life)"><span>\(life)%</span></div><div class="lbl">Life remaining</div></div>
          <div class="card"><div class="ring" style="--c:\(temp<45 ? "#16a34a" : (temp<60 ? "#f59e0b":"#dc2626"));--p:\(min(100,temp*100/70))"><span>\(temp)°</span></div><div class="lbl">Temperature\((smart["temperatureMaxC"] as? Int).map { " · max \($0)°" } ?? "")</div></div>
          <div class="card"><div class="big">\(smart["powerOnHours"] as? Int ?? 0)</div><div class="lbl">Operating hours</div></div>
          <div class="card"><div class="big">\(smart["powerCycles"] as? Int ?? 0)</div><div class="lbl">Power-ups</div></div>
          <div class="card"><div class="badge" style="background:\(healthColor)">\(health)</div><div class="lbl">SMART</div></div>
          \(enduranceBlock)
        </div>

        <h3>Partition map — \(esc(layout["scheme"] as? String ?? "—"))</h3>
        <div class="bar">\(bar)</div>
        <table><tr><th>Volume</th><th>Name</th><th>Filesystem</th><th class="n">Size</th><th>Mount</th></tr>\(partRows)</table>

        <h3>SMART attributes</h3>
        <table><tr><th></th><th>ID</th><th>Attribute</th><th class="n">Value</th><th class="n">Worst</th><th class="n">Threshold</th><th class="n">Data</th></tr>\(attrRows)</table>

        <div class="sub">Generated by OS Disk Manager.</div>
        </body></html>
        """
    }
}
