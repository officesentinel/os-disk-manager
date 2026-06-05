import Foundation

/// What you can actually do with a given partition on macOS,
/// given its filesystem, its previous sibling, and the disk scheme.
struct PartCapabilities {
    var canFormat = true
    var canResize = false
    var canDelete = false
    var canAddNext = false   // shrink this and create a new partition in freed space
    /// Localization-friendly reason codes. The GUI maps them to human strings.
    var formatReasonKey: String?
    var resizeReasonKey: String?
    var deleteReasonKey: String?
    var addReasonKey: String?

    func dict() -> [String: Any] {
        var d: [String: Any] = [
            "canFormat": canFormat, "canResize": canResize,
            "canDelete": canDelete, "canAddNext": canAddNext
        ]
        if let v = formatReasonKey { d["formatReason"] = v }
        if let v = resizeReasonKey { d["resizeReason"] = v }
        if let v = deleteReasonKey { d["deleteReason"] = v }
        if let v = addReasonKey { d["addReason"] = v }
        return d
    }
}

enum Capabilities {
    /// Determine what's possible for a given partition.
    /// - parameter fs: user-visible filesystem name (e.g. "APFS", "MS-DOS FAT32", "NTFS", "ExFAT", "Mac OS Extended (Journaled)").
    /// - parameter scheme: "GUID_partition_scheme" (GPT), "FDisk_partition_scheme" (MBR), etc.
    /// - parameter prevFS: previous sibling's filesystem (nil if no previous).
    /// - parameter isAPFSContainerVolume: true for volumes inside an APFS container.
    /// - parameter content: partition Content GUID name (e.g. "EFI", "Apple_APFS", "Microsoft Basic Data", "Windows_NTFS").
    static func compute(fs: String, scheme: String, prevFS: String?,
                        isAPFSContainerVolume: Bool, content: String) -> PartCapabilities {
        var c = PartCapabilities()

        // Service partitions (EFI, MSR, recovery) — read-only conceptually.
        let serviceContents = ["EFI", "Microsoft Reserved", "Apple_APFS_Recovery", "Apple_APFS_ISC", "Linux_Swap"]
        if serviceContents.contains(content) || content.contains("Recovery") {
            c.canFormat = false; c.formatReasonKey = "cap.service"
            c.canResize = false; c.resizeReasonKey = "cap.service"
            c.canDelete = false; c.deleteReasonKey = "cap.service"
            c.canAddNext = false; c.addReasonKey = "cap.service"
            return c
        }

        let fsLower = fs.lowercased()
        let isAPFS = fsLower.contains("apfs")
        let isHFS = fsLower.contains("hfs") || fsLower.contains("mac os extended") || fsLower.contains("journaled")
        let isExFAT = fsLower.contains("exfat")
        let isFAT = fsLower.contains("fat") && !isExFAT
        let isNTFS = fsLower.contains("ntfs") || content.lowercased().contains("ntfs")
        let isExt = fsLower.contains("ext")

        // FORMAT — anything except NTFS (macOS can't write NTFS via diskutil).
        if isNTFS {
            c.canFormat = false; c.formatReasonKey = "cap.ntfsNoFormat"
        } else {
            c.canFormat = true
        }

        // RESIZE — only filesystems diskutil understands at write level.
        if isAPFS || isHFS {
            c.canResize = true
        } else if isExt {
            c.canResize = false; c.resizeReasonKey = "cap.extResize"
        } else if isExFAT {
            c.canResize = false; c.resizeReasonKey = "cap.exfatResize"
        } else if isFAT {
            c.canResize = false; c.resizeReasonKey = "cap.fatResize"
        } else if isNTFS {
            c.canResize = false; c.resizeReasonKey = "cap.ntfsResize"
        } else {
            c.canResize = false; c.resizeReasonKey = "cap.unknownFS"
        }
        // MBR / APM additionally restrict resize behaviour.
        if scheme.lowercased().contains("fdisk") || scheme.lowercased().contains("mbr") {
            if c.canResize { /* still allowed but flag */ }
        }
        if isAPFSContainerVolume {
            // APFS volumes within a container — diskutil handles them differently;
            // shrinking via resizeVolume targets the container, not the volume. Disable here for safety.
            c.canResize = false; c.resizeReasonKey = "cap.apfsContainer"
            c.canAddNext = false; c.addReasonKey = "cap.apfsContainer"
        }

        // ADD-NEXT requires resize of THIS volume to free space.
        c.canAddNext = c.canResize
        if !c.canAddNext && c.addReasonKey == nil { c.addReasonKey = c.resizeReasonKey }

        // DELETE merges into previous sibling — requires previous to be resizable.
        if let pf = prevFS {
            let pLower = pf.lowercased()
            let prevResizable = pLower.contains("apfs") || pLower.contains("hfs") || pLower.contains("mac os extended") || pLower.contains("journaled")
            if prevResizable {
                c.canDelete = true
            } else {
                c.canDelete = false; c.deleteReasonKey = "cap.prevNotResizable"
            }
        } else {
            c.canDelete = false; c.deleteReasonKey = "cap.firstPartition"
        }

        return c
    }
}
