// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import XCTest
@testable import TreadPilot

/// The target axis: `SegmentTarget`, the heart-rate payload it carries, the
/// recovery goal that finally has columns, and the storage round trip for all of
/// them. The unhappy paths matter more than the happy ones here: every degraded
/// read has to land on a fixed segment that a person could have programmed by
/// hand, because that is the segment the belt will actually run.
final class SegmentTargetTests: XCTestCase {

    private let limits = TreadmillLimits()

    /// A band-holding target with room to move on both axes.
    private func heartRateTarget(actuator: HeartRateActuator = .speed) -> HeartRateTarget {
        HeartRateTarget(lowBpm: 140, highBpm: 152, actuator: actuator,
                        startSpeedKmh: 8.0, startIncline: 1,
                        minSpeedKmh: 6.0, maxSpeedKmh: 11.0,
                        minIncline: 0, maxIncline: 4,
                        fallbackSpeedKmh: 5.0)
    }

    private func record(speedKmh: Double = 8.0, incline: Int = 1,
                        durationSeconds: Int = 600) -> CustomSegmentRecord {
        CustomSegmentRecord(orderIndex: 0, name: "Segment",
                           durationSeconds: durationSeconds,
                           targetSpeedKmh: speedKmh, targetIncline: incline)
    }

    // MARK: - SegmentTarget

    func testFixedTargetReportsItsOwnCommandAndNoHeartRatePayload() {
        let target = SegmentTarget.fixed(speedKmh: 7.5, incline: 3)
        XCTAssertEqual(target.kind, .fixed)
        XCTAssertEqual(target.startSpeedKmh, 7.5)
        XCTAssertEqual(target.startIncline, 3)
        XCTAssertNil(target.heartRate)
        XCTAssertEqual(target.withoutHeartRateControl, target)
    }

    func testHeartRateTargetReportsItsStartCommandAsTheNominalOne() {
        let target = SegmentTarget.heartRate(heartRateTarget())
        XCTAssertEqual(target.kind, .heartRate)
        XCTAssertEqual(target.startSpeedKmh, 8.0)
        XCTAssertEqual(target.startIncline, 1)
        XCTAssertEqual(target.heartRate, heartRateTarget())
    }

    /// The opt-in-off path: control switched off leaves a plain fixed segment at
    /// the start command, not a segment with no target at all.
    func testWithoutHeartRateControlBecomesAFixedSegmentAtTheStartCommand() {
        let target = SegmentTarget.heartRate(heartRateTarget()).withoutHeartRateControl
        XCTAssertEqual(target, .fixed(speedKmh: 8.0, incline: 1))
        XCTAssertNil(target.heartRate)
    }

    // MARK: - WorkoutSegment, both axes

    func testSegmentDerivesTheNominalPairAndTheLegacySpellingFromTheTarget() {
        let segment = WorkoutSegment(name: "Zone 3", goal: .time(seconds: 600),
                                     target: .heartRate(heartRateTarget()))
        XCTAssertEqual(segment.nominalSpeedKmh, 8.0)
        XCTAssertEqual(segment.nominalIncline, 1)
        // The pre-target-axis spelling every existing call site reads.
        XCTAssertEqual(segment.targetSpeedKmh, 8.0)
        XCTAssertEqual(segment.targetIncline, 1)
        XCTAssertTrue(segment.isHeartRateDriven)
        XCTAssertEqual(segment.heartRateTarget, heartRateTarget())
    }

    func testFixedSegmentBuiltWithTheOldInitializerIsAFixedTarget() {
        let segment = WorkoutSegment(name: "Walk", duration: 120,
                                     targetSpeedKmh: 3.0, targetIncline: 0)
        XCTAssertEqual(segment.target, .fixed(speedKmh: 3.0, incline: 0))
        XCTAssertFalse(segment.isHeartRateDriven)
        XCTAssertNil(segment.heartRateTarget)
    }

    /// The plan reads through the start command, so a heart-rate segment's totals
    /// are the totals of the speed it starts at — the only speed known in advance.
    func testHeartRateSegmentPlansFromItsStartSpeed() {
        let segment = WorkoutSegment(name: "Zone 3", goal: .time(seconds: 900),
                                     target: .heartRate(heartRateTarget()))
        XCTAssertEqual(segment.plannedDuration, 900)
        XCTAssertEqual(segment.plannedDistanceKm, 900.0 / 3600 * 8.0, accuracy: 0.0001)
        XCTAssertFalse(segment.isDurationEstimated)
        XCTAssertTrue(segment.isDistanceEstimated)
    }

    func testProgramReportsWhetherAnySegmentSteersTheBelt() {
        let steered = WorkoutProgram(name: "Steered", segments: [
            WorkoutSegment(name: "Warm-up", duration: 300, targetSpeedKmh: 5.0, targetIncline: 0),
            WorkoutSegment(name: "Zone 3", goal: .time(seconds: 600),
                           target: .heartRate(heartRateTarget())),
        ])
        XCTAssertTrue(steered.usesHeartRateControl)
        XCTAssertFalse(WorkoutProgram.builtIn.contains(where: \.usesHeartRateControl))
        for program in WorkoutProgram.builtIn {
            XCTAssertTrue(program.segments.allSatisfy { $0.target.kind == .fixed })
        }
    }

