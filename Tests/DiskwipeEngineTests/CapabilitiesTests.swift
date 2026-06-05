import XCTest
@testable import diskwipe_engine

final class CapabilitiesTests: XCTestCase {

    // MARK: - service partitions are fully locked

    func testEFILocked() {
        let c = Capabilities.compute(
            fs: "MS-DOS FAT32", scheme: "GUID_partition_scheme",
            prevFS: nil, isAPFSContainerVolume: false, content: "EFI")
        XCTAssertFalse(c.canFormat)
        XCTAssertFalse(c.canResize)
        XCTAssertFalse(c.canDelete)
        XCTAssertFalse(c.canAddNext)
        XCTAssertEqual(c.formatReasonKey, "cap.service")
    }

    func testAppleRecoveryLocked() {
        let c = Capabilities.compute(
            fs: "APFS", scheme: "GUID_partition_scheme",
            prevFS: "APFS", isAPFSContainerVolume: true, content: "Apple_APFS_Recovery")
        XCTAssertFalse(c.canFormat)
        XCTAssertFalse(c.canResize)
        XCTAssertFalse(c.canDelete)
    }

    // MARK: - NTFS read-only on macOS

    func testNTFSNoFormat() {
        let c = Capabilities.compute(
            fs: "NTFS", scheme: "GUID_partition_scheme",
            prevFS: "APFS", isAPFSContainerVolume: false, content: "Windows_NTFS")
        XCTAssertFalse(c.canFormat, "macOS cannot write NTFS")
        XCTAssertEqual(c.formatReasonKey, "cap.ntfsNoFormat")
        XCTAssertFalse(c.canResize)
        XCTAssertEqual(c.resizeReasonKey, "cap.ntfsResize")
    }

    // MARK: - APFS / HFS+ are fully manageable

    func testAPFSPhysicalStoreFullyManageable() {
        let c = Capabilities.compute(
            fs: "APFS", scheme: "GUID_partition_scheme",
            prevFS: "Apple HFS", isAPFSContainerVolume: false, content: "Apple_APFS")
        XCTAssertTrue(c.canFormat)
        XCTAssertTrue(c.canResize)
        XCTAssertTrue(c.canAddNext, "if you can resize, you can add a sibling")
    }

    func testHFSResizable() {
        let c = Capabilities.compute(
            fs: "Mac OS Extended (Journaled)", scheme: "GUID_partition_scheme",
            prevFS: nil, isAPFSContainerVolume: false, content: "Apple_HFS")
        XCTAssertTrue(c.canResize)
        XCTAssertTrue(c.canAddNext)
    }

    // MARK: - APFS volumes inside a container are special

    func testAPFSContainerVolumeNotDirectlyResizable() {
        let c = Capabilities.compute(
            fs: "APFS", scheme: "GUID_partition_scheme",
            prevFS: "APFS", isAPFSContainerVolume: true, content: "Apple_APFS")
        XCTAssertFalse(c.canResize, "container-volume resize goes via the container, not the volume")
        XCTAssertEqual(c.resizeReasonKey, "cap.apfsContainer")
        XCTAssertFalse(c.canAddNext)
    }

    // MARK: - exFAT/FAT/ext can format but not resize

    func testExFATCanFormatNotResize() {
        let c = Capabilities.compute(
            fs: "ExFAT", scheme: "GUID_partition_scheme",
            prevFS: "APFS", isAPFSContainerVolume: false, content: "Microsoft Basic Data")
        XCTAssertTrue(c.canFormat)
        XCTAssertFalse(c.canResize)
        XCTAssertEqual(c.resizeReasonKey, "cap.exfatResize")
    }

    func testExt4CanFormatNotResize() {
        let c = Capabilities.compute(
            fs: "ext4", scheme: "GUID_partition_scheme",
            prevFS: "APFS", isAPFSContainerVolume: false, content: "Linux Filesystem")
        XCTAssertTrue(c.canFormat)
        XCTAssertFalse(c.canResize)
        XCTAssertEqual(c.resizeReasonKey, "cap.extResize")
    }

    // MARK: - delete merges into previous sibling

    func testDeleteRequiresResizablePrevious() {
        let cAfterAPFS = Capabilities.compute(
            fs: "ExFAT", scheme: "GUID_partition_scheme",
            prevFS: "APFS", isAPFSContainerVolume: false, content: "Microsoft Basic Data")
        XCTAssertTrue(cAfterAPFS.canDelete, "previous = APFS → can absorb")

        let cAfterExFAT = Capabilities.compute(
            fs: "APFS", scheme: "GUID_partition_scheme",
            prevFS: "ExFAT", isAPFSContainerVolume: false, content: "Apple_APFS")
        XCTAssertFalse(cAfterExFAT.canDelete, "previous = ExFAT cannot expand to absorb")
        XCTAssertEqual(cAfterExFAT.deleteReasonKey, "cap.prevNotResizable")
    }

    func testFirstPartitionNotDeletable() {
        let c = Capabilities.compute(
            fs: "APFS", scheme: "GUID_partition_scheme",
            prevFS: nil, isAPFSContainerVolume: false, content: "Apple_APFS")
        XCTAssertFalse(c.canDelete, "no previous sibling — nothing to merge into")
        XCTAssertEqual(c.deleteReasonKey, "cap.firstPartition")
    }
}
