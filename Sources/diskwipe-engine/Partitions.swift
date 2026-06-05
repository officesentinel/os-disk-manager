import Foundation

/// Partition / volume management wrapping `diskutil`.
/// Apple-native personalities only (APFS, HFS+ journaled, ExFAT, FAT32).
enum Partitions {

    /// Map friendly filesystem name -> diskutil personality.
    static func personality(_ fs: String) -> String {
        switch fs.lowercased() {
        case "apfs": return "APFS"
        case "apfs-case", "apfsx": return "APFSX"
        case "hfs+", "hfs", "jhfs+", "mac os extended": return "JHFS+"
        case "exfat": return "ExFAT"
        case "fat32", "ms-dos", "msdos": return "FAT32"
        case "free", "none": return "free"
        // ext* are NOT diskutil personalities — handled separately via mke2fs.
        case "ext4", "ext3", "ext2", "ext": return fs.uppercased()
        default: return fs   // pass through if caller already gave a personality
        }
    }
    static func isExt(_ fs: String) -> Bool {
        let l = fs.lowercased()
        return l == "ext" || l == "ext2" || l == "ext3" || l == "ext4"
    }

    // MARK: - Read layout

    /// Full layout of a whole disk: scheme + per-partition details.
    static func layout(_ disk: String) -> [String: Any] {
        var result: [String: Any] = ["disk": disk]
        let res = Shell.run(Shell.diskutil, ["list", "-plist", disk])
        guard let data = res.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let all = dict["AllDisksAndPartitions"] as? [[String: Any]],
              let whole = all.first else {
            result["partitions"] = []
            return result
        }
        result["scheme"] = whole["Content"] as? String ?? "—"
        result["sizeBytes"] = whole["Size"] as? Int64 ?? 0

        var parts: [[String: Any]] = []
        let rawParts = whole["Partitions"] as? [[String: Any]] ?? []
        let scheme = (whole["Content"] as? String) ?? ""
        var prevFS: String? = nil
        for p in rawParts {
            guard let pid = p["DeviceIdentifier"] as? String else { continue }
            var detail = volumeDetail(pid, fallback: p)
            let caps = Capabilities.compute(
                fs: detail["fs"] as? String ?? "",
                scheme: scheme,
                prevFS: prevFS,
                isAPFSContainerVolume: false,
                content: detail["content"] as? String ?? ""
            )
            detail["capabilities"] = caps.dict()
            parts.append(detail)
            prevFS = detail["fs"] as? String
            // APFS containers expose volumes inside.
            if let apfs = p["APFSVolumes"] as? [[String: Any]] {
                for v in apfs {
                    if let vid = v["DeviceIdentifier"] as? String {
                        var d = volumeDetail(vid, fallback: v)
                        d["apfsVolume"] = true
                        let inner = Capabilities.compute(
                            fs: d["fs"] as? String ?? "",
                            scheme: scheme, prevFS: nil,
                            isAPFSContainerVolume: true,
                            content: d["content"] as? String ?? ""
                        )
                        d["capabilities"] = inner.dict()
                        parts.append(d)
                    }
                }
            }
        }
        result["partitions"] = parts
        return result
    }

    private static func volumeDetail(_ id: String, fallback: [String: Any]) -> [String: Any] {
        var d: [String: Any] = ["id": id]
        let res = Shell.run(Shell.diskutil, ["info", "-plist", id])
        if let data = res.stdout.data(using: .utf8),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let info = plist as? [String: Any] {
            d["name"] = (info["VolumeName"] as? String) ?? (fallback["VolumeName"] as? String) ?? ""
            d["fs"] = (info["FilesystemUserVisibleName"] as? String)
                    ?? (info["FilesystemName"] as? String)
                    ?? (info["Content"] as? String) ?? "—"
            d["sizeBytes"] = (info["TotalSize"] as? Int64) ?? (info["Size"] as? Int64)
                          ?? (fallback["Size"] as? Int64) ?? 0
            d["mount"] = (info["MountPoint"] as? String) ?? ""
            d["content"] = (info["Content"] as? String) ?? ""
        } else {
            d["name"] = fallback["VolumeName"] as? String ?? ""
            d["fs"] = fallback["Content"] as? String ?? "—"
            d["sizeBytes"] = fallback["Size"] as? Int64 ?? 0
            d["mount"] = fallback["MountPoint"] as? String ?? ""
        }
        return d
    }