    func testWithoutHeartRateControlKeepsTheSegmentsIdentityAndGoal() {
        let segment = WorkoutSegment(name: "Zone 3", goal: .distance(km: 3.0),
                                     target: .heartRate(heartRateTarget()))
        let surrendered = segment.withoutHeartRateControl
        XCTAssertEqual(surrendered.id, segment.id)
        XCTAssertEqual(surrendered.goal, .distance(km: 3.0))
        XCTAssertEqual(surrendered.target, .fixed(speedKmh: 8.0, incline: 1))
        // The plan is unchanged: the start command was always the nominal one.
        XCTAssertEqual(surrendered.plannedDuration, segment.plannedDuration)
    }

    // MARK: - HeartRateTarget usability

    func testUsableTargetPassesAndEveryDegeneracyFails() {
        XCTAssertTrue(heartRateTarget().isUsable)

        var narrow = heartRateTarget()
        narrow.highBpm = narrow.lowBpm + HeartRateTarget.minBandWidthBpm - 1
        XCTAssertFalse(narrow.isUsable, "a band the loop cannot land inside")

        var implausible = heartRateTarget()
        implausible.lowBpm = 20
        implausible.highBpm = 40
        XCTAssertFalse(implausible.isUsable, "below any resting rate")

        var tooHigh = heartRateTarget()
        tooHigh.lowBpm = 230
        tooHigh.highBpm = 245
        XCTAssertFalse(tooHigh.isUsable, "above any plausible maximum")

        var pinnedSpeed = heartRateTarget()
        pinnedSpeed.minSpeedKmh = 8.0
        pinnedSpeed.maxSpeedKmh = 8.0
        XCTAssertFalse(pinnedSpeed.isUsable, "no room for a step on the actuated axis")

        var pinnedIncline = heartRateTarget(actuator: .incline)
        pinnedIncline.minIncline = 2
        pinnedIncline.maxIncline = 2
        XCTAssertFalse(pinnedIncline.isUsable)

        // The other axis being pinned is irrelevant: one segment, one actuator.
        var pinnedOtherAxis = heartRateTarget()
        pinnedOtherAxis.minIncline = 2
        pinnedOtherAxis.maxIncline = 2
        XCTAssertTrue(pinnedOtherAxis.isUsable)

        // All-zero columns are what an un-migrated or half-written record holds.
        let empty = HeartRateTarget(lowBpm: 0, highBpm: 0, startSpeedKmh: 8.0,
                                    startIncline: 0, minSpeedKmh: 0, maxSpeedKmh: 0,
                                    minIncline: 0, maxIncline: 0)
        XCTAssertFalse(empty.isUsable)
    }

    // MARK: - Seeding, and the editor's ranges

    /// Phase 1's major finding, on the new axis: a seeded value the editor cannot
    /// represent leaves the user unable to walk it back.
    func testSeededTargetIsUsableAndEntirelyInsideTheEditorsRanges() {
        for startSpeed in [0.8, 3.0, 8.0, 15.9, 16.0] {
            for startIncline in [0, 1, 11, 12] {
                let target = HeartRateTarget.seeded(startSpeedKmh: startSpeed,
                                                    startIncline: startIncline)
                XCTAssertTrue(target.isUsable, "\(startSpeed) @ \(startIncline)")
                XCTAssertTrue(HeartRateTarget.bandRangeBpm.contains(target.lowBpm))
                XCTAssertTrue(HeartRateTarget.bandRangeBpm.contains(target.highBpm))
                XCTAssertGreaterThanOrEqual(target.highBpm - target.lowBpm,
                                            HeartRateTarget.minBandWidthBpm)
                for speed in [target.startSpeedKmh, target.minSpeedKmh,
                              target.maxSpeedKmh, target.fallbackSpeedKmh] {
                    XCTAssertTrue(HeartRateTarget.speedRangeKmh.contains(speed), "\(speed)")
                    // On the protocol's 0.1 km/h grid, or the client's own
                    // rounding turns the command into evidence of a person.
                    XCTAssertEqual(speed, HeartRateTarget.quantizedSpeed(speed), accuracy: 1e-9)
                }
                for incline in [target.startIncline, target.minIncline, target.maxIncline] {
                    XCTAssertTrue(HeartRateTarget.inclineRange.contains(incline), "\(incline)")
                }
            }
        }
    }

    func testSeedingGivesACorridorAroundTheStartCommandRatherThanTheWholeMachine() {
        let target = HeartRateTarget.seeded(startSpeedKmh: 8.0, startIncline: 2)
        XCTAssertEqual(target.startSpeedKmh, 8.0)
        XCTAssertEqual(target.minSpeedKmh, 6.0)
        XCTAssertEqual(target.maxSpeedKmh, 10.0)
        XCTAssertEqual(target.minIncline, 0)
        XCTAssertEqual(target.maxIncline, 4)
        // The fallback is the corridor's floor: a declared value the editor can
        // show, rather than the 0 that only means "clamp me".
        XCTAssertEqual(target.fallbackSpeedKmh, target.minSpeedKmh)
        XCTAssertEqual(target.lowBpm, HeartRateTarget.defaultBandBpm.lowerBound)
        XCTAssertEqual(target.highBpm, HeartRateTarget.defaultBandBpm.upperBound)
    }

