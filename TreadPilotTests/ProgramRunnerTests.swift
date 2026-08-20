// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import XCTest
@testable import TreadPilot

final class ProgramRunnerTests: XCTestCase {

    private let program = WorkoutProgram(name: "Teszt", segments: [
        WorkoutSegment(name: "Warm-up", duration: 180, targetSpeedKmh: 5.0, targetIncline: 0),
        WorkoutSegment(name: "Gyors", duration: 60, targetSpeedKmh: 9.0, targetIncline: 2),
        WorkoutSegment(name: "Cool-down", duration: 120, targetSpeedKmh: 4.0, targetIncline: 0),
    ])

    func testProgramRemainingSumsCurrentAndFutureSegments() {
        // 100 s remain from the first segment, plus 60 + 120 for the other two.
        XCTAssertEqual(ProgramRunner.programRemainingSeconds(in: program, segmentIndex: 0,
                                                             segmentRemaining: 100), 280)
        // In the last segment only the remainder counts.
        XCTAssertEqual(ProgramRunner.programRemainingSeconds(in: program, segmentIndex: 2,
                                                             segmentRemaining: 45), 45)
    }

    func testNextSegmentLookup() {
        XCTAssertEqual(ProgramRunner.nextSegment(in: program, after: 0)?.name, "Gyors")
        XCTAssertEqual(ProgramRunner.nextSegment(in: program, after: 1)?.name, "Cool-down")
        XCTAssertNil(ProgramRunner.nextSegment(in: program, after: 2))
    }

    func testProgramSummaryComputations() {
        // 600 mp @ 6 km/h @ 5% + 300 mp @ 12 km/h @ 0%:
        // distance: 1.0 + 1.0 = 2.0 km; elevation: 600 × 1.6667 × 0.05 = 50 m;
        // average: 2.0 km / 0.25 h = 8.0 km/h.
        let program = WorkoutProgram(name: "Totals", segments: [
            WorkoutSegment(name: "A", duration: 600, targetSpeedKmh: 6.0, targetIncline: 5),
            WorkoutSegment(name: "B", duration: 300, targetSpeedKmh: 12.0, targetIncline: 0),
        ])
        XCTAssertEqual(program.totalDistanceKm, 2.0, accuracy: 0.001)
        XCTAssertEqual(program.totalElevationGainM, 50.0, accuracy: 0.1)
        XCTAssertEqual(program.averageSpeedKmh, 8.0, accuracy: 0.001)
        XCTAssertEqual(program.totalDuration, 900)
    }

    // MARK: - Per-tick accumulation

    private func tickInput(delta: Double = 1.0, speedKmh: Double = 12.0,
                           running: Bool = true, stale: Bool = false) -> ProgramRunner.TickInput {
        ProgramRunner.TickInput(deltaSeconds: delta, speedKmh: speedKmh,
                                isBeltRunning: running, isDataStale: stale)
    }

    func testAccumulationIntegratesTheMeasuredDeltaNotOneSecondPerTick() {
        var progress = ProgramRunner.SegmentProgress()
        // Six 1.25 s gaps at 12 km/h: 7.5 s of running, 25 m.
        for _ in 0..<6 {
            progress = ProgramRunner.accumulating(progress, tick: tickInput(delta: 1.25))
        }
        XCTAssertEqual(progress.elapsedSeconds, 7.5, accuracy: 0.0001)
        XCTAssertEqual(progress.distanceKm, 12.0 * 7.5 / 3600, accuracy: 0.000001)
    }