    // MARK: - Mutating operations (each returns ShellResult)

    /// Destructive: repartition whole disk. specs = ["fs:name:size", ...] (size "0b" = remaining).
    static func repartition(disk: String, scheme: String, specs: [String]) -> ShellResult {
        var args = ["partitionDisk", disk, scheme]
        for spec in specs {
            let parts = spec.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            let fs = parts.count > 0 ? personality(parts[0]) : "JHFS+"
            let name = parts.count > 1 && !parts[1].isEmpty ? parts[1] : "Untitled"
            let size = parts.count > 2 && !parts[2].isEmpty ? parts[2] : "0b"
            args += [fs, name, size]
        }
        return Shell.run(Shell.diskutil, args)
    }

    /// Reformat an existing volume in place (destroys that volume's data only).
    static func format(volume: String, fs: String, name: String) -> ShellResult {
        let safeName = name.isEmpty ? "Untitled" : name
        if isExt(fs) {
            // Unmount first; mke2fs operates on the raw block device.
            _ = Shell.run(Shell.diskutil, ["unmountDisk", "force", "/dev/\(volume)"])
            let extType = fs.lowercased() == "ext2" ? "ext2"
                        : fs.lowercased() == "ext3" ? "ext3" : "ext4"
            return Shell.run(Shell.mke2fs, ["-t", extType, "-L", safeName, "-F", "/dev/\(volume)"])
        }
        return Shell.run(Shell.diskutil, ["eraseVolume", personality(fs), safeName, volume])
    }

    /// Resize a volume (grow/shrink, data-preserving). Optional new partitions
    /// created from freed space: add = ["fs:name:size", ...].
    static func resize(volume: String, size: String, add: [String]) -> ShellResult {
        var args = ["resizeVolume", volume, size]
        for spec in add {
            let parts = spec.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            let fs = parts.count > 0 ? personality(parts[0]) : "JHFS+"
            let name = parts.count > 1 && !parts[1].isEmpty ? parts[1] : "Untitled"
            let sz = parts.count > 2 && !parts[2].isEmpty ? parts[2] : "0b"
            args += [fs, name, sz]
        }
        return Shell.run(Shell.diskutil, args)
    }

    /// Add a volume: shrink `volume` to `shrinkTo`, create a new one in freed space.
    static func addVolume(volume: String, shrinkTo: String, fs: String, name: String) -> ShellResult {
        resize(volume: volume, size: shrinkTo, add: ["\(fs):\(name):0b"])
    }

    /// Delete a partition by merging it into its previous sibling (previous keeps its data/FS).
    static func delete(volume: String) -> ShellResult {
        // volume like "disk4s3" -> whole "disk4", index 3.
        guard let sIdx = volume.range(of: "s", options: .backwards) else {
            return ShellResult(exitCode: 2, stdout: "", stderr: "bad volume id \(volume)")
        }
        let whole = String(volume[volume.startIndex..<sIdx.lowerBound])
        guard let idx = Int(volume[sIdx.upperBound...]), idx > 1 else {
            return ShellResult(exitCode: 2, stdout: "", stderr: "cannot delete first partition; repartition instead")
        }
        let prev = "\(whole)s\(idx - 1)"
        // Determine prev's FS to preserve it.
        let info = Shell.run(Shell.diskutil, ["info", "-plist", prev])
        var fs = "JHFS+"
        var name = "Untitled"
        if let data = info.stdout.data(using: .utf8),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let d = plist as? [String: Any] {
            if let fsv = d["FilesystemName"] as? String { fs = personality(fsv) }
            if let nm = d["VolumeName"] as? String, !nm.isEmpty { name = nm }
        }
        // mergePartitions <format> <name> <from> <to>  (preserves data on first when format matches)
        return Shell.run(Shell.diskutil, ["mergePartitions", fs, name, prev, volume])
    }
}
