import XCTest
@testable import diskwipe_engine

final class SnapshotTests: XCTestCase {

    private func fmt(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> (stamp: String, date: Date) {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = 0; c.second = 0
        let cal = Calendar(identifier: .gregorian)
        let date = cal.date(from: c)!
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return (df.string(from: date), date)
    }

    func testStampInSameDayReturnsTrue() {
        let (stamp, now) = fmt(2026, 6, 5, 12)
        XCTAssertTrue(Snapshot.isSameLocalDay(stamp, now: now))
    }

    func testEarlierTimeSameDayReturnsTrue() {
        let (stamp, _) = fmt(2026, 6, 5, 1)
        let (_, now) = fmt(2026, 6, 5, 23)
        XCTAssertTrue(Snapshot.isSameLocalDay(stamp, now: now),
            "1 AM and 11 PM on the same day must collapse to one calendar day")
    }

    func testStampPriorDayReturnsFalse() {
        let (stamp, _) = fmt(2026, 6, 4, 23)
        let (_, now) = fmt(2026, 6, 5, 0)
        XCTAssertFalse(Snapshot.isSameLocalDay(stamp, now: now),
            "23:59 of day N-1 and 00:00 of day N must NOT collapse — bug repro")
    }

    func testStampNextDayReturnsFalse() {
        let (stamp, _) = fmt(2026, 6, 6, 0)
        let (_, now) = fmt(2026, 6, 5, 23)
        XCTAssertFalse(Snapshot.isSameLocalDay(stamp, now: now))
    }

    func testMonthBoundary() {
        let (stamp, _) = fmt(2026, 5, 31, 23)
        let (_, now) = fmt(2026, 6, 1, 1)
        XCTAssertFalse(Snapshot.isSameLocalDay(stamp, now: now))
    }

    func testEmptyStampReturnsFalse() {
        let (_, now) = fmt(2026, 6, 5)
        XCTAssertFalse(Snapshot.isSameLocalDay("", now: now),
            "an empty stamp must never match — guard against zombie throttle entries")
    }

    func testMalformedStampReturnsFalse() {
        let (_, now) = fmt(2026, 6, 5)
        XCTAssertFalse(Snapshot.isSameLocalDay("garbage", now: now))
        XCTAssertFalse(Snapshot.isSameLocalDay("2026", now: now))
        XCTAssertFalse(Snapshot.isSameLocalDay("2026-06", now: now))
    }
}