    func testSeedingTakesTheCallersBandWhenItIsGivenOne() {
        let target = HeartRateTarget.seeded(startSpeedKmh: 6.0, startIncline: 0,
                                            band: 132...144, actuator: .incline)
        XCTAssertEqual(target.lowBpm, 132)
        XCTAssertEqual(target.highBpm, 144)
        XCTAssertEqual(target.actuator, .incline)
        XCTAssertTrue(target.isUsable)
    }

    func testBandRepairWidensDownwardAndStaysInsideThePlausibleRange() {
        XCTAssertEqual(HeartRateTarget.repairedBand(130...145), 130...145)
        // Zero width: the upper edge is the one that costs effort, so it holds.
        XCTAssertEqual(HeartRateTarget.repairedBand(150...150),
                       (150 - HeartRateTarget.minBandWidthBpm)...150)
        // A reversed band cannot reach this function at all: `152...140` traps at
        // construction, which is why the parameter is a range rather than two
        // loose Ints. The repair for two stored columns is `HeartRateGovernor
        // .band(for:)`, covered by `testABandStoredBackwardsRendersInOrder`.
        // Below the plausible range: lifted to its floor, one minimum width wide.
        let floor = HeartRateTarget.bandRangeBpm.lowerBound
        XCTAssertEqual(HeartRateTarget.repairedBand(40...42),
                       floor...(floor + HeartRateTarget.minBandWidthBpm))
        // Above it: pulled down to the ceiling, the same width.
        let ceiling = HeartRateTarget.bandRangeBpm.upperBound
        XCTAssertEqual(HeartRateTarget.repairedBand(250...260),
                       (ceiling - HeartRateTarget.minBandWidthBpm)...ceiling)
    }

    func testRepairForEditingKeepsAUsableTargetUntouchedAndRescuesAHalfFilledOne() {
        XCTAssertEqual(heartRateTarget().repairedForEditing, heartRateTarget())

        // A band typed in but no bounds yet — the band survives, the bounds are
        // seeded around the start command.
        var halfFilled = heartRateTarget()
        halfFilled.minSpeedKmh = 0
        halfFilled.maxSpeedKmh = 0
        let repaired = halfFilled.repairedForEditing
        XCTAssertTrue(repaired.isUsable)
        XCTAssertEqual(repaired.lowBpm, 140)
        XCTAssertEqual(repaired.highBpm, 152)
        XCTAssertEqual(repaired.startSpeedKmh, 8.0)
    }

    // MARK: - The recovery goal

    func testRecoveryGoalSurvivesRepairWhenItCarriesBothAThresholdAndACap() {
        XCTAssertEqual(WorkoutSegment.repaired(.untilHeartRateBelow(bpm: 130, maxSeconds: 600)),
                       .untilHeartRateBelow(bpm: 130, maxSeconds: 600))
    }

    /// The cap is mandatory: a failed sensor must not be able to stall the
    /// program, so a recovery goal without one is not a recovery goal.
    func testRecoveryGoalWithoutATimeCapDegradesToATimeGoal() {
        XCTAssertEqual(WorkoutSegment.repaired(.untilHeartRateBelow(bpm: 130, maxSeconds: 0)),
                       .time(seconds: 0))
        XCTAssertEqual(WorkoutSegment.repaired(.untilHeartRateBelow(bpm: 130, maxSeconds: -60)),
                       .time(seconds: 0))
    }

    /// 0 bpm means "no reading" throughout this codebase, so a threshold of 0 can
    /// never be met — and neither can one above any plausible recovery rate.
    func testRecoveryGoalWithAnUnreachableThresholdDegradesToATimeGoalOfItsCap() {
        XCTAssertEqual(WorkoutSegment.repaired(.untilHeartRateBelow(bpm: 0, maxSeconds: 600)),
                       .time(seconds: 600))
        XCTAssertEqual(WorkoutSegment.repaired(.untilHeartRateBelow(bpm: 240, maxSeconds: 600)),
                       .time(seconds: 600))
    }

    func testRepairLeavesTheOtherTwoGoalsAlone() {
        XCTAssertEqual(WorkoutSegment.repaired(.time(seconds: 300)), .time(seconds: 300))
        XCTAssertEqual(WorkoutSegment.repaired(.distance(km: 5.0)), .distance(km: 5.0))
    }

    /// A recovery segment always walks: the segment waits for a heart rate to
    /// come down, and a standing belt never makes that happen.
    func testRecoverySegmentCannotBeBuiltWithAStandingBelt() {
        for stopped in [0.0, 0.4, -1.0] {
            let segment = WorkoutSegment(name: "Recover",
                                         goal: .untilHeartRateBelow(bpm: 130, maxSeconds: 600),
                                         targetSpeedKmh: stopped, targetIncline: 0)
            XCTAssertEqual(segment.nominalSpeedKmh, WorkoutSegment.recoveryMinSpeedKmh)
            XCTAssertGreaterThan(segment.nominalSpeedKmh, 0)
        }
    }

