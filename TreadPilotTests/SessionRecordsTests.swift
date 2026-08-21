// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import XCTest
@testable import TreadPilot

final class SessionRecordsTests: XCTestCase {

    // MARK: - Coverage arithmetic (WorkoutSessionRecord.watchHeartRateCoveragePercent)

    private func session(movingSeconds: Int, watchSeconds: Int?) -> WorkoutSessionRecord {
        let record = WorkoutSessionRecord(startedAt: Date(), deviceName: "Test", programName: nil)
        record.movingSeconds = movingSeconds
        record.watchHeartRateSeconds = watchSeconds
        return record
    }

    func testANewRecordCountsFromZeroRatherThanStartingUnmeasured() {
        // Anything this build records is measured from its first second, so a
        // fresh record must not look like a migrated one.
        let record = WorkoutSessionRecord(startedAt: Date(), deviceName: "Test", programName: nil)
        XCTAssertEqual(record.watchHeartRateSeconds, 0)
    }

    func testCoverageIsUnmeasuredForAWorkoutRecordedBeforeThisBuild() {
        // The migrated row: 30 minutes of running, and nothing was ever counted.
        // "Not measured" is a different answer from "nothing was missing", and
        // the number that decides phase 3's timings may not confuse them.
        let record = session(movingSeconds: 1800, watchSeconds: nil)
        XCTAssertNil(record.watchHeartRateCoveragePercent)
        // Even with heart rates on the record: a 1.0 workout has an average and
        // a maximum, and still measured no coverage.
        record.avgHeartRate = 142
        record.maxHeartRate = 171
        XCTAssertNil(record.watchHeartRateCoveragePercent)
    }

    func testCoverageIsZeroNotUnmeasuredForAHandlebarOnlyWorkout() {
        // The Watch app failed to launch and the user held the grips for the
        // whole run: the feed the governor would have consumed delivered
        // nothing, and 0% is that measurement — not a missing one.
        let record = session(movingSeconds: 1800, watchSeconds: 0)
        record.avgHeartRate = 148
        XCTAssertEqual(record.watchHeartRateCoveragePercent!, 0, accuracy: 0.0001)
    }

    func testCoverageAtOneHundredPercent() {
        let record = session(movingSeconds: 100, watchSeconds: 100)
        XCTAssertEqual(record.watchHeartRateCoveragePercent!, 100, accuracy: 0.0001)
    }

    func testCoverageCountsTheWatchGap() {
        // 200 moving seconds, the Watch feed delivered 150 → 75%.
        let record = session(movingSeconds: 200, watchSeconds: 150)
        XCTAssertEqual(record.watchHeartRateCoveragePercent!, 75, accuracy: 0.0001)
    }

    func testCoverageIsNilWhenNothingMovedAtAll() {
        // No moving seconds at all: nothing to divide, so nil rather than a
        // division by zero — regardless of the counted seconds.
        XCTAssertNil(session(movingSeconds: 0, watchSeconds: 0).watchHeartRateCoveragePercent)
        XCTAssertNil(session(movingSeconds: 0, watchSeconds: 5).watchHeartRateCoveragePercent)
    }

    func testCoverageClampsRatherThanExceedingOneHundredForARecordFromAnotherBuild() {
        // A record from a build with different bookkeeping could have counted
        // more seconds than it moved; the share must clamp at 100%.
        let record = session(movingSeconds: 10, watchSeconds: 15)
        XCTAssertEqual(record.watchHeartRateCoveragePercent!, 100, accuracy: 0.0001)
    }

    // MARK: - Coverage as it is printed (whole percent)

    func testOneHundredPercentIsReservedForAGaplessFeed() {
        // The reproduction: a 30-minute run whose Watch feed dropped seven
        // seconds. 99.61% rounds to 100, which is the string a gapless workout
        // prints — and gapless is the one question this cell answers.
        XCTAssertEqual(session(movingSeconds: 1800, watchSeconds: 1793)
            .watchHeartRateCoverageWholePercent, 99)
        XCTAssertEqual(session(movingSeconds: 1800, watchSeconds: 1800)
            .watchHeartRateCoverageWholePercent, 100)
        // Clamped-over counts are gapless too, so they may print 100.
        XCTAssertEqual(session(movingSeconds: 10, watchSeconds: 15)
            .watchHeartRateCoverageWholePercent, 100)
    }

    func testZeroPercentIsReservedForAFeedThatDeliveredNothing() {
        XCTAssertEqual(session(movingSeconds: 1800, watchSeconds: 0)
            .watchHeartRateCoverageWholePercent, 0)
        // A single covered second is not nothing: 0.06% floors at 1%.
        XCTAssertEqual(session(movingSeconds: 1800, watchSeconds: 1)
            .watchHeartRateCoverageWholePercent, 1)
    }

    func testWholePercentIsUnmeasuredForAWorkoutRecordedBeforeThisBuild() {
        XCTAssertNil(session(movingSeconds: 1800, watchSeconds: nil)
            .watchHeartRateCoverageWholePercent)
        XCTAssertNil(session(movingSeconds: 0, watchSeconds: 0)
            .watchHeartRateCoverageWholePercent)
    }

    func testWholePercentRoundsTheOrdinaryCasesNormally() {
        XCTAssertEqual(session(movingSeconds: 200, watchSeconds: 150)
            .watchHeartRateCoverageWholePercent, 75)
        XCTAssertEqual(session(movingSeconds: 3, watchSeconds: 2)
            .watchHeartRateCoverageWholePercent, 67)
    }
}