    func testLostTimerFiresDoNotLoseTheRunningTheyCovered() {
        // 25 minutes at 12 km/h with 5% of the 1 Hz fires lost: 1500 s of real
        // time delivered in 1425 ticks. That is 5.0 km, not the 4.75 km a tick
        // count would have booked — 250 m of real running.
        var progress = ProgramRunner.SegmentProgress()
        for _ in 0..<1425 {
            progress = ProgramRunner.accumulating(progress, tick: tickInput(delta: 1500.0 / 1425.0))
        }
        XCTAssertEqual(progress.elapsedSeconds, 1500, accuracy: 0.001)
        XCTAssertEqual(progress.distanceKm, 5.0, accuracy: 0.0001)
        // What a tick count would have booked instead: 12 km/h × 1425 s / 3600 =
        // 4.75 km. 250 m of real running never counted, so the belt ran ~75 s past
        // the goal.
        //
        // Those 1425 ticks already integrate the whole 5 km; the one below only
        // covers the float residue of a discrete integral, so the assertion does
        // not depend on the sum landing exactly on the goal.
        progress = ProgramRunner.accumulating(progress, tick: tickInput(delta: 1500.0 / 1425.0))
        XCTAssertTrue(ProgramRunner.isComplete(goal: .distance(km: 5.0), progress: progress))
    }

    func testAccumulationClampsAnOversizedDeltaToTheFreshnessHorizon() {
        // A ten-minute gap (a background window, a wedged main thread): only the
        // client's own freshness horizon may be credited, because past it the
        // frame that carried this speed is stale by definition.
        let progress = ProgramRunner.accumulating(ProgramRunner.SegmentProgress(),
                                                  tick: tickInput(delta: 600))
        XCTAssertEqual(progress.elapsedSeconds, ProgramRunner.maxTickSeconds, accuracy: 0.0001)
        XCTAssertEqual(progress.distanceKm,
                       12.0 * ProgramRunner.maxTickSeconds / 3600, accuracy: 0.000001)
    }

    func testNothingAccumulatesWhileNotRunningOrStandingStill() {
        // Acceptance criterion 3, as a property of the function rather than of a
        // statement order: every one of these inputs must leave the tally alone.
        let start = ProgramRunner.SegmentProgress(elapsedSeconds: 42, distanceKm: 0.14)
        let refused: [(String, ProgramRunner.TickInput)] = [
            ("belt not running", tickInput(running: false)),
            ("suspended on a remembered speed", tickInput(running: false, stale: true)),
            ("standing still on a running status (#181)", tickInput(speedKmh: 0)),
            ("no measured time passed", tickInput(delta: 0)),
            ("the clock went backwards", tickInput(delta: -1)),
            ("nonsense speed", tickInput(speedKmh: .nan)),
            ("nonsense delta", tickInput(delta: .infinity)),
        ]
        for (why, input) in refused {
            XCTAssertEqual(ProgramRunner.accumulating(start, tick: input), start, why)
        }
    }

    func testAStaleTickCreditsTheClockButNotASingleMetre() {
        // The whole staleness rule, in one assertion pair: a remembered speed may
        // not become metres, and the clock needs no trusted speed to know that the
        // measured delta passed. Broadening this gate back to `elapsedSeconds` is
        // what lengthened every time segment by the radio gap.
        let start = ProgramRunner.SegmentProgress(elapsedSeconds: 42, distanceKm: 0.14)
        let next = ProgramRunner.accumulating(start, tick: tickInput(delta: 1.25, stale: true))
        XCTAssertEqual(next.elapsedSeconds, 43.25, accuracy: 0.0001)
        XCTAssertEqual(next.distanceKm, start.distanceKm)
    }

    func testATimeSegmentEndsOnTimeAcrossABluetoothGap() {
        // The regression this rule exists for, on the built-in program it broke:
        // the belt holds 9 km/h and nothing decodes for 4 s at t=20. A 60 s
        // interval must still end at 60 s — not at 64, and without ever telling a
        // running user the program is suspended.
        guard let fast = WorkoutProgram.builtIn.flatMap(\.segments).first(where: {
            $0.goal == .time(seconds: 60) && $0.nominalSpeedKmh == 9.0
        }) else { return XCTFail("the built-in interval program lost its 60 s segment") }

        var progress = ProgramRunner.SegmentProgress()
        var ticks = 0
        while !ProgramRunner.isComplete(goal: fast.goal, progress: progress), ticks < 200 {
            let stale = (20..<24).contains(ticks)
            progress = ProgramRunner.accumulating(
                progress, tick: tickInput(speedKmh: fast.nominalSpeedKmh, stale: stale))
            ticks += 1
        }
        XCTAssertEqual(ticks, 60)
        XCTAssertEqual(progress.elapsedSeconds, 60, accuracy: 0.0001)
        // The gap still bought no distance: 56 s of trusted running, not 60.
        XCTAssertEqual(progress.distanceKm, 9.0 * 56 / 3600, accuracy: 0.000001)
    }