    func testRecoverySegmentKeepsASpeedAlreadyAboveTheWalkingFloor() {
        let segment = WorkoutSegment(name: "Recover",
                                     goal: .untilHeartRateBelow(bpm: 130, maxSeconds: 600),
                                     targetSpeedKmh: 4.0, targetIncline: 1)
        XCTAssertEqual(segment.nominalSpeedKmh, 4.0)
        XCTAssertEqual(segment.nominalIncline, 1)
        XCTAssertEqual(segment.plannedDuration, 600)
        XCTAssertTrue(segment.isDurationEstimated, "the cap is an upper bound, not the plan")
    }

    /// The walking floor also lifts a heart-rate target's lower bound, so the
    /// loop cannot walk a recovery segment down to a stop either.
    func testRecoveryFloorAppliesToAHeartRateTargetToo() {
        var target = heartRateTarget()
        target.startSpeedKmh = 0
        target.minSpeedKmh = 0
        let segment = WorkoutSegment(name: "Recover",
                                     goal: .untilHeartRateBelow(bpm: 130, maxSeconds: 600),
                                     target: .heartRate(target))
        XCTAssertEqual(segment.heartRateTarget?.startSpeedKmh, WorkoutSegment.recoveryMinSpeedKmh)
        XCTAssertEqual(segment.heartRateTarget?.minSpeedKmh, WorkoutSegment.recoveryMinSpeedKmh)
    }

    // MARK: - Storage round trip: the target axis

    func testFixedTargetRoundTripsThroughStorage() {
        let record = self.record(speedKmh: 6.5, incline: 2)
        record.target = .fixed(speedKmh: 6.5, incline: 2)
        XCTAssertEqual(record.targetKindRaw, SegmentTarget.Kind.fixed.rawValue)
        XCTAssertEqual(record.target, .fixed(speedKmh: 6.5, incline: 2))
        XCTAssertEqual(record.asWorkoutSegment.target, .fixed(speedKmh: 6.5, incline: 2))
    }

    func testHeartRateTargetRoundTripsThroughStorage() {
        let record = self.record()
        record.target = .heartRate(heartRateTarget())

        XCTAssertEqual(record.targetKindRaw, SegmentTarget.Kind.heartRate.rawValue)
        // The start command lives in the columns a fixed target uses.
        XCTAssertEqual(record.targetSpeedKmh, 8.0)
        XCTAssertEqual(record.targetIncline, 1)
        XCTAssertEqual(record.hrLowBpm, 140)
        XCTAssertEqual(record.hrHighBpm, 152)
        XCTAssertEqual(record.hrActuator, .speed)
        XCTAssertEqual(record.hrFallbackSpeedKmh, 5.0)

        XCTAssertEqual(record.target, .heartRate(heartRateTarget()))
        XCTAssertEqual(record.asWorkoutSegment.heartRateTarget, heartRateTarget())
    }

    func testInclineActuatedTargetRoundTripsThroughStorage() {
        let record = self.record()
        record.target = .heartRate(heartRateTarget(actuator: .incline))
        XCTAssertEqual(record.hrActuatorRaw, HeartRateActuator.incline.rawValue)
        XCTAssertEqual(record.target, .heartRate(heartRateTarget(actuator: .incline)))
    }

    /// A record written by a newer build has to stay openable.
    func testUnknownTargetKindRawDecodesToFixed() {
        let record = self.record(speedKmh: 7.0, incline: 3)
        record.targetKindRaw = "futureKind"
        XCTAssertEqual(record.target, .fixed(speedKmh: 7.0, incline: 3))
        XCTAssertEqual(record.asWorkoutSegment.nominalSpeedKmh, 7.0)
    }

    /// The honest degradation, and the one the opt-in-off case needs anyway: a
    /// heart-rate kind whose payload is missing reads as a fixed segment at the
    /// start speed rather than as a loop with nowhere to steer.
    func testHeartRateKindWithAnEmptyPayloadDecodesToFixedAtTheStartSpeed() {
        let record = self.record(speedKmh: 9.0, incline: 2)
        record.targetKindRaw = SegmentTarget.Kind.heartRate.rawValue
        XCTAssertEqual(record.target, .fixed(speedKmh: 9.0, incline: 2))
        XCTAssertNil(record.asWorkoutSegment.heartRateTarget)
        XCTAssertFalse(record.asWorkoutSegment.isHeartRateDriven)
    }

    /// The degraded read is a fixed segment at the heart-rate target's own start
    /// command — the value the columns hold, which is also what the segment would
    /// have run with control switched off.
    func testHeartRateKindWithADegenerateBandDecodesToFixed() {
        let record = self.record(speedKmh: 9.0, incline: 0)
        record.target = .heartRate(heartRateTarget())
        // A band this narrow leaves the loop no output that lands inside it.
        record.hrHighBpm = record.hrLowBpm + 1
        XCTAssertEqual(record.target, .fixed(speedKmh: 8.0, incline: 1))
    }

