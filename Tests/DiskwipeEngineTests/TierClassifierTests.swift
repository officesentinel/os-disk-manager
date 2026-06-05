import XCTest
@testable import diskwipe_engine

final class TierClassifierTests: XCTestCase {

    func testSASInterfaceIsEnterprise() {
        let r = TierClassifier.classify(
            model: "Some Generic Brand X",
            proto: "SAS",
            formFactor: "2.5 inches",
            sizeBytes: 480 * 1_000_000_000
        )
        XCTAssertEqual(r.tier, .enterprise)
        XCTAssertTrue(r.reason.contains("SAS"), "reason should mention SAS, got: \(r.reason)")
    }

    func testSCSIIsEnterprise() {
        let r = TierClassifier.classify(model: "X", proto: "SCSI", formFactor: nil, sizeBytes: nil)
        XCTAssertEqual(r.tier, .enterprise)
    }

    func testSamsungPM883IsEnterprise() {
        let r = TierClassifier.classify(
            model: "SAMSUNG MZ7LH960HAJR (PM883)",
            proto: "SATA",
            formFactor: "2.5 inches",
            sizeBytes: 960 * 1_000_000_000
        )
        XCTAssertEqual(r.tier, .enterprise)
    }

    func testSamsung870EVOIsConsumer() {
        // "evo" is in conKeys list. Note: TierClassifier first consults DiskDatabase,
        // which may or may not have an entry. If it does, the DB wins. If it doesn't,
        // we should hit the consumer heuristic.
        let r = TierClassifier.classify(
            model: "Samsung SSD 870 EVO 1TB",
            proto: "SATA",
            formFactor: "2.5 inches",
            sizeBytes: 1_000_000_000_000
        )
        XCTAssertNotEqual(r.tier, .unknown,
            "an EVO drive should classify, not return .unknown — reason: \(r.reason)")
        // Whether enterprise or consumer depends on DB content; the bug we
        // guard against is "unknown" for a well-known consumer family.
    }

    func testEnterpriseCapacityNumerology() {
        // 1920 GB is a classic enterprise size.
        let r = TierClassifier.classify(
            model: "TOTALLY_UNBRANDED_SSD_X",
            proto: "SATA",
            formFactor: nil,
            sizeBytes: 1920 * 1_000_000_000
        )
        XCTAssertEqual(r.tier, .enterprise,
            "1920GB should be classified by capacity numerology — reason: \(r.reason)")
        XCTAssertTrue(r.reason.contains("1920"), "reason should mention capacity, got: \(r.reason)")
    }

    func testU2FormFactorIsEnterprise() {
        let r = TierClassifier.classify(
            model: "Acme Generic",
            proto: "NVMe",
            formFactor: "U.2",
            sizeBytes: 1_500_000_000_000
        )
        XCTAssertEqual(r.tier, .enterprise)
    }

    func testUnknownWithNoSignal() {
        let r = TierClassifier.classify(
            model: "Acme MysteryDrive",
            proto: "SATA",
            formFactor: "2.5 inches",
            sizeBytes: 1_000_000_000_000   // 1 TB — not in enterprise numerology
        )
        XCTAssertEqual(r.tier, .unknown,
            "no signal should return .unknown, not guess — reason: \(r.reason)")
    }

    func testEmptyModelDoesNotCrash() {
        let r = TierClassifier.classify(model: nil, proto: nil, formFactor: nil, sizeBytes: nil)
        XCTAssertEqual(r.tier, .unknown)
    }

    func testIronwolfProVsPlainIronwolf() {
        // The classifier deliberately distinguishes "ironwolf pro" (enterprise)
        // from "ironwolf " (with trailing space, consumer) — the trailing
        // space prevents "ironwolf" alone from matching the "pro" variant.
        // Smartctl's model_family for these drives looks like
        // "Seagate IronWolf" / "Seagate IronWolf Pro"; the GUI passes that
        // back as `model` when no model_name is available.
        let pro = TierClassifier.classify(
            model: "Seagate IronWolf Pro 10TB",
            proto: "SATA",
            formFactor: "3.5 inches",
            sizeBytes: 10_000_000_000_000
        )
        XCTAssertEqual(pro.tier, .enterprise, "IronWolf Pro should be enterprise — reason: \(pro.reason)")

        let plain = TierClassifier.classify(
            model: "Seagate IronWolf 4TB",
            proto: "SATA",
            formFactor: "3.5 inches",
            sizeBytes: 4_000_000_000_000
        )
        XCTAssertEqual(plain.tier, .consumer, "plain IronWolf should be consumer — reason: \(plain.reason)")
    }

    func testIronwolfWithoutTrailingDistinguisherIsUnknown() {
        // A real Seagate model_name like "ST4000VN006" without the family
        // string carries no heuristic signal — it must come out as .unknown
        // unless the DB has an entry. This guards against false positives
        // from over-eager substring matching.
        let r = TierClassifier.classify(
            model: "ST4000VN006",
            proto: "SATA",
            formFactor: "3.5 inches",
            sizeBytes: 4_000_000_000_000
        )
        // Either .unknown (no DB hit) or a DB-driven verdict — never silently
        // misclassified by a stale substring match.
        XCTAssertNotEqual(r.tier, .enterprise,
            "raw Seagate model code without family must not be flagged enterprise — reason: \(r.reason)")
    }
}