    func testTheTickClampIsTheClientsOwnFreshnessHorizon() {
        // One horizon, one constant. Tuning the client's window has to move the
        // runner's clamp with it, or the runner starts crediting a tick with more
        // running than a single frame is evidence for.
        XCTAssertEqual(ProgramRunner.maxTickSeconds,
                       FitShowTreadmillClient.freshnessHorizonSeconds)
    }

    func testTheStationaryTallyCountsMeasuredSecondsNotTimerFires() {
        // #181: "3 s standing" has to mean three seconds. A tick may legitimately
        // cover up to the freshness horizon, so counted in fires three of them
        // could take nine seconds of real standing to suspend the program.
        var tally = 0.0
        tally = ProgramRunner.stationarySeconds(tally, tick: 1.0)
        tally = ProgramRunner.stationarySeconds(tally, tick: 1.0)
        XCTAssertLessThan(tally, ProgramRunner.zeroSpeedSuspendSeconds)
        tally = ProgramRunner.stationarySeconds(tally, tick: 1.0)
        XCTAssertGreaterThanOrEqual(tally, ProgramRunner.zeroSpeedSuspendSeconds)
        // One sparse tick that covers the whole threshold is enough on its own.
        XCTAssertGreaterThanOrEqual(
            ProgramRunner.stationarySeconds(0, tick: ProgramRunner.zeroSpeedSuspendSeconds),
            ProgramRunner.zeroSpeedSuspendSeconds)
        // And a single frame is not evidence of ten minutes of standing: the same
        // horizon bounds this tally as bounds the integral.
        XCTAssertEqual(ProgramRunner.stationarySeconds(0, tick: 600),
                       ProgramRunner.maxTickSeconds, accuracy: 0.0001)
        XCTAssertEqual(ProgramRunner.stationarySeconds(7, tick: -1), 7)
    }

    func testStaleDataCannotFinishASegmentTwentyMetresShortOfItsGoal() {
        // 4.98 km of a 5 km goal covered, then the notifications stall for 8 s
        // while the last frame still claims 12 km/h. Inventing the missing 20 m
        // here would advance the program and write the next segment's target to
        // the belt on data the app has itself flagged as untrustworthy.
        var progress = ProgramRunner.SegmentProgress(elapsedSeconds: 1494, distanceKm: 4.98)
        for _ in 0..<8 {
            progress = ProgramRunner.accumulating(progress, tick: tickInput(stale: true))
        }
        XCTAssertEqual(progress.distanceKm, 4.98, accuracy: 0.000001)
        // The clock ran on through the gap — it is the metres that are missing, and
        // the goal is metres, so the segment stays open.
        XCTAssertEqual(progress.elapsedSeconds, 1502, accuracy: 0.000001)
        XCTAssertFalse(ProgramRunner.isComplete(goal: .distance(km: 5.0), progress: progress))
    }

    // MARK: - The distance goal's time backstop

    func testDistanceGoalEndsOnTheBackstopWhenTheConsoleUnderReportsItsSpeed() {
        // A console reporting 2.0 km/h while the belt runs at 8.0: the integral
        // never reaches 5 km, so without a backstop the segment is immortal and
        // the program never reaches requestStop().
        let goal = SegmentGoal.distance(km: 5.0)
        let cap = ProgramRunner.distanceGoalCapSeconds(km: 5.0)
        XCTAssertEqual(cap, 5.0 / TreadmillLimits().minSpeedKmh * 3600, accuracy: 0.001)
        XCTAssertFalse(ProgramRunner.isComplete(
            goal: goal,
            progress: ProgramRunner.SegmentProgress(elapsedSeconds: cap - 1, distanceKm: 2.5)))
        XCTAssertTrue(ProgramRunner.isComplete(
            goal: goal,
            progress: ProgramRunner.SegmentProgress(elapsedSeconds: cap, distanceKm: 2.5)))
    }

