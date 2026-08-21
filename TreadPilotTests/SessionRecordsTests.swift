// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import SwiftData
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

    // MARK: - Finding 115: the sample's own target band

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: WorkoutSessionRecord.self, WorkoutSampleRecord.self,
            configurations: configuration)
        return ModelContext(container)
    }

    func testASamplesTargetBandSurvivesASaveAndAFetch() throws {
        let context = try makeContext()
        let session = WorkoutSessionRecord(startedAt: Date(), deviceName: "Test", programName: nil)
        context.insert(session)
        let sample = WorkoutSampleRecord(offsetSeconds: 1, speedKmh: 8.0, inclinePercent: 0,
                                         heartRate: 150, distanceKm: 0.002,
                                         targetHrLow: 144, targetHrHigh: 155)
        sample.session = session
        context.insert(sample)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<WorkoutSampleRecord>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.targetHrLow, 144)
        XCTAssertEqual(fetched.first?.targetHrHigh, 155)
        XCTAssertTrue(fetched.first?.hasTargetHeartRateBand ?? false)
    }

    func testASampleDefaultsToNoBandForTheLightweightMigration() {
        // The precedent this table follows is `WorkoutSampleRecord.timestamp`:
        // omitting the new arguments is what a pre-1.1 row decodes as, and it
        // must read as "nothing was governing", not a band that happens to
        // start at 0 bpm.
        let sample = WorkoutSampleRecord(offsetSeconds: 1, speedKmh: 8.0, inclinePercent: 0,
                                         heartRate: 150, distanceKm: 0.002)
        XCTAssertEqual(sample.targetHrLow, 0)
        XCTAssertEqual(sample.targetHrHigh, 0)
        XCTAssertFalse(sample.hasTargetHeartRateBand)
    }

    // MARK: - Finding 138: the durable stop reason

    func testANewSessionDefaultsToNoStopReasonAndNoFailure() {
        // Both the lightweight-migration default for a pre-1.1 row and the
        // starting point for a fresh recording — an ordinary end looks the same
        // either way.
        let record = WorkoutSessionRecord(startedAt: Date(), deviceName: "Test", programName: nil)
        XCTAssertEqual(record.stopReason, .none)
        XCTAssertFalse(record.beltDidNotStop)
    }

    func testTheStopReasonRoundTripsThroughItsStoredRawValue() {
        let record = WorkoutSessionRecord(startedAt: Date(), deviceName: "Test", programName: nil)
        record.stopReason = .heartRateCeiling
        XCTAssertEqual(record.stopReasonRaw, WorkoutStopReason.heartRateCeiling.rawValue)
        XCTAssertEqual(record.stopReason, .heartRateCeiling)
    }

    func testAnUnrecognizedStoredReasonReadsAsNoneRatherThanTrapping() {
        // A row written by a future build with a reason this one does not know —
        // the same tolerance `CustomSegmentRecord.goal` gives an unknown
        // discriminator.
        let record = WorkoutSessionRecord(startedAt: Date(), deviceName: "Test", programName: nil)
        record.stopReasonRaw = "someFutureReason"
        XCTAssertEqual(record.stopReason, .none)
    }

    func testAStopReasonAndAFailureToStopSurviveASaveAndAFetch() throws {
        let context = try makeContext()
        let session = WorkoutSessionRecord(startedAt: Date(), deviceName: "Test", programName: nil)
        session.stopReason = .heartRateCeiling
        session.beltDidNotStop = true
        context.insert(session)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<WorkoutSessionRecord>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.stopReason, .heartRateCeiling)
        XCTAssertEqual(fetched.first?.beltDidNotStop, true)
    }

    func testAnUngovernedSampleAlongsideAGovernedOneDrawsNothingForItself() {
        // A mixed program's fixed segment, recorded next to a governed one:
        // each second answers for itself.
        let governed = WorkoutSampleRecord(offsetSeconds: 1, speedKmh: 8.0, inclinePercent: 0,
                                           heartRate: 150, distanceKm: 0.002,
                                           targetHrLow: 130, targetHrHigh: 148)
        let ungoverned = WorkoutSampleRecord(offsetSeconds: 2, speedKmh: 8.0, inclinePercent: 0,
                                             heartRate: 151, distanceKm: 0.004)
        XCTAssertTrue(governed.hasTargetHeartRateBand)
        XCTAssertFalse(ungoverned.hasTargetHeartRateBand)
    }
}
