import Foundation

/// Parsed subset of SMART data relevant to a wipe/health report.
struct SmartSnapshot {
    var healthPassed: Bool?
    var powerOnHours: Int?
    var powerCycles: Int?
    var reallocated: Int?
    var pending: Int?
    var offlineUncorrectable: Int?
    var reportedUncorrect: Int?
    var crcErrors: Int?
    var commandTimeout: Int?
    var temperatureC: Int?
    var temperatureMaxC: Int?
    // Wear: many vendors differ. Capture both the SSD life-left % if exposed
    // and the average block-erase / wear-leveling raw count.
    var wearLevelingRaw: Int?
    var aveBlockEraseRaw: Int?
    var wearValueNormalized: Int?   // normalized VALUE of the wear attribute (100 -> threshold)
    var totalLBAsWritten: Int?

    var dictionary: [String: Any] {
        var d: [String: Any] = [:]
        if let v = healthPassed { d["healthPassed"] = v }
        if let v = powerOnHours { d["powerOnHours"] = v }
        if let v = powerCycles { d["powerCycles"] = v }
        if let v = reallocated { d["reallocated"] = v }
        if let v = pending { d["pending"] = v }
        if let v = offlineUncorrectable { d["offlineUncorrectable"] = v }
        if let v = reportedUncorrect { d["reportedUncorrect"] = v }
        if let v = crcErrors { d["crcErrors"] = v }
        if let v = commandTimeout { d["commandTimeout"] = v }
        if let v = temperatureC { d["temperatureC"] = v }
        if let v = temperatureMaxC { d["temperatureMaxC"] = v }
        if let v = wearLevelingRaw { d["wearLevelingRaw"] = v }
        if let v = aveBlockEraseRaw { d["aveBlockEraseRaw"] = v }
        if let v = wearValueNormalized { d["wearValueNormalized"] = v }
        if let v = totalLBAsWritten { d["totalLBAsWritten"] = v }
        return d
    }
}

enum Smart {
    /// Full SMART snapshot via `smartctl --json -a`.
    static func snapshot(_ node: String) -> SmartSnapshot {
        var s = SmartSnapshot()
        let res = Shell.run(Shell.smartctl, ["--json=c", "-a", node])
        guard let data = res.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return s
        }
        if let status = obj["smart_status"] as? [String: Any] {
            s.healthPassed = status["passed"] as? Bool
        }
        if let poh = obj["power_on_time"] as? [String: Any] {
            s.powerOnHours = poh["hours"] as? Int
        }
        s.powerCycles = obj["power_cycle_count"] as? Int
        if let temp = obj["temperature"] as? [String: Any] {
            s.temperatureC = temp["current"] as? Int
        }