    /// Walks a 1 km goal to completion at a fixed speed and reports how it ended.
    private func walkOneKilometre(atKmh speed: Double)
        -> (ticks: Int, progress: ProgramRunner.SegmentProgress) {
        var progress = ProgramRunner.SegmentProgress()
        var ticks = 0
        while !ProgramRunner.isComplete(goal: .distance(km: 1.0), progress: progress),
              ticks < 20_000 {
            progress = ProgramRunner.accumulating(progress, tick: tickInput(speedKmh: speed))
            ticks += 1
        }
        return (ticks, progress)
    }

    func testTheBackstopCannotCutShortASlowWalkAboveTheEstimateFloor() {
        // 1 km at 1.0 km/h: above the 0.8 km/h floor the backstop is derived from,
        // so the goal must be what ends the segment. At exactly the floor the two
        // fall on the same tick and the assertion could not tell them apart.
        // 1 km at 1 km/h is 3600 s of running; the backstop only fires at 4500.
        let walk = walkOneKilometre(atKmh: 1.0)
        XCTAssertGreaterThanOrEqual(walk.progress.distanceKm, 1.0 - 0.0001)
        XCTAssertEqual(Double(walk.ticks), 3600, accuracy: 1)
        XCTAssertLessThan(walk.progress.elapsedSeconds,
                          ProgramRunner.distanceGoalCapSeconds(km: 1.0))
    }

    func testTheBackstopEndsASegmentWhoseBeltCreepsBelowTheEstimateFloor() {
        // A machine whose real minimum is under the default floor, or a console
        // under-reporting its speed: the integral cannot reach the goal inside the
        // backstop's window, so the backstop is what has to end the segment —
        // short of the goal, which is the direction of the failure.
        let creeping = TreadmillLimits().minSpeedKmh / 2
        let walk = walkOneKilometre(atKmh: creeping)
        XCTAssertLessThan(walk.progress.distanceKm, 1.0)
        XCTAssertEqual(walk.progress.elapsedSeconds,
                       ProgramRunner.distanceGoalCapSeconds(km: 1.0), accuracy: 1)
    }

    func testTheBackstopSharesTheEstimateCeilingAndEndsANonsenseGoal() {
        // 42.2 / 0.8 * 3600 = 189900 s, capped to the same 24 h the plan and the
        // ETA are capped to.
        XCTAssertEqual(ProgramRunner.distanceGoalCapSeconds(km: 42.2),
                       Double(WorkoutSegment.maxEstimateSeconds), accuracy: 0.001)
        // A nonsense goal must end the segment, never outlive it.
        XCTAssertEqual(ProgramRunner.distanceGoalCapSeconds(km: 0), 0)
        XCTAssertTrue(ProgramRunner.isComplete(goal: .distance(km: .nan),
                                               progress: ProgramRunner.SegmentProgress()))
    }

    // MARK: - One ceiling for the plan and the live ETA

    func testPlannedDurationAndTheLiveETAShareOneCeiling() {
        let segment = WorkoutSegment(name: "Crawl", goal: .distance(km: 42.2),
                                     targetSpeedKmh: 0.8, targetIncline: 0)
        XCTAssertEqual(segment.plannedDuration, Double(WorkoutSegment.maxEstimateSeconds))
        XCTAssertEqual(segment.plannedDurationSeconds, WorkoutSegment.maxEstimateSeconds)
        XCTAssertEqual(ProgramRunner.estimatedRemainingSeconds(
            goal: segment.goal, progress: ProgramRunner.SegmentProgress(),
            commandedSpeedKmh: segment.targetSpeedKmh), WorkoutSegment.maxEstimateSeconds)
    }

