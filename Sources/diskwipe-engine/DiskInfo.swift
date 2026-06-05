import Foundation

struct DiskInfo {
    let id: String            // e.g. "disk4"
    let node: String          // e.g. "/dev/disk4"
    let rawNode: String       // e.g. "/dev/rdisk4"
    let sizeBytes: Int64
    let blockSize: Int64
    let model: String
    let serial: String
    let firmware: String
    let busProtocol: String
    let isSSD: Bool
    let removable: Bool
    let isInternal: Bool

    var sizeGB: Double { Double(sizeBytes) / 1_000_000_000.0 }

    var dictionary: [String: Any] {
        [
            "id": id, "node": node, "rawNode": rawNode,
            "sizeBytes": sizeBytes, "sizeGB": sizeGB, "blockSize": blockSize,
            "model": model, "serial": serial, "firmware": firmware,
            "busProtocol": busProtocol, "isSSD": isSSD,
            "removable": removable, "isInternal": isInternal
        ]
    }

    /// Load detailed info for a given disk id via `diskutil info -plist`.
    static func load(_ id: String) -> DiskInfo? {
        let res = Shell.run(Shell.diskutil, ["info", "-plist", id])
        guard res.ok, let data = res.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any] else {
            return nil
        }
        let size = (dict["Size"] as? Int64) ?? (dict["TotalSize"] as? Int64) ?? 0
        let bs = (dict["DeviceBlockSize"] as? Int64) ?? 512
        let node = (dict["DeviceNode"] as? String) ?? "/dev/\(id)"
        let internalDisk = (dict["Internal"] as? Bool) ?? false
        let removable = (dict["Removable"] as? Bool) ?? (dict["RemovableMedia"] as? Bool) ?? false
        let solid = (dict["SolidState"] as? Bool) ?? false
        let bus = (dict["BusProtocol"] as? String) ?? "?"
        var model = (dict["MediaName"] as? String) ?? "?"
        // diskutil often truncates model; prefer smartctl identity if available.
        var serial = ""
        var firmware = ""
        if let sm = smartIdentity(node) {
            if !sm.model.isEmpty { model = sm.model }
            serial = sm.serial
            firmware = sm.firmware
        }
        return DiskInfo(
            id: id, node: node, rawNode: node.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk"),
            sizeBytes: size, blockSize: bs, model: model, serial: serial,
            firmware: firmware, busProtocol: bus, isSSD: solid,
            removable: removable, isInternal: internalDisk
        )
    }

    private static func smartIdentity(_ node: String) -> (model: String, serial: String, firmware: String)? {
        let res = Shell.run(Shell.smartctl, ["--json=c", "-i", node])
        guard let data = res.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let model = (obj["model_name"] as? String) ?? (obj["device_model"] as? String) ?? ""
        let serial = (obj["serial_number"] as? String) ?? ""
        let fw = (obj["firmware_version"] as? String) ?? ""
        return (model, serial, fw)
    }

    /// List all external physical disks.
    static func listExternal() -> [DiskInfo] {
        let res = Shell.run(Shell.diskutil, ["list", "-plist", "external", "physical"])
        guard res.ok, let data = res.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let whole = dict["WholeDisks"] as? [String] else {
            return []
        }
        return whole.compactMap { load($0) }
    }
}