        guard let attrs = obj["ata_smart_attributes"] as? [String: Any],
              let table = attrs["table"] as? [[String: Any]] else {
            return s
        }
        func raw(_ id: Int) -> Int? {
            for a in table where (a["id"] as? Int) == id {
                if let r = a["raw"] as? [String: Any] { return r["value"] as? Int }
            }
            return nil
        }
        func normalized(_ id: Int) -> Int? {
            for a in table where (a["id"] as? Int) == id { return a["value"] as? Int }
            return nil
        }
        s.reallocated = raw(5)
        s.pending = raw(197)
        s.offlineUncorrectable = raw(198)
        s.reportedUncorrect = raw(187)
        s.crcErrors = raw(199)
        s.commandTimeout = raw(188)
        s.totalLBAsWritten = raw(241)
        // Wear: 177 = Wear_Leveling_Count (Samsung/SPCC), 173 = Ave_Block-Erase (Micron/Crucial)
        if let wl = raw(177) { s.wearLevelingRaw = wl; s.wearValueNormalized = normalized(177) }
        if let be = raw(173) { s.aveBlockEraseRaw = be; s.wearValueNormalized = normalized(173) ?? s.wearValueNormalized }
        return s
    }

    /// Full SMART report for the dashboard: every attribute + computed wear/life/temp.
    static func fullReport(_ node: String) -> [String: Any] {
        var out: [String: Any] = [:]
        let res = Shell.run(Shell.smartctl, ["--json=c", "-a", node])
        guard let data = res.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return out
        }
        out["model"] = (obj["model_name"] as? String) ?? (obj["device_model"] as? String) ?? "—"
        // smartctl's own family from its drivedb.h (updated via `brew upgrade smartmontools`).
        // Used as fallback when our model database doesn't have an entry.
        if let smartFamily = obj["model_family"] as? String { out["smartctlFamily"] = smartFamily }
        out["serial"] = obj["serial_number"] as? String ?? ""
        out["firmware"] = obj["firmware_version"] as? String ?? ""
        if let cap = obj["user_capacity"] as? [String: Any] { out["sizeBytes"] = cap["bytes"] as? Int64 ?? 0 }
        out["rotationRate"] = obj["rotation_rate"] as? Int ?? 0   // 0 = SSD
        out["isSSD"] = (obj["rotation_rate"] as? Int ?? 0) == 0
        if let iface = obj["device"] as? [String: Any] { out["protocol"] = iface["protocol"] as? String ?? "" }
        if let ff = obj["form_factor"] as? [String: Any], let name = ff["name"] as? String {
            out["formFactor"] = name
        } else {
            out["formFactor"] = obj["form_factor"] as? String ?? ""
        }
        // Discard mechanism name varies by interface:
        //   ATA  → TRIM       NVMe → Deallocate (mandatory per spec)     SCSI/SAS → UNMAP
        let protoU = (out["protocol"] as? String ?? "").uppercased()
        switch protoU {
        case "NVME":
            out["discardMechanism"] = "Deallocate"
            // NVMe Deallocate is mandatory; treat as supported unless explicitly disabled elsewhere.
            if out["trimSupported"] == nil { out["trimSupported"] = true }
        case "SCSI", "SAS":
            out["discardMechanism"] = "UNMAP"
        default:
            out["discardMechanism"] = "TRIM"
        }
        // Secure-erase / sanitize family (orthogonal to discard).
        var sanitize: [String] = []
        if obj["ata_security"] != nil { sanitize.append("ATA Security Erase") }
        if obj["ata_sanitize_device"] != nil || obj["ata_sanitize"] != nil {
            sanitize.append("ATA Sanitize")
        }
        if let nvmeFormat = obj["nvme_format"] {
            sanitize.append("NVMe Format")
            _ = nvmeFormat   // reserved for future detail extraction
        }
        if obj["nvme_sanitize"] != nil { sanitize.append("NVMe Sanitize") }
        if !sanitize.isEmpty { out["sanitizeMethods"] = sanitize }
        // Static metadata resolution priority:
        //   1. OurDB  — curated entries (DRAM, NAND, PLP, TBW, family)
        //   2. smartctl drivedb.h — model_family fallback for the family string only
        //   3. nil    — UI shows "no data" rather than guessing
        if let spec = DiskDatabase.match(out["model"] as? String) {
            // OurDB hit — authoritative for the fields it knows.
            if let dram = spec.dram { out["dramCache"] = dram }
            let dbFamily = "\(spec.brand) \(spec.family)".trimmingCharacters(in: .whitespaces)
            if !dbFamily.isEmpty {
                out["family"] = dbFamily
                out["dramCacheReason"] = dbFamily
            }
            if let nand = spec.nand { out["nandType"] = nand }
            if let ctrl = spec.controller { out["controller"] = ctrl }
            if let plp = spec.plp { out["plp"] = plp }
            if let tbw = spec.tbwPerTb { out["tbwPerTb"] = tbw }
            out["dataSource"] = "OurDB"
        } else if let smartFamily = obj["model_family"] as? String {
            // OurDB miss — fall back to smartctl's drivedb.h family string.
            // smartctl doesn't carry DRAM/NAND/PLP info, so those stay nil
            // and the UI will show "no data" honestly.
            out["family"] = smartFamily
            out["dataSource"] = "smartctl"
        } else {
            out["dataSource"] = "none"
        }
        // Disk tier (enterprise / consumer / unknown) — heuristic by model + interface + form factor + capacity.
        let tierResult = TierClassifier.classify(
            model: out["model"] as? String,
            proto: out["protocol"] as? String,
            formFactor: out["formFactor"] as? String,
            sizeBytes: out["sizeBytes"] as? Int64
        )
        out["tier"] = tierResult.tier.rawValue
        out["tierReason"] = tierResult.reason
        out["healthPassed"] = (obj["smart_status"] as? [String: Any])?["passed"] as? Bool
        // TRIM support — three states: present+supported=Yes, present+!supported=No, absent=No data.
        // Plus a level/variant: DZAT (zeroed) > DRAT (deterministic) > Basic.
        if let trim = obj["trim"] as? [String: Any], let supported = trim["supported"] as? Bool {
            out["trimSupported"] = supported
            if supported {
                let isDet = trim["deterministic"] as? Bool == true
                let isZero = trim["zeroed"] as? Bool == true
                var quals: [String] = []
                if isDet { quals.append("deterministic") }
                if isZero { quals.append("zeroed") }
                if !quals.isEmpty { out["trimDetail"] = quals.joined(separator: ", ") }
                let level: String
                if isZero && isDet { level = "DZAT" }
                else if isDet { level = "DRAT" }
                else { level = "basic" }
                out["trimLevel"] = level
            }
        }
        if let poh = obj["power_on_time"] as? [String: Any] { out["powerOnHours"] = poh["hours"] as? Int ?? 0 }
        out["powerCycles"] = obj["power_cycle_count"] as? Int ?? 0
        if let temp = obj["temperature"] as? [String: Any] { out["temperatureC"] = temp["current"] as? Int ?? 0 }

        var attrs: [[String: Any]] = []
        var lifeLeft: Int? = nil
        var tempMax: Int? = nil
        if let table = (obj["ata_smart_attributes"] as? [String: Any])?["table"] as? [[String: Any]] {
            for a in table {
                let id = a["id"] as? Int ?? 0
                let value = a["value"] as? Int ?? 0
                let worst = a["worst"] as? Int ?? 0
                let thresh = a["thresh"] as? Int ?? 0
                let rawObj = a["raw"] as? [String: Any]
                let rawVal = rawObj?["value"] as? Int ?? 0
                let rawStr = rawObj?["string"] as? String ?? "\(rawVal)"
                let whenFailed = a["when_failed"] as? String ?? ""
                let name = a["name"] as? String ?? "Attr_\(id)"
                let flags = a["flags"] as? [String: Any]
                let prefail = flags?["prefailure"] as? Bool ?? false

                // Status classification.
                var status = "ok"
                if !whenFailed.isEmpty && whenFailed != "-" { status = "fail" }
                else if thresh > 0 && value <= thresh { status = "fail" }
                else if prefail && thresh > 0 && (value - thresh) <= 10 { status = "warn" }
                if [5, 187, 197, 198].contains(id) && rawVal > 0 { status = status == "ok" ? "warn" : status }

                attrs.append([
                    "id": id, "name": name, "value": value, "worst": worst, "thresh": thresh,
                    "raw": rawVal, "rawString": rawStr, "whenFailed": whenFailed,
                    "prefail": prefail, "status": status
                ])

                // Life-left from a wear attribute (normalized VALUE counts down 100 -> threshold).
                if lifeLeft == nil && [177, 173, 233, 202, 231, 169].contains(id) { lifeLeft = value }
                // Max temperature from attr 194 raw string e.g. "40 (Min/Max 18/59)".
                if id == 194, let r = rawStr.range(of: #"Min/Max \d+/(\d+)"#, options: .regularExpression) {
                    let m = rawStr[r].replacingOccurrences(of: "Min/Max ", with: "")
                    if let mx = m.split(separator: "/").last.flatMap({ Int($0) }) { tempMax = mx }
                }
            }
        }
        out["attributes"] = attrs
        if let ll = lifeLeft { out["lifeLeftPercent"] = ll; out["wearPercentUsed"] = max(0, 100 - ll) }
        if let tm = tempMax { out["temperatureMaxC"] = tm }
        return out
    }

    /// Start an extended (long) self-test. Returns estimated minutes, or nil on failure.
    static func startLongTest(_ node: String) -> Int? {
        let res = Shell.run(Shell.smartctl, ["-t", "long", node])
        guard res.ok || res.stdout.contains("Testing has begun") else { return nil }
        // Parse "Please wait NN minutes".
        if let r = res.stdout.range(of: #"wait (\d+) minutes"#, options: .regularExpression) {
            let s = res.stdout[r].replacingOccurrences(of: "wait ", with: "")
                .replacingOccurrences(of: " minutes", with: "")
            return Int(s)
        }
        return 21
    }

    /// Poll self-test progress. Returns (inProgress, remainingPercent).
    static func longTestProgress(_ node: String) -> (inProgress: Bool, remainingPercent: Int) {
        let res = Shell.run(Shell.smartctl, ["--json=c", "-c", node])
        guard let data = res.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let asd = obj["ata_smart_data"] as? [String: Any],
              let st = asd["self_test"] as? [String: Any],
              let status = st["status"] as? [String: Any] else {
            return (false, 0)
        }
        let remaining = status["remaining_percent"] as? Int ?? 0
        // value 249/241 etc: "in progress" when remaining_percent present and > 0,
        // smartctl also sets "value" with bit 0xF0 == 0xF0 while running.
        let running = (status["remaining_percent"] as? Int) != nil && remaining > 0
        return (running, remaining)
    }

    /// Read most recent self-test log result string.
    static func lastSelfTestResult(_ node: String) -> String {
        let res = Shell.run(Shell.smartctl, ["-l", "selftest", node])
        for line in res.stdout.split(separator: "\n") {
            if line.contains("# 1") { return line.trimmingCharacters(in: .whitespaces) }
        }
        return "unknown"
    }
}