    /// The remaining seconds the runner publishes the moment a segment begins.
    private func remainingAtStart(of segment: WorkoutSegment) -> TimeInterval {
        TimeInterval(ProgramRunner.estimatedRemainingSeconds(
            goal: segment.goal, progress: ProgramRunner.SegmentProgress(),
            commandedSpeedKmh: segment.targetSpeedKmh))
    }

    func testProgramProgressStartsAtZeroForEveryLegalProgram() {
        var programs = WorkoutProgram.builtIn
        // The reproduction: a 52-hour plan against a 24 h ETA showed the bar 55%
        // full at second zero.
        programs.append(WorkoutProgram(name: "Marathon crawl", segments: [
            WorkoutSegment(name: "Crawl", goal: .distance(km: 42.2),
                           targetSpeedKmh: 0.8, targetIncline: 0),
        ]))
        programs.append(WorkoutProgram(name: "Mixed", segments: [
            WorkoutSegment(name: "Warm-up", duration: 180, targetSpeedKmh: 5.0, targetIncline: 0),
            WorkoutSegment(name: "5 km", goal: .distance(km: 5.0),
                           targetSpeedKmh: 7.0, targetIncline: 0),
            WorkoutSegment(name: "Cool-down", duration: 120, targetSpeedKmh: 4.0, targetIncline: 0),
        ]))
        for program in programs {
            let progress = ProgramRunner.programProgress(
                in: program, segmentIndex: 0,
                segmentRemaining: remainingAtStart(of: program.segments[0]))
            XCTAssertEqual(progress ?? -1, 0, accuracy: 0.001, program.name)
        }
    }

    func testProgramProgressIsHalfwayHalfwayThroughADistanceSegment() {
        let program = WorkoutProgram(name: "5 km", segments: [
            WorkoutSegment(name: "5 km", goal: .distance(km: 5.0),
                           targetSpeedKmh: 10.0, targetIncline: 0),
        ])
        // 2.5 km covered of 5.0 at a commanded 10 km/h: 900 s left of 1800.
        let remaining = TimeInterval(ProgramRunner.estimatedRemainingSeconds(
            goal: program.segments[0].goal,
            progress: ProgramRunner.SegmentProgress(elapsedSeconds: 900, distanceKm: 2.5),
            commandedSpeedKmh: 10.0))
        XCTAssertEqual(ProgramRunner.programProgress(in: program, segmentIndex: 0,
                                                     segmentRemaining: remaining) ?? -1,
                       0.5, accuracy: 0.001)
    }

    // MARK: - isComplete

    func testIsCompleteForTimeGoalAtBelowExactlyAndPastTheGoal() {
        let goal = SegmentGoal.time(seconds: 60)
        XCTAssertFalse(ProgramRunner.isComplete(
            goal: goal, progress: ProgramRunner.SegmentProgress(elapsedSeconds: 59, distanceKm: 0)))
        XCTAssertTrue(ProgramRunner.isComplete(
            goal: goal, progress: ProgramRunner.SegmentProgress(elapsedSeconds: 60, distanceKm: 0)))
        XCTAssertTrue(ProgramRunner.isComplete(
            goal: goal, progress: ProgramRunner.SegmentProgress(elapsedSeconds: 61, distanceKm: 0)))
    }

    func testIsCompleteForDistanceGoalAtBelowExactlyAndPastTheGoal() {
        let goal = SegmentGoal.distance(km: 5.0)
        XCTAssertFalse(ProgramRunner.isComplete(
            goal: goal, progress: ProgramRunner.SegmentProgress(elapsedSeconds: 0, distanceKm: 4.999)))
        XCTAssertTrue(ProgramRunner.isComplete(
            goal: goal, progress: ProgramRunner.SegmentProgress(elapsedSeconds: 0, distanceKm: 5.0)))
        XCTAssertTrue(ProgramRunner.isComplete(
            goal: goal, progress: ProgramRunner.SegmentProgress(elapsedSeconds: 0, distanceKm: 5.001)))
    }