    func testHeartRateKindWithPinnedBoundsDecodesToFixed() {
        let record = self.record(speedKmh: 9.0, incline: 0)
        record.target = .heartRate(heartRateTarget())
        record.hrMinSpeedKmh = 8.0
        record.hrMaxSpeedKmh = 8.0
        XCTAssertEqual(record.target, .fixed(speedKmh: 8.0, incline: 1))
    }

    func testUnknownStoredActuatorReadsAsSpeed() {
        let record = self.record()
        record.hrActuatorRaw = "cadence"
        XCTAssertEqual(record.hrActuator, .speed)
    }

    // MARK: - Storage round trip: the recovery goal

    func testRecoveryGoalRoundTripsThroughStorage() {
        let record = self.record(speedKmh: 4.0, incline: 0, durationSeconds: 0)
        record.goal = .untilHeartRateBelow(bpm: 130, maxSeconds: 600)

        XCTAssertEqual(record.goalKindRaw, SegmentGoal.Kind.untilHeartRateBelow.rawValue)
        XCTAssertEqual(record.goalHeartRateBelow, 130)
        XCTAssertEqual(record.goalMaxSeconds, 600)
        // durationSeconds stays the planned-duration mirror the lists sort on.
        XCTAssertEqual(record.durationSeconds, 600)
        XCTAssertEqual(record.goal, .untilHeartRateBelow(bpm: 130, maxSeconds: 600))
        XCTAssertEqual(record.asWorkoutSegment.goal,
                       .untilHeartRateBelow(bpm: 130, maxSeconds: 600))
        XCTAssertEqual(record.asWorkoutSegment.plannedDuration, 600)
    }

    func testStoringARecoveryGoalLiftsAStandingBeltToTheWalkingFloor() {
        let record = self.record(speedKmh: 0, incline: 0, durationSeconds: 0)
        record.goal = .untilHeartRateBelow(bpm: 130, maxSeconds: 600)
        XCTAssertEqual(record.targetSpeedKmh, WorkoutSegment.recoveryMinSpeedKmh)
        XCTAssertGreaterThan(record.asWorkoutSegment.nominalSpeedKmh, 0)
    }

    func testStoredRecoveryGoalWithoutAThresholdOrACapReadsAsTime() {
        let noThreshold = self.record(durationSeconds: 240)
        noThreshold.goalKindRaw = SegmentGoal.Kind.untilHeartRateBelow.rawValue
        noThreshold.goalMaxSeconds = 600
        XCTAssertEqual(noThreshold.goal, .time(seconds: 240))

        let noCap = self.record(durationSeconds: 240)
        noCap.goalKindRaw = SegmentGoal.Kind.untilHeartRateBelow.rawValue
        noCap.goalHeartRateBelow = 130
        XCTAssertEqual(noCap.goal, .time(seconds: 240))
    }

    func testStoredRecoveryGoalWithAnImplausibleThresholdReadsAsTimeOfItsCap() {
        let record = self.record(durationSeconds: 240)
        record.goalKindRaw = SegmentGoal.Kind.untilHeartRateBelow.rawValue
        record.goalHeartRateBelow = 40
        record.goalMaxSeconds = 600
        XCTAssertEqual(record.goal, .time(seconds: 600))
    }

    /// A recovery goal set through the record cannot come back out without its
    /// cap, whatever it was asked for.
    func testStoringARecoveryGoalWithoutACapDoesNotStoreARecoveryGoal() {
        let record = self.record(durationSeconds: 240)
        record.goal = .untilHeartRateBelow(bpm: 130, maxSeconds: 0)
        XCTAssertEqual(record.goalKindRaw, SegmentGoal.Kind.time.rawValue)
        XCTAssertEqual(record.goal, .time(seconds: 0))
    }

    // MARK: - The editor's two kind pickers

    func testSwitchingTheGoalKindToRecoverySeedsValuesTheEditorCanRepresent() {
        let record = self.record(speedKmh: 0, incline: 0, durationSeconds: 1234)
        record.goalKind = .untilHeartRateBelow

        guard case .untilHeartRateBelow(let bpm, let maxSeconds) = record.goal else {
            return XCTFail("expected a recovery goal, got \(record.goal)")
        }
        XCTAssertTrue(WorkoutSegment.goalHeartRateBelowRangeBpm.contains(bpm))
        XCTAssertTrue(WorkoutSegment.goalDurationRangeSeconds.contains(maxSeconds))
        // On the duration stepper's own grid, so it can be walked back.
        XCTAssertEqual(maxSeconds % WorkoutSegment.goalDurationStepSeconds, 0)
        // And the walking-target rule came with it.
        XCTAssertEqual(record.targetSpeedKmh, WorkoutSegment.recoveryMinSpeedKmh)
    }

    func testSwitchingTheGoalKindKeepsAThresholdTheUserAlreadySet() {
        let record = self.record()
        record.goal = .untilHeartRateBelow(bpm: 140, maxSeconds: 600)
        record.goalKind = .time
        record.goalKind = .untilHeartRateBelow
        XCTAssertEqual(record.goal, .untilHeartRateBelow(bpm: 140, maxSeconds: 600))
    }