    // MARK: - estimatedRemainingSeconds

    func testEstimatedRemainingSecondsForTimeGoal() {
        let goal = SegmentGoal.time(seconds: 300)
        let progress = ProgramRunner.SegmentProgress(elapsedSeconds: 100, distanceKm: 0)
        // 300 - 100 elapsed = 200 s left, regardless of the commanded speed.
        XCTAssertEqual(ProgramRunner.estimatedRemainingSeconds(
            goal: goal, progress: progress, commandedSpeedKmh: 8.0), 200)
    }

    func testEstimatedRemainingSecondsForDistanceGoalAtTargetSpeed() {
        let goal = SegmentGoal.distance(km: 5.0)
        let progress = ProgramRunner.SegmentProgress(elapsedSeconds: 0, distanceKm: 2.0)
        // 3.0 km left at the commanded 8.0 km/h: 3.0 / 8.0 * 3600 = 1350 s.
        XCTAssertEqual(ProgramRunner.estimatedRemainingSeconds(
            goal: goal, progress: progress, commandedSpeedKmh: 8.0), 1350)
    }

    func testEstimatedRemainingSecondsForDistanceGoalAtZeroSpeedAppliesTheFloor() {
        let goal = SegmentGoal.distance(km: 2.0)
        let progress = ProgramRunner.SegmentProgress(elapsedSeconds: 0, distanceKm: 0)
        // 0 km/h floors to TreadmillLimits().minSpeedKmh (0.8 km/h):
        // 2.0 / 0.8 * 3600 = 9000 s — finite, no crash, no negative.
        let remaining = ProgramRunner.estimatedRemainingSeconds(
            goal: goal, progress: progress, commandedSpeedKmh: 0)
        XCTAssertEqual(remaining, 9000)
        XCTAssertGreaterThanOrEqual(remaining, 0)
    }

    func testEstimatedRemainingSecondsCapsAt24Hours() {
        let goal = SegmentGoal.distance(km: 42.2)
        let progress = ProgramRunner.SegmentProgress(elapsedSeconds: 0, distanceKm: 0)
        // 42.2 / 1.0 * 3600 = 151920 s, capped to 24 h = 86400 s.
        XCTAssertEqual(ProgramRunner.estimatedRemainingSeconds(
            goal: goal, progress: progress, commandedSpeedKmh: 1.0), 86400)
    }

    // MARK: - programRemainingSeconds, mixed goals

    func testProgramRemainingSecondsForMixedTimeAndDistanceGoals() {
        let program = WorkoutProgram(name: "Mixed", segments: [
            WorkoutSegment(name: "Warm-up", duration: 180, targetSpeedKmh: 5.0, targetIncline: 0),
            WorkoutSegment(name: "Distance leg", goal: .distance(km: 5.0), targetSpeedKmh: 10.0, targetIncline: 0),
            WorkoutSegment(name: "Cool-down", duration: 60, targetSpeedKmh: 4.0, targetIncline: 0),
        ])
        // The distance leg's planned duration: 5.0 / 10.0 * 3600 = 1800 s.
        XCTAssertEqual(ProgramRunner.programRemainingSeconds(
            in: program, segmentIndex: 0, segmentRemaining: 100), 100 + 1800 + 60)
        XCTAssertEqual(ProgramRunner.programRemainingSeconds(
            in: program, segmentIndex: 1, segmentRemaining: 900), 900 + 60)
    }

    // MARK: - WorkoutProgram totals, mixed goals

    func testWorkoutProgramTotalsForMixedTimeAndDistanceGoals() {
        let program = WorkoutProgram(name: "Mixed totals", segments: [
            WorkoutSegment(name: "Time leg", duration: 600, targetSpeedKmh: 6.0, targetIncline: 0),
            WorkoutSegment(name: "Distance leg", goal: .distance(km: 2.0), targetSpeedKmh: 8.0, targetIncline: 0),
        ])
        // Time leg: 600 s @ 6 km/h -> 1.0 km. Distance leg: exact 2.0 km, planned
        // duration 2.0 / 8.0 * 3600 = 900 s. Totals: 1500 s, 3.0 km, 7.2 km/h average.
        XCTAssertEqual(program.totalDuration, 1500)
        XCTAssertEqual(program.totalDistanceKm, 3.0, accuracy: 0.001)
        XCTAssertEqual(program.averageSpeedKmh, 7.2, accuracy: 0.001)
        // The distance leg's duration is only a projection...
        XCTAssertTrue(program.hasEstimatedDuration)
        // ...and the time leg's distance is only a projection, the other way round.
        XCTAssertTrue(program.hasEstimatedDistance)
    }

    // MARK: - CustomSegmentRecord round-trip

    func testCustomSegmentRecordDistanceGoalRoundTripsThroughAsWorkoutProgram() {
        let program = CustomProgram(name: "Round-trip")
        let record = CustomSegmentRecord(orderIndex: 0, name: "Distance leg",
                                         durationSeconds: 0, targetSpeedKmh: 10.0, targetIncline: 1)
        record.program = program
        program.segments.append(record)
        // Set after the speed, per the CustomProgram.copy(of:) precedent: the stored
        // planned duration is derived from the speed already in place.
        record.goal = .distance(km: 5.0)

        XCTAssertEqual(record.goal, .distance(km: 5.0))
        // durationSeconds is the planned-duration mirror: 5.0 / 10.0 * 3600 = 1800 s.
        XCTAssertEqual(record.durationSeconds, 1800)

        let workout = program.asWorkoutProgram
        XCTAssertEqual(workout.segments.count, 1)
        XCTAssertEqual(workout.segments[0].goal, .distance(km: 5.0))
        XCTAssertEqual(workout.segments[0].targetSpeedKmh, 10.0)
        XCTAssertEqual(workout.segments[0].targetIncline, 1)
    }

    func testCopyOfPreservesTheDistanceGoalAndItsPlannedDurationMirror() {
        let source = WorkoutProgram(name: "Source", segments: [
            WorkoutSegment(name: "Distance leg", goal: .distance(km: 3.0),
                           targetSpeedKmh: 6.0, targetIncline: 2),
        ])
        let copy = CustomProgram.copy(of: source, name: "Copy")

        XCTAssertEqual(copy.segments.count, 1)
        let record = copy.sortedSegments[0]
        XCTAssertEqual(record.goal, .distance(km: 3.0))
        XCTAssertEqual(record.targetSpeedKmh, 6.0)
        XCTAssertEqual(record.targetIncline, 2)
        // durationSeconds is the planned-duration mirror: 3.0 / 6.0 * 3600 = 1800 s.
        XCTAssertEqual(record.durationSeconds, 1800)

        XCTAssertEqual(copy.asWorkoutProgram.segments[0].goal, .distance(km: 3.0))
    }

    // MARK: - Unknown / degraded stored goal kinds

    func testUnknownGoalKindRawDecodesToTime() {
        let record = CustomSegmentRecord(orderIndex: 0, name: "Future kind",
                                         durationSeconds: 240, targetSpeedKmh: 5.0, targetIncline: 0)
        // A record written by a newer build than this one — the raw string is not
        // one of the cases this build knows, and must not crash the getter.
        record.goalKindRaw = "futureKind"
        XCTAssertEqual(record.goal, .time(seconds: 240))
    }

    func testDistanceGoalWithNonPositiveStoredDistanceDegradesToTime() {
        let record = CustomSegmentRecord(orderIndex: 0, name: "Zero distance",
                                         durationSeconds: 180, targetSpeedKmh: 5.0, targetIncline: 0)
        // Simulates a stored .distance kind whose distance column is 0 (or an
        // un-migrated default) — a 0 km goal would otherwise finish instantly.
        record.goalKindRaw = SegmentGoal.Kind.distance.rawValue
        record.goalDistanceKm = 0
        XCTAssertEqual(record.goal, .time(seconds: 180))
    }
}