    func testSwitchingTheTargetKindToHeartRateSeedsAUsableTarget() {
        let record = self.record(speedKmh: 8.0, incline: 1)
        record.targetKind = .heartRate

        guard let target = record.target.heartRate else {
            return XCTFail("expected a heart-rate target, got \(record.target)")
        }
        XCTAssertTrue(target.isUsable)
        XCTAssertEqual(target.startSpeedKmh, 8.0)
        XCTAssertEqual(target.startIncline, 1)
        XCTAssertEqual(record.asWorkoutSegment.heartRateTarget, target)
    }

    /// Switching to Fixed and back must not cost the user the band they typed —
    /// the discriminator decides which columns are read, so nothing is cleared.
    func testTheBandSurvivesATripThroughTheFixedTab() {
        let record = self.record()
        record.target = .heartRate(heartRateTarget())
        record.targetKind = .fixed
        XCTAssertEqual(record.target, .fixed(speedKmh: 8.0, incline: 1))
        record.targetKind = .heartRate
        XCTAssertEqual(record.target, .heartRate(heartRateTarget()))
    }

    func testRefreshPlannedDurationMirrorsARecoveryGoalsCap() {
        let record = self.record(durationSeconds: 0)
        record.goal = .untilHeartRateBelow(bpm: 130, maxSeconds: 600)
        record.goalMaxSeconds = 900
        record.refreshPlannedDuration()
        XCTAssertEqual(record.durationSeconds, 900)
    }

    // MARK: - Duplication carries both axes

    func testCopyingCarriesTheHeartRateTargetAndTheRecoveryGoal() {
        let source = WorkoutSegment(name: "Zone 3",
                                    goal: .untilHeartRateBelow(bpm: 130, maxSeconds: 600),
                                    target: .heartRate(heartRateTarget()))
        let record = CustomSegmentRecord.copying(source, orderIndex: 3, name: "Zone 3 (copy)")

        XCTAssertEqual(record.orderIndex, 3)
        XCTAssertEqual(record.name, "Zone 3 (copy)")
        XCTAssertEqual(record.goal, .untilHeartRateBelow(bpm: 130, maxSeconds: 600))
        XCTAssertEqual(record.target, .heartRate(heartRateTarget()))
        XCTAssertEqual(record.durationSeconds, 600)
    }

    func testCopyOfAProgramCarriesBothAxesOfEverySegment() {
        let source = WorkoutProgram(name: "Source", segments: [
            WorkoutSegment(name: "Warm-up", duration: 300, targetSpeedKmh: 5.0, targetIncline: 0),
            WorkoutSegment(name: "Zone 3", goal: .time(seconds: 600),
                           target: .heartRate(heartRateTarget())),
            WorkoutSegment(name: "Recover",
                           goal: .untilHeartRateBelow(bpm: 130, maxSeconds: 300),
                           targetSpeedKmh: 4.0, targetIncline: 0),
        ])
        let copy = CustomProgram.copy(of: source, name: "Copy")
        let records = copy.sortedSegments

        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records[0].target, .fixed(speedKmh: 5.0, incline: 0))
        XCTAssertEqual(records[1].target, .heartRate(heartRateTarget()))
        XCTAssertEqual(records[2].goal, .untilHeartRateBelow(bpm: 130, maxSeconds: 300))
        XCTAssertEqual(records[2].targetSpeedKmh, 4.0)
        XCTAssertEqual(copy.asWorkoutProgram.segments[1].heartRateTarget, heartRateTarget())
        XCTAssertTrue(copy.asWorkoutProgram.usesHeartRateControl)
        XCTAssertTrue(copy.hasEstimatedDuration)
    }

    // MARK: - What the governor actually receives

    /// The end of the chain this packet builds: a stored record produces a target
    /// the governor can steer with, and its bounds are the ones that were stored.
    func testAStoredTargetDrivesTheGovernorWithinItsOwnBounds() {
        let record = self.record()
        record.target = .heartRate(heartRateTarget())
        guard let target = record.asWorkoutSegment.heartRateTarget else {
            return XCTFail("expected a heart-rate target")
        }

        let bounds = HeartRateGovernor.speedBounds(for: target, limits: limits)
        XCTAssertEqual(bounds.lowerBound, 6.0)
        XCTAssertEqual(bounds.upperBound, 11.0)
        XCTAssertEqual(HeartRateGovernor.band(for: target), 140...152)

        // Below the band, everything settled: the one increasing path in the
        // governor, and it must stay inside the bounds the record stored.
        let command = HeartRateGovernor.Command(speedKmh: 8.0, incline: 1)
        let decision = HeartRateGovernor.decide(.init(
            target: target,
            basis: HeartRateBasis(restingBpm: 60, maxBpm: 190),
            limits: limits,
            heartRate: 130,
            command: command,
            lastAppliedChange: .settled(at: command),
            secondsSinceSegmentStart: 300,
            secondsSinceLastCommand: 300,
            secondsSinceLoadChange: 300,
            tallies: HeartRateGovernor.Tallies()))

        guard case .adjust(let next, .belowBand) = decision else {
            return XCTFail("expected a step toward the band, got \(decision)")
        }
        XCTAssertTrue(bounds.contains(next.speedKmh))
        XCTAssertGreaterThan(next.speedKmh, command.speedKmh)
        XCTAssertEqual(next.incline, command.incline, "the non-actuated axis is passed through")
    }

    // MARK: - Rendering

    func testHeartRateTargetRendersItsBandAndTheCommandItStartsFrom() {
        let rendered = SegmentFormat.target(.heartRate(heartRateTarget()))
        XCTAssertTrue(rendered.contains("140"), rendered)
        XCTAssertTrue(rendered.contains("152"), rendered)
        XCTAssertTrue(rendered.hasSuffix(SegmentFormat.target(speedKmh: 8.0, incline: 1)),
                      rendered)
    }

    func testFixedTargetRendersExactlyAsItAlwaysDid() {
        XCTAssertEqual(SegmentFormat.target(.fixed(speedKmh: 8.0, incline: 0)),
                       SegmentFormat.target(speedKmh: 8.0, incline: 0))
    }

    /// A stored pair in the wrong order must read as a band, not as a negative one.
    func testABandStoredBackwardsRendersInOrder() {
        var reversed = heartRateTarget()
        reversed.lowBpm = 152
        reversed.highBpm = 140
        let rendered = SegmentFormat.heartRateBand(reversed)
        XCTAssertTrue(rendered.hasPrefix("140"), rendered)
    }

    // MARK: - Finding 118: the band editor cannot trap

    /// The exact crash: a fresh segment seeds the default 130–145 band, and a
    /// profile whose maximum heart rate is 147 or lower pulls the force-down
    /// ceiling — and so `holdableBandRangeBpm`'s own top — below 135, which used
    /// to leave the "Band high" Stepper's `in:` range inverted (135...134) and
    /// trap on construction. Swept across every maximum from a beta-blocker
    /// case up to a very high one, on both the seeded band and a band that had
    /// already been narrowed by a previous repair, because a Stepper is
    /// constructed from whatever is currently stored, not only from a fresh
    /// seed.
    func testBandEditingRangesNeverInvertAtAnyMaximumHeartRate() {
        for maxBpm in stride(from: 60, through: 220, by: 1) {
            let holdable = HeartRateGovernor.holdableBandRangeBpm(
                for: HeartRateBasis(restingBpm: 60, maxBpm: maxBpm))
            XCTAssertLessThanOrEqual(holdable.lowerBound, holdable.upperBound,
                                     "holdableBandRangeBpm itself inverted at max \(maxBpm)")

            for (lowBpm, highBpm) in [(HeartRateTarget.defaultBandBpm.lowerBound,
                                       HeartRateTarget.defaultBandBpm.upperBound),
                                      (holdable.lowerBound, holdable.upperBound),
                                      (0, 0), (200, 210)] {
                let lowRange = HeartRateTarget.lowBpmEditingRange(highBpm: highBpm,
                                                                  holdableRange: holdable)
                XCTAssertLessThanOrEqual(lowRange.lowerBound, lowRange.upperBound,
                                         "low range inverted: max \(maxBpm), stored \(lowBpm)...\(highBpm)")
                let highRange = HeartRateTarget.highBpmEditingRange(lowBpm: lowBpm,
                                                                    holdableRange: holdable)
                XCTAssertLessThanOrEqual(highRange.lowerBound, highRange.upperBound,
                                         "high range inverted: max \(maxBpm), stored \(lowBpm)...\(highBpm)")
            }
        }
    }

    /// The acceptance criterion's own value, spelled out: a 120 bpm maximum
    /// (well inside the beta-blocker case phase 2 introduced) must neither
    /// trap nor leave the editor with nothing to show.
    func testABandEditorOpenedAgainstAMaximumHeartRateOf120DoesNotTrap() {
        let holdable = HeartRateGovernor.holdableBandRangeBpm(
            for: HeartRateBasis(restingBpm: 60, maxBpm: 120))
        let lowRange = HeartRateTarget.lowBpmEditingRange(
            highBpm: HeartRateTarget.defaultBandBpm.upperBound, holdableRange: holdable)
        let highRange = HeartRateTarget.highBpmEditingRange(
            lowBpm: HeartRateTarget.defaultBandBpm.lowerBound, holdableRange: holdable)
        XCTAssertLessThanOrEqual(lowRange.lowerBound, lowRange.upperBound)
        XCTAssertLessThanOrEqual(highRange.lowerBound, highRange.upperBound)
    }

    /// `repairedBand(_:within:)` — the seeding/repair half of finding 118 — pulls
    /// a band that was fine at 130–145 into a narrow holdable range without
    /// inverting it, and the result is still `minBandWidthBpm` wide.
    func testRepairedBandWithinANarrowHoldableRangeStaysOrderedAndWideEnough() {
        let holdable = HeartRateGovernor.holdableBandRangeBpm(
            for: HeartRateBasis(restingBpm: 60, maxBpm: 120))
        let repaired = HeartRateTarget.repairedBand(HeartRateTarget.defaultBandBpm, within: holdable)
        XCTAssertLessThanOrEqual(repaired.lowerBound, repaired.upperBound)
        XCTAssertGreaterThanOrEqual(repaired.upperBound - repaired.lowerBound,
                                    HeartRateTarget.minBandWidthBpm)
        XCTAssertTrue(holdable.contains(repaired.lowerBound))
        XCTAssertTrue(holdable.contains(repaired.upperBound))
    }

    // MARK: - Finding 119: one source of truth for the start command's bounds

    /// `isUsable(within:)` sees a device wider than the default accept a start
    /// command the default-only property would reject — the "wider machine"
    /// half of finding 119.
    func testIsUsableWithinAWiderDeviceAcceptsAStartCommandTheDefaultRejects() {
        var target = heartRateTarget()
        target.startSpeedKmh = 18.0
        target.minSpeedKmh = 17.0
        target.maxSpeedKmh = 19.0
        XCTAssertFalse(target.isUsable, "18 km/h is above the default's own 16.0 km/h ceiling")

        let wideDevice = TreadmillLimits(minSpeedRaw: 5, maxSpeedRaw: 220,
                                         minIncline: 0, maxIncline: 15, fromDevice: true)
        XCTAssertTrue(target.isUsable(within: wideDevice))
    }

    /// The other half: a device narrower than the default rejects a corridor
    /// the default-only property would have waved through.
    func testIsUsableWithinANarrowerDeviceRejectsACorridorTheDefaultAccepts() {
        let target = heartRateTarget() // minSpeedKmh 6.0, maxSpeedKmh 11.0
        XCTAssertTrue(target.isUsable)

        let narrowDevice = TreadmillLimits(minSpeedRaw: 8, maxSpeedRaw: 90,
                                           minIncline: 0, maxIncline: 12, fromDevice: true)
        XCTAssertFalse(target.isUsable(within: narrowDevice),
                       "11.0 km/h is above this device's own 9.0 km/h ceiling")
    }

    /// `TreadmillLimits.narrower` never returns an inverted range, even when the
    /// two inputs do not overlap at all — the malformed-device-reading case the
    /// editor's own bounds must survive without trapping downstream.
    func testNarrowerLimitsIsTheIntersectionAndNeverInverts() {
        let a = TreadmillLimits(minSpeedRaw: 10, maxSpeedRaw: 100, minIncline: 0, maxIncline: 10)
        let b = TreadmillLimits(minSpeedRaw: 20, maxSpeedRaw: 150, minIncline: 2, maxIncline: 8)
        let intersected = TreadmillLimits.narrower(a, b)
        XCTAssertEqual(intersected.minSpeedRaw, 20)
        XCTAssertEqual(intersected.maxSpeedRaw, 100)
        XCTAssertEqual(intersected.minIncline, 2)
        XCTAssertEqual(intersected.maxIncline, 8)

        // Non-overlapping speed ranges collapse to a point at the floor rather
        // than invert.
        let disjoint = TreadmillLimits(minSpeedRaw: 200, maxSpeedRaw: 300)
        let collapsed = TreadmillLimits.narrower(a, disjoint)
        XCTAssertLessThanOrEqual(collapsed.minSpeedRaw, collapsed.maxSpeedRaw)
        XCTAssertEqual(collapsed.minSpeedRaw, collapsed.maxSpeedRaw)
    }

    /// The speed and incline corridor editing ranges are as inversion-proof as
    /// the bpm band's — swept the same way, since this packet is what makes
    /// them device-dependent in the first place.
    func testSpeedAndInclineCorridorEditingRangesNeverInvert() {
        let devices = [TreadmillLimits(), // the plausible default, unconnected
                       TreadmillLimits(minSpeedRaw: 8, maxSpeedRaw: 90,
                                       minIncline: 0, maxIncline: 12, fromDevice: true),
                       TreadmillLimits(minSpeedRaw: 5, maxSpeedRaw: 220,
                                       minIncline: 0, maxIncline: 3, fromDevice: true)]
        for limits in devices {
            for edge in [limits.minSpeedKmh, limits.maxSpeedKmh, 0, 999] {
                let minRange = HeartRateTarget.minSpeedEditingRange(maxSpeedKmh: edge, limits: limits)
                XCTAssertLessThanOrEqual(minRange.lowerBound, minRange.upperBound)
                let maxRange = HeartRateTarget.maxSpeedEditingRange(minSpeedKmh: edge, limits: limits)
                XCTAssertLessThanOrEqual(maxRange.lowerBound, maxRange.upperBound)
            }
            for edge in [limits.minIncline, limits.maxIncline, 0, 999] {
                let minRange = HeartRateTarget.minInclineEditingRange(maxIncline: edge, limits: limits)
                XCTAssertLessThanOrEqual(minRange.lowerBound, minRange.upperBound)
                let maxRange = HeartRateTarget.maxInclineEditingRange(minIncline: edge, limits: limits)
                XCTAssertLessThanOrEqual(maxRange.lowerBound, maxRange.upperBound)
            }
        }
    }
}
