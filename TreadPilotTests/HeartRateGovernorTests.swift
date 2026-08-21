// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import XCTest
@testable import TreadPilot

final class HeartRateGovernorTests: XCTestCase {

    typealias Governor = HeartRateGovernor
    typealias Command = HeartRateGovernor.Command
    typealias Change = HeartRateGovernor.Change
    typealias Tallies = HeartRateGovernor.Tallies
    typealias Decision = HeartRateGovernor.Decision

    // Resting 60 / max 180, the pair every zone test in this suite is built on:
    // Z3 is 144…155 bpm, the force-down ceiling 166, the stop ceiling 175.
    private let basis = HeartRateBasis(restingBpm: 60, maxBpm: 180)
    private let limits = TreadmillLimits() // 0.8…16.0 km/h, incline 0…12

    /// A speed-actuated zone-3 segment: start at 6, free between 4 and 10 km/h,
    /// and a declared walking fallback.
    private func speedTarget(low: Int = 144, high: Int = 155,
                             min: Double = 4.0, max: Double = 10.0,
                             fallback: Double = 4.5) -> HeartRateTarget {
        HeartRateTarget(lowBpm: low, highBpm: high, actuator: .speed,
                        startSpeedKmh: 6.0, startIncline: 0,
                        minSpeedKmh: min, maxSpeedKmh: max,
                        minIncline: 0, maxIncline: 0, fallbackSpeedKmh: fallback)
    }

    /// An incline-actuated segment at a fixed 6 km/h, free between levels 0 and 6.
    private func inclineTarget(low: Int = 144, high: Int = 155,
                               minLevel: Int = 0, maxLevel: Int = 6) -> HeartRateTarget {
        HeartRateTarget(lowBpm: low, highBpm: high, actuator: .incline,
                        startSpeedKmh: 6.0, startIncline: 0,
                        minSpeedKmh: 6.0, maxSpeedKmh: 6.0,
                        minIncline: minLevel, maxIncline: maxLevel, fallbackSpeedKmh: 6.0)
    }

    /// An input that is past every settle window and has no tally standing, so a
    /// test only has to state what it is actually about.
    ///
    /// `belt` defaults to `.unobserved`: nothing measured and nobody's hand on the
    /// dial. A test that is about the belt says so.
    /// `sinceLoadChange` defaults to `sinceLastCommand`, which is the production
    /// relationship: the app's own write re-arms both clocks, so the two only come
    /// apart when somebody else changes the load (finding 137).
    private func input(_ target: HeartRateTarget, heartRate: Int,
                       command: Command,
                       lastChange: Change? = nil,
                       belt: Governor.BeltFacts = .unobserved,
                       sinceSegmentStart: Double = 600,
                       sinceLastCommand: Double = 600,
                       sinceLoadChange: Double? = nil,
                       tallies: Tallies = Tallies(),
                       limits: TreadmillLimits? = nil) -> Governor.Input {
        Governor.Input(target: target, basis: basis, limits: limits ?? self.limits,
                       heartRate: heartRate, command: command,
                       lastAppliedChange: lastChange ?? .settled(at: command),
                       secondsSinceSegmentStart: sinceSegmentStart,
                       secondsSinceLastCommand: sinceLastCommand,
                       secondsSinceLoadChange: sinceLoadChange ?? sinceLastCommand,
                       tallies: tallies, belt: belt)
    }

    /// Facts 2 and 3 as the client reports them. There is no "travelling" flag
    /// any more: the reference is `min(fact 1, fact 2)` whether an actuator is
    /// mid-journey or not (finding 124).
    private func belt(measured: Command? = nil, speedByHand: Bool = false,
                      inclineByHand: Bool = false) -> Governor.BeltFacts {
        Governor.BeltFacts(measured: measured, isSpeedSetByHand: speedByHand,
                           isInclineSetByHand: inclineByHand)
    }

    private func speedCommand(_ speedKmh: Double, incline: Int = 0) -> Command {
        Command(speedKmh: speedKmh, incline: incline)
    }

    // MARK: - Derived quantities

    func testCeilingsAreThePercentagesOfTheFrozenMaximum() {
        // 0.92 × 180 = 165.6 → 166; 0.97 × 180 = 174.6 → 175.
        let ceilings = Governor.ceilings(for: basis)
        XCTAssertEqual(ceilings.forceDownBpm, 166)
        XCTAssertEqual(ceilings.stopBpm, 175)
    }

    func testCeilingsFollowTheBasisAndNothingElse() {
        // The same person with a lower frozen maximum gets lower ceilings — and
        // the basis is the only input that can move them.
        let low = Governor.ceilings(for: HeartRateBasis(restingBpm: 60, maxBpm: 120))
        XCTAssertEqual(low.forceDownBpm, 110)
        XCTAssertEqual(low.stopBpm, 116)
    }

    func testABandStoredInTheWrongOrderIsRepairedNotInverted() {
        let target = speedTarget(low: 155, high: 144)
        XCTAssertEqual(Governor.band(for: target), 144...155)
    }

    func testSpeedBoundsAreTheSegmentIntersectedWithTheDeviceLimits() {
        let bounds = Governor.speedBounds(for: speedTarget(min: 4, max: 10), limits: limits)
        XCTAssertEqual(bounds.lowerBound, 4.0, accuracy: 0.0001)
        XCTAssertEqual(bounds.upperBound, 10.0, accuracy: 0.0001)
        // A segment wider than the machine cannot widen the machine.
        let wide = Governor.speedBounds(for: speedTarget(min: 0.1, max: 30), limits: limits)
        XCTAssertEqual(wide.lowerBound, limits.minSpeedKmh, accuracy: 0.0001)
        XCTAssertEqual(wide.upperBound, limits.maxSpeedKmh, accuracy: 0.0001)
    }

    func testSpeedBoundsSnapInwardToTheProtocolGrid() {
        // 8.35 sent as-is would leave the console at 8.4 — above the bound the
        // user set. Bounds therefore round inward, never outward.
        let bounds = Governor.speedBounds(for: speedTarget(min: 4.02, max: 8.35), limits: limits)
        XCTAssertEqual(bounds.lowerBound, 4.1, accuracy: 0.0001)
        XCTAssertEqual(bounds.upperBound, 8.3, accuracy: 0.0001)
    }

    func testReversedOrNonsenseBoundsCollapseInsteadOfTrapping() {
        let bounds = Governor.speedBounds(for: speedTarget(min: 10, max: 4), limits: limits)
        XCTAssertTrue(bounds.lowerBound <= bounds.upperBound)
        let incline = Governor.inclineBounds(for: inclineTarget(minLevel: 8, maxLevel: 2),
                                            limits: limits)
        XCTAssertTrue(incline.lowerBound <= incline.upperBound)
    }

    func testInclineBoundsCollapseOnAMachineWithoutAnInclineMotor() {
        var flat = limits
        flat.maxIncline = 0
        XCTAssertEqual(Governor.inclineBounds(for: inclineTarget(maxLevel: 6), limits: flat),
                       0...0)
    }

    /// **This test used to pin the exact comparison, and the exact comparison was
    /// the defect.** It asked one question — is the reference itself on the bound —
    /// and the reference carries the belt's raw measured speed, so a console with a
    /// one-tenth bias was "not at the bound" on every single tick, the 120 s stall
    /// window never filled, and the give-up rule could not fire at all. The
    /// predicate now asks fact 1, the app's own command, and gives the reference one
    /// step of room.
    func testUpperBoundDetectionReadsTheAppsCommandAndAllowsOneStepOfMeasurement() {
        let target = speedTarget(max: 10)
        // The app is commanding the bound: the loop has no room left, whatever the
        // frames say within one step of it.
        for reference in [10.0, 9.9, 9.8] {
            XCTAssertTrue(Governor.isAtUpperBound(reference: speedCommand(reference),
                                                  appCommand: speedCommand(10.0),
                                                  target: target, limits: limits),
                          "reference \(reference) is within one step of the bound")
        }
        // More than a step below it is a belt somewhere else — a segment entered
        // from a slower one, a person who dialled it down — and not a loop out of
        // room.
        XCTAssertFalse(Governor.isAtUpperBound(reference: speedCommand(9.7),
                                               appCommand: speedCommand(10.0),
                                               target: target, limits: limits))
        // And the app not being at the bound is decisive on its own: there is a
        // step left to take, so nothing has stalled.
        XCTAssertFalse(Governor.isAtUpperBound(reference: speedCommand(9.8),
                                               appCommand: speedCommand(9.8),
                                               target: target, limits: limits))
        let incline = inclineTarget(maxLevel: 6)
        XCTAssertTrue(Governor.isAtUpperBound(reference: speedCommand(6, incline: 6),
                                              appCommand: speedCommand(6, incline: 6),
                                              target: incline, limits: limits))
        // One level of travel left to report is still at the bound; two is not.
        XCTAssertTrue(Governor.isAtUpperBound(reference: speedCommand(6, incline: 5),
                                              appCommand: speedCommand(6, incline: 6),
                                              target: incline, limits: limits))
        XCTAssertFalse(Governor.isAtUpperBound(reference: speedCommand(6, incline: 4),
                                               appCommand: speedCommand(6, incline: 6),
                                               target: incline, limits: limits))
        XCTAssertFalse(Governor.isAtUpperBound(reference: speedCommand(6, incline: 5),
                                               appCommand: speedCommand(6, incline: 5),
                                               target: incline, limits: limits))
    }

    // MARK: - The proportional law

    func testTheStepLawHasThreeOutputsAndIsSaturated() {
        // Gain 0.02 km/h per bpm on a 0.1 grid, capped at 0.2: one quantum below
        // 7.5 bpm of error, two above, and never more however wrong the reading.
        XCTAssertEqual(Governor.speedStepKmh(forError: 1), 0.1, accuracy: 0.0001)
        XCTAssertEqual(Governor.speedStepKmh(forError: 7), 0.1, accuracy: 0.0001)
        XCTAssertEqual(Governor.speedStepKmh(forError: 8), 0.2, accuracy: 0.0001)
        XCTAssertEqual(Governor.speedStepKmh(forError: 90), Governor.maxSpeedStepKmh,
                       accuracy: 0.0001)
        // No error is too small to move: a step that rounds to nothing would let a
        // 1 bpm miss stand forever, which is what an integral term is usually for.
        XCTAssertEqual(Governor.speedStepKmh(forError: 0), 0.1, accuracy: 0.0001)
    }

    // MARK: - The dead band and the band law

    func testInsideTheBandNothingIsCommanded() {
        for heartRate in [144, 150, 155] {
            let decision = Governor.decide(input(speedTarget(), heartRate: heartRate,
                                                 command: speedCommand(8.0)))
            XCTAssertEqual(decision, .hold(reason: .insideBand), "at \(heartRate) bpm")
        }
    }

    func testBelowTheBandItStepsUpByTheProportionalStep() {
        // 138 bpm is 6 below the band floor → one quantum.
        XCTAssertEqual(Governor.decide(input(speedTarget(), heartRate: 138,
                                             command: speedCommand(8.0))),
                       .adjust(command: speedCommand(8.1), reason: .belowBand))
        // 130 bpm is 14 below → the saturated two quanta, and no more.
        XCTAssertEqual(Governor.decide(input(speedTarget(), heartRate: 130,
                                             command: speedCommand(8.0))),
                       .adjust(command: speedCommand(8.2), reason: .belowBand))
    }

    func testAboveTheBandItStepsDown() {
        XCTAssertEqual(Governor.decide(input(speedTarget(), heartRate: 160,
                                             command: speedCommand(8.0))),
                       .adjust(command: speedCommand(7.9), reason: .aboveBand))
        XCTAssertEqual(Governor.decide(input(speedTarget(), heartRate: 170,
                                             command: speedCommand(8.0))),
                       .adjust(command: speedCommand(7.8), reason: .aboveBand))
    }

    func testTheInclineActuatorMovesOneLevelAndLeavesTheSpeedAlone() {
        let target = inclineTarget()
        XCTAssertEqual(Governor.decide(input(target, heartRate: 130,
                                             command: speedCommand(6.0, incline: 2))),
                       .adjust(command: speedCommand(6.0, incline: 3), reason: .belowBand))
        // Even a 40 bpm error is one level: the level *is* the step limit.
        XCTAssertEqual(Governor.decide(input(target, heartRate: 104,
                                             command: speedCommand(6.0, incline: 2))),
                       .adjust(command: speedCommand(6.0, incline: 3), reason: .belowBand))
        XCTAssertEqual(Governor.decide(input(target, heartRate: 170,
                                             command: speedCommand(6.0, incline: 2))),
                       .adjust(command: speedCommand(6.0, incline: 1), reason: .aboveBand))
    }

    func testAReversalInsideTheMarginHoldsInsteadOfPingPonging() {
        // The last change was an increase (7.8 → 8.0); 157 bpm is 2 over the band,
        // inside the reversal margin, so the previous step keeps the benefit of
        // the doubt.
        let rising = Change(from: speedCommand(7.8), to: speedCommand(8.0))
        XCTAssertEqual(Governor.decide(input(speedTarget(), heartRate: 157,
                                             command: speedCommand(8.0),
                                             lastChange: rising)),
                       .hold(reason: .hysteresis))
        // 158 is 3 over: past the margin, the reversal happens.
        XCTAssertEqual(Governor.decide(input(speedTarget(), heartRate: 158,
                                             command: speedCommand(8.0),
                                             lastChange: rising)),
                       .adjust(command: speedCommand(7.9), reason: .aboveBand))
        // Continuing in the same direction is never held back by the margin.
        XCTAssertEqual(Governor.decide(input(speedTarget(), heartRate: 143,
                                             command: speedCommand(8.0),
                                             lastChange: rising)),
                       .adjust(command: speedCommand(8.1), reason: .belowBand))
    }

    // MARK: - Settle windows

    func testNothingIsChasedInsideTheSettleWindows() {
        // Heart rate lags load by 20–40 s: the reading in hand still describes the
        // load before the last change.
        XCTAssertEqual(Governor.decide(input(speedTarget(), heartRate: 130,
                                             command: speedCommand(8.0),
                                             sinceLastCommand: 44)),
                       .hold(reason: .settling))
        XCTAssertEqual(Governor.decide(input(speedTarget(), heartRate: 130,
                                             command: speedCommand(8.0),
                                             sinceSegmentStart: 44)),
                       .hold(reason: .settling))
        XCTAssertEqual(Governor.decide(input(speedTarget(), heartRate: 130,
                                             command: speedCommand(8.0),
                                             sinceSegmentStart: 45, sinceLastCommand: 45)),
                       .adjust(command: speedCommand(8.2), reason: .belowBand))
    }

    func testTheInclineActuatorGetsTheLongerSettleWindow() {
        XCTAssertEqual(Governor.settleSeconds(for: .speed), 45)
        XCTAssertEqual(Governor.settleSeconds(for: .incline), 60)
        // 50 s is enough for a speed step and not for an incline level.
        XCTAssertEqual(Governor.decide(input(inclineTarget(), heartRate: 130,
                                             command: speedCommand(6.0, incline: 2),
                                             sinceLastCommand: 50)),
                       .hold(reason: .settling))
        XCTAssertEqual(Governor.decide(input(inclineTarget(), heartRate: 130,
                                             command: speedCommand(6.0, incline: 2),
                                             sinceLastCommand: 60)),
                       .adjust(command: speedCommand(6.0, incline: 3), reason: .belowBand))
    }

    func testTheSettleWindowIsArmedByAnyObservedChangeOfLoad() {
        // **Finding 137.** The window exists because the reading in hand still
        // describes the load before the last change — and whose hand made that
        // change has nothing to do with it. Armed only by the app's own writes, the
        // first step after a manual reduction could go out ten seconds later, from a
        // heart rate that predated the reduction: the loop pushing back up on
        // somebody who had just chosen to go slower.
        XCTAssertEqual(Governor.decide(input(speedTarget(), heartRate: 130,
                                             command: speedCommand(8.0),
                                             sinceLastCommand: 600, sinceLoadChange: 8)),
                       .hold(reason: .settling))
        XCTAssertEqual(Governor.decide(input(speedTarget(), heartRate: 130,
                                             command: speedCommand(8.0),
                                             sinceLastCommand: 600, sinceLoadChange: 45)),
                       .adjust(command: speedCommand(8.2), reason: .belowBand))
        // A brake is not delayed by it. The app's own clock is the floor under two
        // successive forced reductions, and the dial that made a reduction necessary
        // may not postpone it.
        XCTAssertEqual(Governor.decide(input(speedTarget(), heartRate: 168,
                                             command: speedCommand(8.0),
                                             sinceLastCommand: 600, sinceLoadChange: 1,
                                             tallies: Tallies(secondsAboveForceDownCeiling: 12))),
                       .adjust(command: speedCommand(7.8), reason: .ceilingForceDown))
    }

    func testALoadChangeIsTheLoopsOwnStepAndNotTheBeltsNoise() {
        // The threshold that keeps a belt reporting a tenth either side of the value
        // it is holding from re-arming the settle window for ever: the loop's own
        // step, per axis. Compared in protocol units at every speed the device
        // offers, because one quantum is 0.09999999999999964 as a `Double`.
        for units in 8...160 {
            let held = speedCommand(Governor.speedKmh(units: units))
            XCTAssertFalse(Governor.isLoadChanged(
                from: held, to: speedCommand(Governor.speedKmh(units: units + 1))),
                           "one tenth at \(units) tenths is noise")
            XCTAssertTrue(Governor.isLoadChanged(
                from: held, to: speedCommand(Governor.speedKmh(units: units + 2))),
                          "two tenths at \(units) tenths is the loop's own step")
            XCTAssertTrue(Governor.isLoadChanged(
                from: held, to: speedCommand(Governor.speedKmh(units: units - 2))),
                          "and so is two tenths downward")
        }
        // One incline level is a whole step on that axis.
        XCTAssertTrue(Governor.isLoadChanged(from: speedCommand(8.0),
                                             to: speedCommand(8.0, incline: 1)))
        XCTAssertFalse(Governor.isLoadChanged(from: speedCommand(8.0, incline: 3),
                                              to: speedCommand(8.0, incline: 3)))
    }

    // MARK: - Bounds

    func testItNeverCommandsAboveTheSegmentUpperBoundHoweverLowTheHeartRate() {
        // 90 bpm at the top of the segment's range argues for a lot more speed.
        XCTAssertEqual(Governor.decide(input(speedTarget(max: 10), heartRate: 90,
                                             command: speedCommand(10.0))),
                       .hold(reason: .atBound))
        XCTAssertEqual(Governor.decide(input(inclineTarget(maxLevel: 6), heartRate: 90,
                                             command: speedCommand(6.0, incline: 6))),
                       .hold(reason: .atBound))
    }

    func testItNeverCommandsBelowTheSegmentLowerBoundHoweverHighTheHeartRate() {
        XCTAssertEqual(Governor.decide(input(speedTarget(min: 4), heartRate: 174,
                                             command: speedCommand(4.0))),
                       .hold(reason: .atBound))
        XCTAssertEqual(Governor.decide(input(inclineTarget(minLevel: 0), heartRate: 174,
                                             command: speedCommand(6.0, incline: 0))),
                       .hold(reason: .atBound))
    }

    func testTheDeviceLimitBindsWhenItIsTighterThanTheSegment() {
        var slow = limits
        slow.maxSpeedRaw = 90 // 9.0 km/h
        XCTAssertEqual(Governor.decide(input(speedTarget(max: 12), heartRate: 90,
                                             command: speedCommand(9.0), limits: slow)),
                       .hold(reason: .atBound))
    }

    func testACommandAboveTheBoundIsCorrectedDownwardAndNeverUpward() {
        // A malformed segment can start above its own ceiling; the correction is
        // a reduction, so it is safe even though it is larger than a step.
        XCTAssertEqual(Governor.decide(input(speedTarget(max: 10), heartRate: 150,
                                             command: speedCommand(12.0))),
                       .adjust(command: speedCommand(10.0), reason: .outOfBounds))
        // Below the lower bound nothing is corrected: raising a command to a lower
        // bound would be an acceleration no heart rate asked for.
        XCTAssertEqual(Governor.decide(input(speedTarget(min: 4), heartRate: 150,
                                             command: speedCommand(3.0))),
                       .hold(reason: .insideBand))
    }

    // MARK: - The feed

    func testAMissingReadingFreezesTheCommand() {
        // The handlebar case from the specification: no fresh Watch reading, and
        // whatever the handlebar sensor says never reaches this function.
        XCTAssertEqual(Governor.decide(input(speedTarget(), heartRate: 0,
                                             command: speedCommand(8.0),
                                             tallies: Tallies(secondsWithoutHeartRate: 9))),
                       .frozen)
        // A freeze one second before the fallback window is still a freeze.
        XCTAssertEqual(Governor.decide(input(speedTarget(), heartRate: 0,
                                             command: speedCommand(8.0),
                                             tallies: Tallies(secondsWithoutHeartRate: 29))),
                       .frozen)
    }

    func testAfterThirtySecondsWithoutAReadingItFallsBackToAWalk() {
        XCTAssertEqual(Governor.decide(input(speedTarget(fallback: 4.5), heartRate: 0,
                                             command: speedCommand(8.0),
                                             tallies: Tallies(secondsWithoutHeartRate: 30))),
                       .fallback(command: speedCommand(4.5)))
    }

    func testTheFallbackNeverAcceleratesAndNeverCommandsZero() {
        // A fallback above the current command must not be sent: absent data is
        // the one input that may never make the belt faster.
        XCTAssertEqual(Governor.decide(input(speedTarget(fallback: 9.0), heartRate: 0,
                                             command: speedCommand(5.0),
                                             tallies: Tallies(secondsWithoutHeartRate: 60))),
                       .frozen)
        // A brake is bounded by the device and not by the segment's corridor, so
        // the stored default of 0 clamps into the *machine's* minimum — the
        // slowest walk it does, which is still not a stop.
        XCTAssertEqual(Governor.decide(input(speedTarget(min: 4, fallback: 0), heartRate: 0,
                                             command: speedCommand(8.0),
                                             tallies: Tallies(secondsWithoutHeartRate: 30))),
                       .fallback(command: speedCommand(limits.minSpeedKmh)))
        XCTAssertGreaterThan(limits.minSpeedKmh, 0)
    }

    func testAnInclineSegmentFallsBackOnItsOwnAxis() {
        // One actuator per segment holds in the failure path too: the incline goes
        // to the flattest the machine does, the speed the user chose is left alone.
        XCTAssertEqual(Governor.decide(input(inclineTarget(minLevel: 1), heartRate: 0,
                                             command: speedCommand(6.0, incline: 5),
                                             tallies: Tallies(secondsWithoutHeartRate: 30))),
                       .fallback(command: speedCommand(6.0, incline: limits.minIncline)))
    }

    // MARK: - The two ceilings

    func testTheForceDownCeilingOverridesABandThatWantsMoreSpeed() {
        // A band above the ceiling is what a wrong maximum produces. 168 bpm is
        // below this band (it argues for more speed) and above the 166 ceiling.
        let tooHigh = speedTarget(low: 170, high: 180)
        XCTAssertEqual(Governor.decide(input(tooHigh, heartRate: 168,
                                             command: speedCommand(8.0),
                                             tallies: Tallies(secondsAboveForceDownCeiling: 10))),
                       .adjust(command: speedCommand(7.8), reason: .ceilingForceDown))
    }

    func testTheForceDownCeilingIgnoresTheSettleWindowButNotTheEvaluationInterval() {
        let tallies = Tallies(secondsAboveForceDownCeiling: 12)
        // 20 s after the last change is inside the 45 s settle window: waiting at
        // 92% of maximum is not settling.
        XCTAssertEqual(Governor.decide(input(speedTarget(), heartRate: 168,
                                             command: speedCommand(8.0),
                                             sinceLastCommand: 20, tallies: tallies)),
                       .adjust(command: speedCommand(7.8), reason: .ceilingForceDown))
        // But it may not write twice inside one evaluation interval, however often
        // the caller happens to call.
        XCTAssertEqual(Governor.decide(input(speedTarget(), heartRate: 168,
                                             command: speedCommand(8.0),
                                             sinceLastCommand: 3, tallies: tallies)),
                       .hold(reason: .ceilingForceDown))
    }

    func testTheForceDownCeilingNeedsItsHoldWindow() {
        // Nine seconds over the ceiling is an artefact's length, not a workout's.
        XCTAssertEqual(Governor.decide(input(speedTarget(), heartRate: 168,
                                             command: speedCommand(8.0),
                                             tallies: Tallies(secondsAboveForceDownCeiling: 9))),
                       .adjust(command: speedCommand(7.8), reason: .aboveBand))
    }

    // MARK: - A brake is not bounded by the segment's corridor (finding 97)

    func testTheForceDownGoesBelowTheSegmentsOwnFloor() {
        // The segment's floor is the user's statement about where they want to
        // train, not a floor under the brakes. This used to be rejected by the
        // bounds check while the decision still said "ceiling", so the dashboard
        // reported the app slowing down while nothing was sent.
        XCTAssertEqual(Governor.decide(input(speedTarget(min: 4), heartRate: 168,
                                             command: speedCommand(4.0),
                                             tallies: Tallies(secondsAboveForceDownCeiling: 30))),
                       .adjust(command: speedCommand(3.8), reason: .ceilingForceDown))
    }

    func testAConsoleDialledBelowAnEightToTenCorridorStillGetsItsForceDown() {
        // The finding's own reproduction, with no malformed data anywhere: an
        // 8–10 km/h segment whose user has dialled the console down to 6.
        let dialledDown = input(speedTarget(min: 8, max: 10), heartRate: 168,
                                command: speedCommand(6.0),
                                lastChange: Change.settled(at: speedCommand(9.0)),
                                belt: belt(measured: speedCommand(6.0)),
                                tallies: Tallies(secondsAboveForceDownCeiling: 30))
        XCTAssertEqual(Governor.decide(dialledDown),
                       .adjust(command: speedCommand(5.8), reason: .ceilingForceDown))
    }

    func testAtTheDeviceMinimumTheCeilingHoldsAndSaysSo() {
        // The one honest hold left: there is nothing below the slowest the machine
        // runs, so the rule is standing with nothing left to take off.
        XCTAssertEqual(Governor.decide(input(speedTarget(min: 4), heartRate: 168,
                                             command: speedCommand(limits.minSpeedKmh),
                                             tallies: Tallies(secondsAboveForceDownCeiling: 30))),
                       .hold(reason: .ceilingForceDown))
    }

    func testABrakeOutOfRoomOnItsOwnAxisTakesTheLoadOffTheOtherOne() {
        // Finding 112. An incline-actuated segment whose incline is already at the
        // flattest the machine does: the force-down used to become a permanent
        // no-op there, holding for the rest of the segment while the dashboard went
        // on reporting that the app was slowing the belt down. A brake that has run
        // out of room on one axis has not run out of options.
        let atTheFloor = input(inclineTarget(minLevel: 0, maxLevel: 6), heartRate: 168,
                               command: speedCommand(6.0, incline: limits.minIncline),
                               tallies: Tallies(secondsAboveForceDownCeiling: 30))
        XCTAssertEqual(Governor.decide(atTheFloor),
                       .adjust(command: speedCommand(5.8, incline: limits.minIncline),
                               reason: .ceilingForceDown))
        // It crosses only when there is nothing left on its own axis: with a level
        // to give, the incline is what comes down and the speed is left alone.
        XCTAssertEqual(Governor.decide(input(inclineTarget(minLevel: 0, maxLevel: 6),
                                             heartRate: 168,
                                             command: speedCommand(6.0, incline: 3),
                                             tallies: Tallies(secondsAboveForceDownCeiling: 30))),
                       .adjust(command: speedCommand(6.0, incline: 2),
                               reason: .ceilingForceDown))
        // The step it crosses with is bounded by the device and not by the segment:
        // this segment's corridor is 6.0…6.0 km/h, and a brake is not bounded by
        // the corridor it is braking inside.
        XCTAssertEqual(Governor.speedBounds(for: inclineTarget(), limits: limits), 6.0...6.0)
    }

    func testWithBothAxesAtTheMachinesFloorTheCeilingHoldsAndSaysSo() {
        // The one honest hold left after finding 112: nothing anywhere to take off.
        var floored = inclineTarget(minLevel: 0, maxLevel: 6)
        floored.minSpeedKmh = limits.minSpeedKmh
        floored.maxSpeedKmh = limits.minSpeedKmh
        XCTAssertEqual(Governor.decide(input(floored, heartRate: 168,
                                             command: speedCommand(limits.minSpeedKmh,
                                                                   incline: limits.minIncline),
                                             tallies: Tallies(secondsAboveForceDownCeiling: 30))),
                       .hold(reason: .ceilingForceDown))
    }

    func testTheBandLawIsStillBoundedByTheSegmentsCorridor() {
        // Only the brakes changed. A reduction the *band* asks for stops at the
        // corridor the user set, because that is what a corridor is for.
        XCTAssertEqual(Governor.decide(input(speedTarget(min: 4), heartRate: 174,
                                             command: speedCommand(4.0))),
                       .hold(reason: .atBound))
    }

    func testTheStopCeilingEndsTheWorkout() {
        XCTAssertEqual(Governor.decide(input(speedTarget(), heartRate: 176,
                                             command: speedCommand(8.0),
                                             tallies: Tallies(secondsAboveForceDownCeiling: 30,
                                                              secondsAboveStopCeiling: 15))),
                       .emergencyStop)
        // Fourteen seconds is not fifteen.
        XCTAssertEqual(Governor.decide(input(speedTarget(), heartRate: 176,
                                             command: speedCommand(8.0),
                                             tallies: Tallies(secondsAboveForceDownCeiling: 30,
                                                              secondsAboveStopCeiling: 14))),
                       .adjust(command: speedCommand(7.8), reason: .ceilingForceDown))
    }

    // MARK: - The stall rule (an unreachable band)

    func testAtTheUpperBoundBelowTheBandItGivesUpRatherThanPushing() {
        // The 55-year-old on a beta-blocker from the specification: the band is a
        // number their heart cannot reach, and the ceilings derived from the same
        // estimate can never fire to stop the escalation.
        let tallies = Tallies(secondsAtUpperBoundBelowBand: 120)
        XCTAssertEqual(Governor.decide(input(speedTarget(max: 10), heartRate: 118,
                                             command: speedCommand(10.0), tallies: tallies)),
                       .hold(reason: .targetUnreachable))
    }

    func testTheStallRuleDoesNotFireWhileTheBandIsMerelySlowToArrive() {
        // Same two minutes below the band, but not yet at the bound: escalating is
        // exactly the right thing to keep doing.
        let tallies = Tallies(secondsAtUpperBoundBelowBand: 120)
        XCTAssertEqual(Governor.decide(input(speedTarget(max: 10), heartRate: 118,
                                             command: speedCommand(8.0), tallies: tallies)),
                       .adjust(command: speedCommand(8.2), reason: .belowBand))
        // And at the bound before the window has run out it holds at the bound,
        // which is a different state from having given up.
        XCTAssertEqual(Governor.decide(input(speedTarget(max: 10), heartRate: 118,
                                             command: speedCommand(10.0),
                                             tallies: Tallies(secondsAtUpperBoundBelowBand: 119))),
                       .hold(reason: .atBound))
    }

    func testTheStallRuleAppliesToTheInclineActuatorToo() {
        XCTAssertEqual(Governor.decide(input(inclineTarget(maxLevel: 6), heartRate: 118,
                                             command: speedCommand(6.0, incline: 6),
                                             tallies: Tallies(secondsAtUpperBoundBelowBand: 120))),
                       .hold(reason: .targetUnreachable))
    }

    // MARK: - Manual intervention

    // Whether a dial was turned is fact 3, inferred by
    // `ConsoleDialDetector` in the client from the measured values — its own
    // tests live in `FitShowProtocolTests`. What is asserted here is what the
    // ladder does once that fact arrives, which is the half the three rounds of
    // blockers were about: the governor used to *derive* this from the client's
    // target field, and every corridor, latch and dead band it took to make that
    // work blinded the axis it was protecting.

    func testAManualChangeHandsControlBackAndBeatsTheBand() {
        // 130 bpm argues loudly for more speed; the user has dialled the belt
        // down to 5.0, and the governor does not push back.
        XCTAssertEqual(Governor.decide(input(speedTarget(), heartRate: 130,
                                             command: speedCommand(5.0),
                                             lastChange: Change.settled(at: speedCommand(8.2)),
                                             belt: belt(measured: speedCommand(5.0),
                                                        speedByHand: true))),
                       .manualControl)
    }

    func testAChangeOnTheAxisTheGovernorDoesNotDriveHandsControlBackToo() {
        // The incline axis of a speed-actuated segment, which the deleted incline
        // dead band made completely blind: one level away from the app's target
        // was invisible for ever, because the condition was not time-based
        // (finding 75).
        XCTAssertEqual(Governor.decide(input(speedTarget(), heartRate: 130,
                                             command: speedCommand(8.0, incline: 3),
                                             belt: belt(measured: speedCommand(8.0, incline: 3),
                                                        inclineByHand: true))),
                       .manualControl)
    }

    func testAHandBackDoesNotSurrenderTheCeilings() {
        // The only automatic write left after a hand-back is a reduction the 92%
        // ceiling demands, and the stop. Both are cheaper than the alternative:
        // leaving the person on a belt until the 97% rule ends the workout.
        //
        // The user has dialled the belt up, to 12.0 and to 9.0. A reduction is
        // measured from the app's own last write and may never come out above it,
        // so both land one step under 8.2 rather than one step under the user's
        // number: a "reduction" that leaves the belt faster than the app itself
        // asked for is the failure this release found in the ceiling.
        let change = Change(from: speedCommand(8.0), to: speedCommand(8.2))
        for dialled in [12.0, 9.0] {
            XCTAssertEqual(Governor.decide(input(speedTarget(max: 10), heartRate: 168,
                                                 command: speedCommand(dialled),
                                                 lastChange: change,
                                                 belt: belt(measured: speedCommand(dialled),
                                                            speedByHand: true),
                                                 tallies: Tallies(secondsAboveForceDownCeiling: 10))),
                           .adjust(command: speedCommand(8.0), reason: .ceilingForceDown),
                           "dialled up to \(dialled)")
        }
        XCTAssertEqual(Governor.decide(input(speedTarget(), heartRate: 176,
                                             command: speedCommand(12.0),
                                             lastChange: change,
                                             belt: belt(measured: speedCommand(12.0),
                                                        speedByHand: true),
                                             tallies: Tallies(secondsAboveStopCeiling: 15))),
                       .emergencyStop)
    }

    func testAHandBackSuppressesTheBoundsCorrectionButNotTheFallback() {
        // The bounds correction would change a speed the user chose by hand and is
        // not answering evidence about their heart, so it goes.
        let change = Change(from: speedCommand(8.0), to: speedCommand(8.2))
        XCTAssertEqual(Governor.decide(input(speedTarget(max: 10), heartRate: 150,
                                             command: speedCommand(12.0),
                                             lastChange: change,
                                             belt: belt(measured: speedCommand(12.0),
                                                        speedByHand: true))),
                       .manualControl)
        // The fallback stays, for the same reason the two ceilings do: it can only
        // restate or lower the load, so it cannot do the thing the hand-back rule
        // exists to prevent — and a *falsely* inferred person used to disable the
        // one rule that answers a dead feed (finding 98).
        XCTAssertEqual(Governor.decide(input(speedTarget(fallback: 4.5), heartRate: 0,
                                             command: speedCommand(11.0),
                                             lastChange: change,
                                             belt: belt(measured: speedCommand(11.0),
                                                        speedByHand: true),
                                             tallies: Tallies(secondsWithoutHeartRate: 300))),
                       .fallback(command: speedCommand(4.5)))
    }

    func testTheFallbackUnderAHandBackIsStillNeverAnAcceleration() {
        // It runs under a hand-back, but it is still measured from
        // `min(fact 1, fact 2)`: a fallback above that is not sent at all.
        XCTAssertEqual(Governor.decide(input(speedTarget(fallback: 9.0), heartRate: 0,
                                             command: speedCommand(5.0),
                                             belt: belt(measured: speedCommand(5.0),
                                                        speedByHand: true),
                                             tallies: Tallies(secondsWithoutHeartRate: 300))),
                       .frozen)
    }

    func testABeltTrackingItsOwnCommandIsNeverAPerson() {
        // The whole point of taking the inference out of the target field: a belt
        // on its way to the app's own command, at any point on that way, is not a
        // person — and nothing here has to reason about corridors to say so.
        let entry = Change(from: speedCommand(12.0), to: speedCommand(4.0))
        for onTheWay in [12.0, 7.3, 4.1, 4.0] {
            let candidate = input(speedTarget(min: 4, max: 10), heartRate: 150,
                                  command: speedCommand(onTheWay), lastChange: entry,
                                  belt: belt(measured: speedCommand(onTheWay)))
            XCTAssertFalse(Governor.isManualIntervention(candidate), "\(onTheWay) km/h")
        }
    }

    // MARK: - Every command is one step from the belt, never from memory

    func testAnIncreaseStepsFromTheBeltAndNotFromTheAppsOwnMemory() {
        // **Inverted from the rung this replaces.** The old law refused to climb at
        // all while the actuated axis had not reached the app's command, because a
        // ramp and a person are the same picture — and that refusal was the last
        // piece of machinery whose only job was to classify a difference of a
        // quantum or two. The spec's answer is simpler and needs no classification:
        // the step is measured from `min(fact 1, fact 2)`, so a belt at 6.0 under a
        // command of 8.0 is climbed *from 6.0*. Nothing compounds: the loop never
        // commands from memory, so a person holding the belt at 6.0 keeps their 6.0
        // plus at most one step per evaluation, and a decisive change hands control
        // back outright.
        let below = belt(measured: speedCommand(6.0))
        XCTAssertEqual(Governor.decide(input(speedTarget(min: 4, max: 10), heartRate: 130,
                                             command: speedCommand(8.0),
                                             lastChange: .settled(at: speedCommand(8.0)),
                                             belt: below)),
                       .adjust(command: speedCommand(6.2), reason: .belowBand),
                       "one step from the belt, not 8.2 from the app's memory")
        // A reduction is measured from the same reference, so it cannot compound
        // anything either.
        XCTAssertEqual(Governor.decide(input(speedTarget(min: 4, max: 10), heartRate: 170,
                                             command: speedCommand(8.0),
                                             lastChange: .settled(at: speedCommand(8.0)),
                                             belt: below)),
                       .adjust(command: speedCommand(5.8), reason: .aboveBand))
        // And with the belt where the app asked, the step is from there.
        XCTAssertEqual(Governor.decide(input(speedTarget(min: 4, max: 10), heartRate: 130,
                                             command: speedCommand(8.0),
                                             lastChange: .settled(at: speedCommand(8.0)),
                                             belt: belt(measured: speedCommand(8.0)))),
                       .adjust(command: speedCommand(8.2), reason: .belowBand))
    }

    func testTheOtherAxisBeingBelowFactOneDoesNotStopTheActuatedOneClimbing() {
        // Per axis, because a speed segment whose incline is lagging its command
        // would otherwise never climb — and the lagging incline is restated at the
        // reference, which is where the belt is.
        XCTAssertEqual(Governor.decide(input(speedTarget(min: 4, max: 10), heartRate: 130,
                                             command: speedCommand(8.0, incline: 4),
                                             lastChange: .settled(at: speedCommand(8.0,
                                                                                   incline: 4)),
                                             belt: belt(measured: speedCommand(8.0,
                                                                               incline: 2)))),
                       .adjust(command: speedCommand(8.2, incline: 2), reason: .belowBand))
    }

    // MARK: - The client's target is an observation, not a record

    /// `FitShowTreadmillClient.reconcileTargets` re-points `targetSpeedKmh` at
    /// the belt's *measured* value once the app's own last command is more than
    /// ten seconds old — including while the belt is still travelling toward that
    /// command. Every reduction used to be computed from that number.
    func testAForcedReductionCannotHaltADecelerationTheAppItselfOrdered() {
        // The report's own reproduction: a recovery segment entered at 4.0 km/h
        // from 12, bounds 4…8, band 110…120, so the ceiling tally is already full
        // from the previous effort. At t = 10.2 s the client's target reads the
        // belt's measured 6.8, and a step down from 6.8 commands 6.6 to a belt the
        // app had already told to go to 4.0 — the safety rule accelerating the
        // belt relative to the app's own intent.
        let recovery = HeartRateTarget(lowBpm: 110, highBpm: 120, actuator: .speed,
                                       startSpeedKmh: 4.0, startIncline: 0,
                                       minSpeedKmh: 4.0, maxSpeedKmh: 8.0,
                                       minIncline: 0, maxIncline: 0, fallbackSpeedKmh: 4.0)
        // It steps *down* from the app's own 4.0 — the brake is bounded by the
        // machine and not by the segment's 4.0 floor (finding 97) — and the one
        // thing it may never do is come out above the 4.0 the app itself ordered.
        let entry = Change(from: speedCommand(12.0), to: speedCommand(4.0))
        XCTAssertEqual(Governor.decide(input(recovery, heartRate: 170,
                                             command: speedCommand(6.8), lastChange: entry,
                                             sinceSegmentStart: 10.2, sinceLastCommand: 10.2,
                                             tallies: Tallies(secondsAboveForceDownCeiling: 10))),
                       .adjust(command: speedCommand(3.8), reason: .ceilingForceDown),
                       "the reduction steps down from the app's own command, it does not raise it")
        // And the corridor makes no difference to it either way, which is the whole
        // of "a brake is not bounded by the segment's corridor".
        var lower = recovery
        lower.minSpeedKmh = 2.0
        XCTAssertEqual(Governor.decide(input(lower, heartRate: 170,
                                             command: speedCommand(6.8), lastChange: entry,
                                             sinceSegmentStart: 10.2, sinceLastCommand: 10.2,
                                             tallies: Tallies(secondsAboveForceDownCeiling: 10))),
                       .adjust(command: speedCommand(3.8), reason: .ceilingForceDown))
    }

    func testTheFallbackAndTheBoundsCorrectionReadTheSameRecord() {
        // Both are reductions and both used to start from the client's target.
        let entry = Change(from: speedCommand(12.0), to: speedCommand(4.0))
        // A declared fallback of 6.0 is above the app's own last write, so a lost
        // feed may not raise the belt to it — however fast the console says the
        // belt currently is.
        XCTAssertEqual(Governor.decide(input(speedTarget(min: 4, max: 8, fallback: 6.0),
                                             heartRate: 0, command: speedCommand(6.8),
                                             lastChange: entry,
                                             tallies: Tallies(secondsWithoutHeartRate: 30))),
                       .fallback(command: speedCommand(4.0)))
        // The bounds correction fires on what the app commanded, not on what the
        // belt happens to be doing: 9.0 is above this segment's 8.0 ceiling but
        // the app's own write is 4.0, so there is nothing to correct.
        XCTAssertEqual(Governor.decide(input(speedTarget(low: 110, high: 120, min: 4, max: 8),
                                             heartRate: 115, command: speedCommand(9.0),
                                             lastChange: entry)),
                       .hold(reason: .insideBand))
    }

    func testAnIncreaseIsAlsoMeasuredFromTheAppsOwnLastWrite() {
        // The band wants more speed while the belt is still coming down from the
        // previous segment, so the client's target reads higher than the app's own
        // command. One step from the console's 6.8 would compound a number the app
        // never chose; one step from the app's own 4.0 does not.
        let entry = Change(from: speedCommand(12.0), to: speedCommand(4.0))
        XCTAssertEqual(Governor.decide(input(speedTarget(min: 4, max: 10), heartRate: 130,
                                             command: speedCommand(6.8), lastChange: entry)),
                       .adjust(command: speedCommand(4.2), reason: .belowBand))
    }

    // MARK: - The reference: min(fact 1, fact 2), both axes, no exception

    func testTheReferenceIsTheLowerOfTheAppsCommandAndTheMeasuredBelt() {
        // Fact 1 is 8.0 and the belt is measured at 5.0 — the user dialled it
        // down, or the belt is still coming down from a previous segment. Either
        // way the governor believes the lower number at once, and it can never be
        // talked above its own command.
        let change = Change.settled(at: speedCommand(8.0))
        XCTAssertEqual(Governor.reference(command: speedCommand(8.0), lastAppliedChange: change,
                                          belt: belt(measured: speedCommand(5.0))),
                       speedCommand(5.0))
        XCTAssertEqual(Governor.reference(command: speedCommand(8.0), lastAppliedChange: change,
                                          belt: belt(measured: speedCommand(11.0))),
                       speedCommand(8.0))
        // Both axes, not only the actuated one.
        XCTAssertEqual(Governor.reference(command: speedCommand(8.0, incline: 6),
                                          lastAppliedChange: .settled(at: speedCommand(8.0,
                                                                                       incline: 6)),
                                          belt: belt(measured: speedCommand(9.0, incline: 2))),
                       speedCommand(8.0, incline: 2))
        // And every copy of fact 1 folds in the same direction, the live one
        // included: adding a term to a `min` can only lower it.
        let onSix = Change.settled(at: speedCommand(8.0, incline: 6))
        XCTAssertEqual(Governor.reference(command: speedCommand(8.0, incline: 6),
                                          lastAppliedChange: onSix,
                                          appCommand: speedCommand(5.0, incline: 2),
                                          belt: belt(measured: speedCommand(9.0, incline: 6))),
                       speedCommand(5.0, incline: 2))
        XCTAssertEqual(Governor.reference(command: speedCommand(8.0, incline: 6),
                                          lastAppliedChange: onSix,
                                          appCommand: speedCommand(12.0, incline: 9),
                                          belt: belt(measured: speedCommand(9.0, incline: 6))),
                       speedCommand(8.0, incline: 6))
    }

    func testTheReferenceIsInProtocolUnitsAtEverySpeedTheDeviceOffers() {
        // A speed rebuilt as `units / 10` and the same speed written as a literal
        // are not the same `Double`; a reference that compared them in km/h would
        // pick one of them at random. Both readings of every settable speed have
        // to come out as the same command.
        for units in TreadmillLimits().minSpeedRaw...TreadmillLimits().maxSpeedRaw {
            let asComputed = Double(units) / 10
            let asProduct = Double(units) * 0.1
            let reference = Governor.reference(
                command: Command(speedKmh: asProduct, incline: 0),
                lastAppliedChange: .settled(at: Command(speedKmh: asComputed, incline: 0)))
            XCTAssertEqual(Governor.speedUnits(reference.speedKmh), units, "\(units) tenths")
        }
    }

    func testTheAxisTheSegmentDoesNotSteerIsRestatedAtTheReference() {
        // Finding 74's reproduction: a hills program whose previous segment ran at
        // 10% incline hands over to a speed-actuated heart-rate segment starting at
        // 2%. The entry write sets 2%, the belt is still measured at 8% — and the
        // next force-down step, a reduction, used to take its pass-through axis from
        // that observation and command the 8% back up. A reduction may not
        // re-command load the app has cancelled, and `min(fact 1, fact 2)` is what
        // says so: fact 1 on that axis is the entry's own 2%.
        let entry = Change(from: speedCommand(9.0, incline: 10),
                           to: speedCommand(8.0, incline: 2))
        let lagging = belt(measured: speedCommand(8.0, incline: 8))
        XCTAssertEqual(Governor.decide(input(speedTarget(min: 4, max: 10), heartRate: 168,
                                             command: speedCommand(8.0, incline: 8),
                                             lastChange: entry, belt: lagging,
                                             tallies: Tallies(secondsAboveForceDownCeiling: 10))),
                       .adjust(command: speedCommand(7.8, incline: 2), reason: .ceilingForceDown))
        // The same for the fallback and the bounds correction, the other two
        // reductions that write both axes.
        XCTAssertEqual(Governor.decide(input(speedTarget(min: 4, max: 10, fallback: 4.5),
                                             heartRate: 0,
                                             command: speedCommand(8.0, incline: 8),
                                             lastChange: entry, belt: lagging,
                                             tallies: Tallies(secondsWithoutHeartRate: 30))),
                       .fallback(command: speedCommand(4.5, incline: 2)))
        XCTAssertEqual(Governor.decide(input(speedTarget(min: 4, max: 6), heartRate: 150,
                                             command: speedCommand(8.0, incline: 8),
                                             lastChange: entry, belt: lagging)),
                       .adjust(command: speedCommand(6.0, incline: 2), reason: .outOfBounds))
    }

    func testAnInclineSegmentRestatesTheSpeedAxisAtTheReferenceToo() {
        // The mirror image, so neither axis is special-cased.
        let entry = Change(from: speedCommand(12.0, incline: 0),
                           to: speedCommand(6.0, incline: 2))
        XCTAssertEqual(Governor.decide(input(inclineTarget(minLevel: 0, maxLevel: 6),
                                             heartRate: 168,
                                             command: speedCommand(9.4, incline: 2),
                                             lastChange: entry,
                                             belt: belt(measured: speedCommand(9.4, incline: 2)),
                                             tallies: Tallies(secondsAboveForceDownCeiling: 10))),
                       .adjust(command: speedCommand(6.0, incline: 1), reason: .ceilingForceDown))
    }

    func testNoBrakeRaisesTheAxisItIsNotSteering() {
        // Finding 111, both directions. The axis a rung does not move is restated at
        // `min(fact 1, fact 2)` — the user has dialled the console back and the
        // app's own command is stale, so restating fact 1 there would be an
        // acceleration on the axis nothing is braking, while the dashboard says
        // "slowing down".
        var inclineSegment = inclineTarget(minLevel: 0, maxLevel: 6)
        inclineSegment.minSpeedKmh = 10.0
        inclineSegment.maxSpeedKmh = 10.0
        var dialledDown = input(inclineSegment, heartRate: 168,
                                command: speedCommand(6.0, incline: 3),
                                lastChange: .settled(at: speedCommand(10.0, incline: 3)),
                                belt: belt(measured: speedCommand(6.0, incline: 3),
                                           speedByHand: true),
                                tallies: Tallies(secondsAboveForceDownCeiling: 10))
        dialledDown.appCommand = speedCommand(10.0, incline: 3)
        XCTAssertEqual(Governor.decide(dialledDown),
                       .adjust(command: speedCommand(6.0, incline: 2),
                               reason: .ceilingForceDown),
                       "the brake put the app's own 10.0 back over the user's 6.0")
        // The mirror image: a speed-actuated segment whose *incline* the user has
        // taken down by hand. A fallback is the other write that carries both axes.
        var speedSegment = speedTarget(min: 4, max: 10, fallback: 4.5)
        speedSegment.minIncline = 0
        speedSegment.maxIncline = 6
        var inclineByHand = input(speedSegment, heartRate: 0,
                                  command: speedCommand(8.0, incline: 2),
                                  lastChange: .settled(at: speedCommand(8.0, incline: 6)),
                                  belt: belt(measured: speedCommand(8.0, incline: 2),
                                             inclineByHand: true),
                                  tallies: Tallies(secondsWithoutHeartRate: 30))
        inclineByHand.appCommand = speedCommand(8.0, incline: 6)
        XCTAssertEqual(Governor.decide(inclineByHand),
                       .fallback(command: speedCommand(4.5, incline: 2)))
    }

    // MARK: - The reference rule has no exceptions (finding 124)

    func testABrakeLeavesAClimbingInclineWhereTheBeltHasGotTo() {
        // **The mandated inversion of finding 99's expectation.** This used to
        // assert that a fallback firing while an incline motor was still travelling
        // came out at the segment's own 8%, by taking the pass-through axis from
        // fact 1 alone while that axis was travelling. The spec now forbids the
        // exception and records the consequence: "a brake that fires while an
        // incline is still climbing leaves the incline where the belt had got to,
        // instead of completing the climb. That is a segment doing less than it
        // said, which is safe; the exception was a brake making the belt go faster,
        // which is not." A person holding the belt away from the command is exactly
        // what keeps "travelling" true, so the window never closed.
        let entry = Change(from: speedCommand(6.0, incline: 2),
                           to: speedCommand(8.0, incline: 8))
        var target = speedTarget(min: 4, max: 10, fallback: 4.5)
        target.minIncline = 8
        target.maxIncline = 8
        target.startIncline = 8
        XCTAssertEqual(Governor.decide(input(target, heartRate: 0,
                                             command: speedCommand(8.0, incline: 8),
                                             lastChange: entry,
                                             belt: belt(measured: speedCommand(8.0, incline: 2)),
                                             tallies: Tallies(secondsWithoutHeartRate: 30))),
                       .fallback(command: speedCommand(4.5, incline: 2)))
    }

    func testLiveFactOneCanOnlyLowerTheReference() {
        // `Input.appCommand` is the client's own `commandedSpeedKmh`, which no
        // incoming frame may move. It is a third copy of fact 1 and it enters the
        // reference the way every other observation does — downward only.
        //
        // The case that needs it: the user presses the app's own "−" tile to 5.0,
        // then dials the *console* back up to 8.0. Past the client's hold-off its
        // target follows the belt, so `command` reads 8.0 again and the runner's
        // record of its own last write never came down at all — the client's live
        // command is the only copy that did.
        let change = Change.settled(at: speedCommand(8.0, incline: 6))
        var candidate = input(speedTarget(min: 4, max: 10, fallback: 4.5), heartRate: 0,
                              command: speedCommand(8.0, incline: 6),
                              lastChange: change,
                              belt: belt(measured: speedCommand(8.0, incline: 6)),
                              tallies: Tallies(secondsWithoutHeartRate: 300))
        XCTAssertEqual(Governor.decide(candidate),
                       .fallback(command: speedCommand(4.5, incline: 6)))
        candidate.appCommand = speedCommand(5.0, incline: 2)
        XCTAssertEqual(Governor.decide(candidate),
                       .fallback(command: speedCommand(4.5, incline: 2)),
                       "the axis it does not steer came out above the app's live command")
        // And it cannot raise it: a live command above the other copies changes
        // nothing, because a `min` is a `min`.
        candidate.appCommand = speedCommand(12.0, incline: 9)
        XCTAssertEqual(Governor.decide(candidate),
                       .fallback(command: speedCommand(4.5, incline: 6)))
    }

    // MARK: - One step means one step

    func testAnUpwardStepIsNeverALeapToReachABound() {
        // A start command below the segment's own floor: the raw step is 3.2, and
        // clamping *the result* into 8.0…10.0 turned that into one 5 km/h
        // acceleration arrived at by adding 0.2. Clamping the step's magnitude
        // means it stays put instead — and `isUsable` now refuses the payload
        // outright, so this is the second of two locks on the same door.
        XCTAssertEqual(Governor.decide(input(speedTarget(min: 8.0, max: 10.0), heartRate: 130,
                                             command: speedCommand(3.0))),
                       .hold(reason: .atBound))
        XCTAssertEqual(Governor.decide(input(inclineTarget(minLevel: 4, maxLevel: 6),
                                             heartRate: 130,
                                             command: speedCommand(6.0, incline: 0))),
                       .hold(reason: .atBound))
    }

    func testAStartCommandOutsideItsOwnBoundsIsNotAUsablePayload() {
        // `isUsable` is the gate the runner reads, and a target that fails it runs
        // as a fixed segment at its start command. It used to check the band and
        // that the bounds had room for one step, and nothing else: a stored start
        // of 3.0 with an 8.0…10.0 corridor passed as steerable.
        var outside = speedTarget(min: 8.0, max: 10.0)
        outside.startSpeedKmh = 3.0
        XCTAssertFalse(outside.isUsable)
        outside.startSpeedKmh = 9.0
        XCTAssertTrue(outside.isUsable)

        // Bounds the machine cannot represent are refused for the same reason.
        var offMachine = speedTarget()
        offMachine.maxSpeedKmh = 30.0
        XCTAssertFalse(offMachine.isUsable)
        offMachine = speedTarget()
        offMachine.minSpeedKmh = 0.1
        XCTAssertFalse(offMachine.isUsable)

        // The actuated axis is the one that has to contain the start command; the
        // other axis being pinned elsewhere is still irrelevant.
        var inclineOutside = inclineTarget(minLevel: 3, maxLevel: 6)
        inclineOutside.startIncline = 0
        XCTAssertFalse(inclineOutside.isUsable)
        inclineOutside.startIncline = 4
        XCTAssertTrue(inclineOutside.isUsable)

        // Whether a payload is usable may not depend on which of the two ways of
        // writing a tenth of a km/h the stored bounds happen to hold: the checks
        // are in protocol units, so `82 * 0.1` and `8.2` are the same payload.
        var offGrid = speedTarget(min: 4.0, max: 10.0)
        offGrid.startSpeedKmh = 82 * 0.1
        offGrid.minSpeedKmh = 82 * 0.1
        offGrid.maxSpeedKmh = 100 * 0.1
        XCTAssertTrue(offGrid.isUsable)
        // One quantum of room is enough, and less than one is not.
        var pinned = offGrid
        pinned.maxSpeedKmh = 82 * 0.1
        XCTAssertFalse(pinned.isUsable)
        pinned.maxSpeedKmh = 83 * 0.1
        XCTAssertTrue(pinned.isUsable)

        // And a seeded target is always usable — the editor's own repair path
        // depends on it.
        for start in [0.8, 3.0, 8.0, 16.0] {
            for actuator in HeartRateActuator.allCases {
                XCTAssertTrue(HeartRateTarget.seeded(startSpeedKmh: start, startIncline: 0,
                                                     actuator: actuator).isUsable,
                              "\(start) \(actuator)")
            }
        }
    }

    // MARK: - A band above the force-down ceiling

    func testABandAtOrAboveTheForceDownCeilingIsNotSteerable() {
        // Karvonen bands are bpm on the heart-rate *reserve*, the ceilings a share
        // of the *maximum*, and they collide at the top: on this suite's own
        // reference basis zone 5 is 168…180 while the force-down ceiling is 166.
        XCTAssertEqual(Governor.arbitration(for: speedTarget(low: 168, high: 180), basis: basis),
                       .notSteerable)
        // Zone 4's upper edge crosses the ceiling: clamped under it, not refused.
        XCTAssertEqual(Governor.arbitration(for: speedTarget(low: 156, high: 168), basis: basis),
                       .clamped(156...165))
        XCTAssertEqual(Governor.arbitration(for: speedTarget(), basis: basis),
                       .steerable(144...155))
        // What the editor may offer, so a user cannot ask for the first case.
        XCTAssertEqual(Governor.holdableBandRangeBpm(for: basis).upperBound, 165)
        XCTAssertEqual(Governor.holdableBandRangeBpm(for: basis).lowerBound,
                       HeartRateTarget.bandRangeBpm.lowerBound)
    }

    func testAnUnsteerableBandRunsFixedInsteadOfSawtoothingAtTheCeiling() {
        let zone5 = speedTarget(low: 168, high: 180)
        // 160 bpm is below the band and argues for more speed; the old ladder
        // stepped up, the ceiling then stepped down, and the loop held the user at
        // 92% of maximum for the whole segment.
        XCTAssertEqual(Governor.decide(input(zone5, heartRate: 160, command: speedCommand(8.0))),
                       .hold(reason: .bandNotSteerable))
        XCTAssertEqual(Governor.decide(input(zone5, heartRate: 120, command: speedCommand(8.0))),
                       .hold(reason: .bandNotSteerable))
        // The ceilings are above this rung and they only ever reduce, so they
        // still act.
        XCTAssertEqual(Governor.decide(input(zone5, heartRate: 168, command: speedCommand(8.0),
                                             tallies: Tallies(secondsAboveForceDownCeiling: 10))),
                       .adjust(command: speedCommand(7.8), reason: .ceilingForceDown))
        XCTAssertEqual(Governor.decide(input(zone5, heartRate: 176, command: speedCommand(8.0),
                                             tallies: Tallies(secondsAboveStopCeiling: 15))),
                       .emergencyStop)
    }

    func testAClampedBandIsHeldBelowTheCeilingRatherThanChasedThroughIt() {
        let zone4 = speedTarget(low: 156, high: 168)
        // 166 is inside the band the user asked for and above the one the governor
        // is allowed to hold, so it reduces instead of holding.
        XCTAssertEqual(Governor.decide(input(zone4, heartRate: 166, command: speedCommand(8.0))),
                       .adjust(command: speedCommand(7.9), reason: .aboveBand))
        XCTAssertEqual(Governor.decide(input(zone4, heartRate: 160, command: speedCommand(8.0))),
                       .hold(reason: .insideBand))
    }

    func testTheStallRuleFiresOnTheForceDownWhileBelowBandSignature() {
        // A band whose floor sits just under the ceiling is not clamped and not
        // refused, and it still sawtooths: the ceiling pulls the load back, the
        // band rung pushes it up again. Two minutes below the band after the
        // ceiling has already had to intervene is the same evidence as two
        // minutes at the upper bound.
        let target = speedTarget(low: 160, high: 165, min: 4, max: 10)
        XCTAssertEqual(Governor.decide(input(target, heartRate: 155, command: speedCommand(8.0),
                                             tallies: Tallies(didForceDown: true,
                                                              secondsBelowBandAfterForceDown: 120))),
                       .hold(reason: .targetUnreachable))
        // Not before the window is full, and not without the ceiling having fired.
        XCTAssertEqual(Governor.decide(input(target, heartRate: 155, command: speedCommand(8.0),
                                             tallies: Tallies(didForceDown: true,
                                                              secondsBelowBandAfterForceDown: 119))),
                       .adjust(command: speedCommand(8.1), reason: .belowBand))
        XCTAssertEqual(Governor.decide(input(target, heartRate: 155, command: speedCommand(8.0),
                                             tallies: Tallies(secondsBelowBandAfterForceDown: 300))),
                       .adjust(command: speedCommand(8.1), reason: .belowBand))
    }

    func testTheForceDownSignatureLatchesAndThenCountsTimeBelowTheBand() {
        let ceilings = Governor.ceilings(for: basis) // 166 / 175
        var tallies = Tallies()
        for _ in 0..<10 {
            tallies = tallies.advanced(bySeconds: 1, heartRate: 168, ceilings: ceilings,
                                       band: 160...165, isAtUpperBound: false)
        }
        XCTAssertTrue(tallies.didForceDown, "ten seconds over the ceiling is the rung's own test")
        XCTAssertEqual(tallies.secondsBelowBandAfterForceDown, 0, "168 is above the band")
        for _ in 0..<30 {
            tallies = tallies.advanced(bySeconds: 1, heartRate: 155, ceilings: ceilings,
                                       band: 160...165, isAtUpperBound: false)
        }
        // The ceiling tally itself has reset; the fact that it fired has not.
        XCTAssertEqual(tallies.secondsAboveForceDownCeiling, 0)
        XCTAssertEqual(tallies.secondsBelowBandAfterForceDown, 30)
        // And it does not reset on the next excursion: a sawtooth is made of
        // excursions, so resetting on each one would count nothing at all.
        tallies = tallies.advanced(bySeconds: 1, heartRate: 162, ceilings: ceilings,
                                   band: 160...165, isAtUpperBound: false)
        XCTAssertEqual(tallies.secondsBelowBandAfterForceDown, 30)
        XCTAssertTrue(tallies.didForceDown)
    }

    // MARK: - Precedence

    func testTheRuleLadderIsTheDocumentedOrder() {
        // Precedence is this list, not the order of statements in a function: if
        // a rung moves, this test says so.
        XCTAssertEqual(Governor.Rung.allCases, [
            .stopCeiling, .feedLostFallback, .forceDownCeiling, .manualControl,
            .outOfBoundsCorrection, .feedLostFreeze, .bandNotSteerable,
            .stalledAtUpperBound, .settling, .insideBand, .followBand,
        ])
    }

    func testAStaleReadingWithTheStopCeilingStandingStillStops() {
        // The worked example: the feed is gone and the last thing known was that
        // the user was over 97% of maximum for fifteen seconds. Silence is not
        // evidence of recovery, and stopping a belt is safe in both worlds.
        XCTAssertEqual(Governor.decide(input(speedTarget(), heartRate: 0,
                                             command: speedCommand(8.0),
                                             tallies: Tallies(secondsWithoutHeartRate: 20,
                                                              secondsAboveStopCeiling: 15))),
                       .emergencyStop)
    }

    func testAStaleReadingWithTheForceDownCeilingStandingReducesRatherThanFreezes() {
        // Freezing would hold a load already known to be too high.
        XCTAssertEqual(Governor.decide(input(speedTarget(), heartRate: 0,
                                             command: speedCommand(8.0),
                                             tallies: Tallies(secondsWithoutHeartRate: 20,
                                                              secondsAboveForceDownCeiling: 12))),
                       .adjust(command: speedCommand(7.8), reason: .ceilingForceDown))
    }

    func testPastTheFallbackWindowTheFallbackBeatsTheForceDownCeiling() {
        // Both point downward; the fallback is the more decisive of the two and it
        // is the rule the specification states for a feed that is simply gone.
        XCTAssertEqual(Governor.decide(input(speedTarget(fallback: 4.5), heartRate: 0,
                                             command: speedCommand(8.0),
                                             tallies: Tallies(secondsWithoutHeartRate: 30,
                                                              secondsAboveForceDownCeiling: 12))),
                       .fallback(command: speedCommand(4.5)))
    }

    func testTheCeilingBeatsAGivenUpStall() {
        // The second worked example: parked at the upper bound with the stall
        // window expired, and then the heart rate climbs into the ceiling band.
        let tallies = Tallies(secondsAboveForceDownCeiling: 10,
                              secondsAtUpperBoundBelowBand: 300)
        XCTAssertEqual(Governor.decide(input(speedTarget(max: 10), heartRate: 168,
                                             command: speedCommand(10.0), tallies: tallies)),
                       .adjust(command: speedCommand(9.8), reason: .ceilingForceDown))
    }

    func testAFrozenFeedBeatsTheStallAndTheSettleWindows() {
        XCTAssertEqual(Governor.decide(input(speedTarget(max: 10), heartRate: 0,
                                             command: speedCommand(10.0),
                                             sinceLastCommand: 5,
                                             tallies: Tallies(secondsWithoutHeartRate: 5,
                                                              secondsAtUpperBoundBelowBand: 300))),
                       .frozen)
    }

    // MARK: - The tallies

    func testAMissingReadingHoldsTheCeilingTalliesAndCountsTheGap() {
        let ceilings = Governor.ceilings(for: basis)
        let standing = Tallies(secondsWithoutHeartRate: 0,
                               secondsAboveForceDownCeiling: 8,
                               secondsAboveStopCeiling: 4,
                               secondsAtUpperBoundBelowBand: 30)
        let next = standing.advanced(bySeconds: 1, heartRate: 0, ceilings: ceilings,
                                     band: 144...155, isAtUpperBound: true)
        XCTAssertEqual(next.secondsWithoutHeartRate, 1)
        // Losing the feed is not evidence that the heart rate came down.
        XCTAssertEqual(next.secondsAboveForceDownCeiling, 8)
        XCTAssertEqual(next.secondsAboveStopCeiling, 4)
        XCTAssertEqual(next.secondsAtUpperBoundBelowBand, 30)
    }

    func testAFreshReadingBelowTheCeilingsResetsThem() {
        let ceilings = Governor.ceilings(for: basis)
        let standing = Tallies(secondsWithoutHeartRate: 20,
                               secondsAboveForceDownCeiling: 8,
                               secondsAboveStopCeiling: 4,
                               secondsAtUpperBoundBelowBand: 30)
        let next = standing.advanced(bySeconds: 1, heartRate: 150, ceilings: ceilings,
                                     band: 144...155, isAtUpperBound: true)
        XCTAssertEqual(next.secondsWithoutHeartRate, 0)
        XCTAssertEqual(next.secondsAboveForceDownCeiling, 0)
        XCTAssertEqual(next.secondsAboveStopCeiling, 0)
        // In the band, so not below it: the stall tally is about an unreachable
        // target, and this target has been reached.
        XCTAssertEqual(next.secondsAtUpperBoundBelowBand, 0)
    }

    func testTheCeilingTalliesAccumulateFromTheirOwnThresholds() {
        let ceilings = Governor.ceilings(for: basis) // 166 / 175
        var tallies = Tallies()
        // Ten seconds at 168: the force-down window is full, the stop one is not
        // counting at all.
        for _ in 0..<10 {
            tallies = tallies.advanced(bySeconds: 1, heartRate: 168, ceilings: ceilings,
                                       band: 144...155, isAtUpperBound: false)
        }
        XCTAssertEqual(tallies.secondsAboveForceDownCeiling, 10)
        XCTAssertEqual(tallies.secondsAboveStopCeiling, 0)
        for _ in 0..<15 {
            tallies = tallies.advanced(bySeconds: 1, heartRate: 176, ceilings: ceilings,
                                       band: 144...155, isAtUpperBound: false)
        }
        XCTAssertEqual(tallies.secondsAboveForceDownCeiling, 25)
        XCTAssertEqual(tallies.secondsAboveStopCeiling, 15)
    }

    func testTheStallTallyNeedsTheBoundAndTheBandTogether() {
        let ceilings = Governor.ceilings(for: basis)
        var tallies = Tallies(secondsAtUpperBoundBelowBand: 60)
        // Below the band but no longer at the bound: the escalation is live again.
        tallies = tallies.advanced(bySeconds: 1, heartRate: 118, ceilings: ceilings,
                                   band: 144...155, isAtUpperBound: false)
        XCTAssertEqual(tallies.secondsAtUpperBoundBelowBand, 0)
        tallies = tallies.advanced(bySeconds: 2, heartRate: 118, ceilings: ceilings,
                                   band: 144...155, isAtUpperBound: true)
        XCTAssertEqual(tallies.secondsAtUpperBoundBelowBand, 2)
    }

    func testTheStallTallyFillsUnderTheRealPredicateOnABiasedConsole() {
        // **The defect, at the tally.** The app is commanding the segment's own
        // bound and the console reports a tenth less than that for ever — the
        // spec's first named confusion. The flag used to be an exact test against
        // the reference, which carries that measurement, so it was false on every
        // tick, this loop counted nothing, and `.hold(reason: .targetUnreachable)`
        // was unreachable however long the segment ran.
        let target = speedTarget(min: 4, max: 10)
        let ceilings = Governor.ceilings(for: basis)
        let band = Governor.band(for: target)
        var tallies = Tallies()
        for _ in 0..<120 {
            tallies = tallies.advanced(
                bySeconds: 1, heartRate: 118, ceilings: ceilings, band: band,
                isAtUpperBound: Governor.isAtUpperBound(reference: speedCommand(9.9),
                                                        appCommand: speedCommand(10.0),
                                                        target: target, limits: limits))
        }
        XCTAssertEqual(tallies.secondsAtUpperBoundBelowBand,
                       Governor.stallWindowSeconds, accuracy: 0.0001)
        // And a belt more than one step below the bound is a belt somewhere else —
        // a segment entered from a slower one, a dial turned down — so the
        // escalation is live again and the tally resets, exactly as before.
        tallies = tallies.advanced(
            bySeconds: 1, heartRate: 118, ceilings: ceilings, band: band,
            isAtUpperBound: Governor.isAtUpperBound(reference: speedCommand(9.5),
                                                    appCommand: speedCommand(10.0),
                                                    target: target, limits: limits))
        XCTAssertEqual(tallies.secondsAtUpperBoundBelowBand, 0, accuracy: 0.0001)
    }

    func testANonsenseDeltaChangesNothing() {
        // A tick is not a second, and a measured delta can be zero or worse.
        let ceilings = Governor.ceilings(for: basis)
        let tallies = Tallies(secondsWithoutHeartRate: 5)
        for delta in [0.0, -1.0, Double.nan, .infinity] {
            XCTAssertEqual(tallies.advanced(bySeconds: delta, heartRate: 0, ceilings: ceilings,
                                            band: 144...155, isAtUpperBound: false),
                           tallies)
        }
    }

    // MARK: - Invariants over every input this suite can build

    /// The safety properties, asserted over a grid rather than one case at a
    /// time: the acceptance criteria are about what the governor can *never* do,
    /// and a single example cannot say that.
    func testTheSafetyInvariantsHoldForEveryCombinationOfInputs() {
        let targets = [speedTarget(), speedTarget(low: 170, high: 180),
                       speedTarget(low: 156, high: 168),
                       inclineTarget(), inclineTarget(minLevel: 1, maxLevel: 6)]
        let heartRates = [0, 90, 118, 143, 150, 158, 168, 176, 240]
        let commands = [speedCommand(3.0), speedCommand(4.0), speedCommand(6.0, incline: 0),
                        speedCommand(6.0, incline: 3), speedCommand(6.0, incline: 6),
                        speedCommand(10.0), speedCommand(12.0)]
        // The last three are the ones that matter: a client target that is *not*
        // the app's own last write, which is what the reconcile rule produces on
        // every segment entry and every incline move.
        let changes = [Change.settled(at: speedCommand(6.0)),
                       Change(from: speedCommand(6.0), to: speedCommand(6.2)),
                       Change(from: speedCommand(6.2), to: speedCommand(6.0)),
                       Change(from: speedCommand(12.0), to: speedCommand(4.0)),
                       Change(from: speedCommand(4.0, incline: 0),
                              to: speedCommand(4.0, incline: 4))]
        // Facts 2 and 3, including the belt measured above and below the app's own
        // command on each axis and a hand on either dial. There is no "travelling"
        // row any more: the reference is the minimum whether an actuator is
        // mid-journey or not, which is the property invariant 2 now asserts
        // unconditionally (finding 124).
        let belts = [Governor.BeltFacts.unobserved,
                     belt(measured: speedCommand(3.0, incline: 0)),
                     belt(measured: speedCommand(12.0, incline: 6)),
                     belt(measured: speedCommand(5.0, incline: 2)),
                     belt(measured: speedCommand(5.0, incline: 2), speedByHand: true),
                     belt(measured: speedCommand(7.0, incline: 5), inclineByHand: true)]
        // Live fact 1, the third copy: nil is the caller that does not supply it,
        // one below the other copies and one above. It has to be a dimension of the
        // grid and not a special case, because production always supplies it — a
        // pass-through taking fact 1 alone was invisible to this test while it did
        // not (finding 124).
        let appCommands = [nil, speedCommand(4.0, incline: 1), speedCommand(12.0, incline: 6)]
        let talliesGrid = [Tallies(),
                           Tallies(secondsWithoutHeartRate: 45),
                           Tallies(secondsAboveForceDownCeiling: 12),
                           Tallies(secondsAboveStopCeiling: 20),
                           Tallies(secondsAtUpperBoundBelowBand: 300),
                           Tallies(secondsWithoutHeartRate: 45,
                                   secondsAboveForceDownCeiling: 12),
                           Tallies(didForceDown: true, secondsBelowBandAfterForceDown: 300)]
        var checked = 0
        for target in targets {
            let speedBounds = Governor.speedBounds(for: target, limits: limits)
            let inclineBounds = Governor.inclineBounds(for: target, limits: limits)
            let band = Governor.band(for: target)
            for heartRate in heartRates {
                for command in commands {
                    for change in changes {
                        for beltFacts in belts {
                            for tallies in talliesGrid {
                                for seconds in [0.0, 12.0, 600.0] {
                                    for appCommand in appCommands {
                                        var candidate = input(target, heartRate: heartRate,
                                                              command: command,
                                                              lastChange: change,
                                                              belt: beltFacts,
                                                              sinceSegmentStart: seconds,
                                                              sinceLastCommand: seconds,
                                                              tallies: tallies)
                                        candidate.appCommand = appCommand
                                        assertInvariants(Governor.decide(candidate),
                                                         for: candidate,
                                                         speedBounds: speedBounds,
                                                         inclineBounds: inclineBounds,
                                                         band: band)
                                        checked += 1
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(checked, 5 * 9 * 7 * 5 * 6 * 7 * 3 * 3)
    }

    /// The actuated axis of a command, so an invariant can be stated once rather
    /// than once per axis.
    private func actuated(_ command: Command, _ actuator: HeartRateActuator) -> Double {
        actuator == .speed ? command.speedKmh : Double(command.incline)
    }

    private func passedThrough(_ command: Command, _ actuator: HeartRateActuator) -> Double {
        actuator == .speed ? Double(command.incline) : command.speedKmh
    }

    private func stepLimit(_ actuator: HeartRateActuator) -> Double {
        actuator == .speed ? Governor.maxSpeedStepKmh : Double(Governor.maxInclineStep)
    }

    private func assertInvariants(_ decision: Decision, for input: Governor.Input,
                                 speedBounds: ClosedRange<Double>,
                                 inclineBounds: ClosedRange<Int>,
                                 band: ClosedRange<Int>) {
        guard let commanded = commandedValue(of: decision) else { return }
        let actuator = input.target.actuator
        let label = "\(input.heartRate) bpm, target \(input.command), "
            + "wrote \(input.lastAppliedChange.to), belt \(input.belt), \(decision)"
        // The reference, and there is no second number: `min(fact 1, fact 2)` per
        // axis, on both axes, with no exception. Every invariant below is stated
        // against it, which is strictly stronger than the old statement against
        // fact 1 alone — the reference is never above fact 1.
        let reference = Governor.reference(command: input.command,
                                          lastAppliedChange: input.lastAppliedChange,
                                          appCommand: input.appCommand,
                                          belt: input.belt)
        let write = actuated(reference, actuator)
        let sent = actuated(commanded, actuator)

        // 1. The actuated axis is never outside the bounds that rung answers to,
        // and every decision answers to *some* bounds: the segment's corridor
        // intersected with the device for anything that steers, the device's own
        // limits for a brake. Splitting the invariant rather than dropping half of
        // it — a brake below the corridor's floor is the point of finding 97, and a
        // brake outside the machine's limits would still be a bug.
        let isBrake: Bool
        switch decision {
        case .fallback, .adjust(_, .ceilingForceDown): isBrake = true
        default: isBrake = false
        }
        let deviceSpeed = Governor.deviceSpeedBounds(input.limits)
        let deviceIncline = Governor.deviceInclineBounds(input.limits)
        switch actuator {
        case .speed:
            let bounds = isBrake ? deviceSpeed : speedBounds
            XCTAssertGreaterThanOrEqual(commanded.speedKmh, bounds.lowerBound - 0.0001, label)
            XCTAssertLessThanOrEqual(commanded.speedKmh, bounds.upperBound + 0.0001, label)
        case .incline:
            let bounds = isBrake ? deviceIncline : inclineBounds
            XCTAssertGreaterThanOrEqual(commanded.incline, bounds.lowerBound, label)
            XCTAssertLessThanOrEqual(commanded.incline, bounds.upperBound, label)
        }
        // And a brake never leaves the machine's own limits either way.
        XCTAssertGreaterThanOrEqual(commanded.speedKmh, deviceSpeed.lowerBound - 0.0001, label)
        XCTAssertLessThanOrEqual(commanded.speedKmh, deviceSpeed.upperBound + 0.0001, label)
        XCTAssertGreaterThanOrEqual(commanded.incline, deviceIncline.lowerBound, label)
        XCTAssertLessThanOrEqual(commanded.incline, deviceIncline.upperBound, label)

        // 2. **The axis the rung does not move is restated at the reference**, with
        // no exception on either axis: `min(fact 1, fact 2)` there as everywhere
        // else. Each half of the rule this replaces answered a blocker — fact 1
        // alone re-commanded the app's own value over a dial the user had turned
        // down, so a brake *accelerated* the axis it was not braking (finding 111);
        // the exception that kept fact 1 while an axis was travelling re-opened
        // exactly that path, because a person holding the belt away from the command
        // is what keeps travelling true (finding 124).
        //
        // A brake may go one step *below* that value on this axis, and only a
        // brake: when the actuated axis has run out of room at the machine's own
        // bound, the load comes off the other one instead (finding 112).
        let passAxis = actuator.other
        let expectedPassThrough = passedThrough(reference, actuator)
        let passThroughSent = passedThrough(commanded, actuator)
        XCTAssertLessThanOrEqual(passThroughSent, expectedPassThrough + 0.0001, label)
        let isCrossAxisBrake = isBrake
            && abs(sent - actuated(reference, actuator)) < 0.0001
            && abs(passThroughSent - expectedPassThrough) >= 0.0001
        if isCrossAxisBrake {
            XCTAssertGreaterThanOrEqual(passThroughSent,
                                        expectedPassThrough - stepLimit(passAxis) - 0.0001, label)
        } else {
            XCTAssertEqual(passThroughSent, expectedPassThrough, accuracy: 0.0001, label)
        }

        // 3. A command that would change nothing and re-state nothing is never
        // sent: a pointlessly re-written target is the failure mode this release
        // keeps finding. Judged on the axis the rung actually moved — a cross-axis
        // brake is a real reduction on the axis it crossed to.
        let observed = max(actuated(input.command, actuator),
                           input.belt.measured.map { actuated($0, actuator) } ?? -.infinity)
        if abs(sent - actuated(reference, actuator)) < 0.0001, !isCrossAxisBrake {
            XCTAssertGreaterThan(observed, actuated(reference, actuator) + 0.0001, label)
        }

        // 4. Nothing raises the load above the reference — the only number that
        // means anything — except a fresh reading below the band, with no ceiling
        // standing and no hand-back in force. And then by one step and no more.
        // Stated against the reference rather than fact 1, which is a tightening:
        // the reference is never above fact 1, so this also forbids the step from
        // memory that fact 1 alone would have allowed.
        let raisesLoad = sent > write + 0.0001
        if raisesLoad {
            XCTAssertGreaterThan(input.heartRate, 0, label)
            XCTAssertLessThan(input.heartRate, band.lowerBound, label)
            XCTAssertLessThan(input.tallies.secondsAboveForceDownCeiling,
                              Governor.forceDownHoldSeconds, label)
            XCTAssertLessThan(input.tallies.secondsAboveStopCeiling,
                              Governor.stopHoldSeconds, label)
            XCTAssertFalse(Governor.isManualIntervention(input), label)
            XCTAssertLessThanOrEqual(sent, write + stepLimit(actuator) + 0.0001, label)
            if case .adjust(_, .belowBand) = decision {} else {
                XCTFail("only a band-following increase may raise the load: " + label)
            }
        }

        // 5. **No brake may raise either axis, under any input.** Both axes, not
        // only the actuated one, and against the reference: an observation may lower
        // it and never raise it, so a "reduction" can no longer come out above the
        // app's own intent and cancel a deceleration the app ordered.
        switch decision {
        case .fallback, .adjust(_, .ceilingForceDown), .adjust(_, .outOfBounds),
             .adjust(_, .aboveBand):
            XCTAssertLessThanOrEqual(sent, write + 0.0001, label)
            XCTAssertLessThanOrEqual(passThroughSent, expectedPassThrough + 0.0001, label)
            XCTAssertLessThanOrEqual(commanded.speedKmh, reference.speedKmh + 0.0001, label)
            XCTAssertLessThanOrEqual(commanded.incline, reference.incline, label)
        default:
            break
        }

        // 6. Every band-following and ceiling step is inside the step limit,
        // measured from the reference it started at, as long as that reference is
        // itself legal. The exceptions are the fallback and the bounds
        // correction, and both only ever reduce.
        let referenceValue = actuated(reference, actuator)
        let referenceIsLegal = actuator == .speed
            ? speedBounds.contains(referenceValue)
            : inclineBounds.contains(Int(referenceValue))
        if referenceIsLegal, case .adjust(_, let reason) = decision, reason != .outOfBounds {
            XCTAssertLessThanOrEqual(abs(sent - referenceValue), stepLimit(actuator) + 0.0001,
                                     label)
        }
        if case .fallback = decision {
            XCTAssertLessThanOrEqual(sent, referenceValue + 0.0001, label)
        }
    }

    /// The command a decision would have the caller send, if any.
    private func commandedValue(of decision: Decision) -> Command? {
        switch decision {
        case .adjust(let command, _), .fallback(let command):
            return command
        case .hold, .frozen, .emergencyStop, .manualControl:
            return nil
        }
    }

    // MARK: - Closed loop against a lagged plant

    func testFromBelowItSettlesIntoTheBandWithoutOscillating() {
        var loop = GovernorLoop(target: speedTarget(min: 4, max: 10), basis: basis,
                                plant: LaggedHeartRatePlant(),
                                startCommand: speedCommand(6.0))
        loop.run(forSeconds: 1800)
        assertSettled(loop, band: 144...155)
        // Non-vacuity: 6 km/h steadies at 126 bpm, so reaching the band means it
        // actually climbed — a governor that decided nothing would fail above.
        XCTAssertGreaterThan(loop.command.speedKmh, 7.0)
        // The first thing it must not do is take a shortcut through the ceiling.
        XCTAssertLessThan(loop.peakHeartRate, Governor.ceilings(for: basis).forceDownBpm,
                          "overshot into the force-down ceiling")
        XCTAssertLessThanOrEqual(loop.directionChanges, 2,
                                 "hunted around the band: \(loop.commandTraceDescription)")
        XCTAssertFalse(loop.trace.contains { $0.decision == .manualControl },
                       "a belt tracking its own command must not read as a person")
    }

    func testFromAboveItSettlesDownIntoTheBandWithoutOscillating() {
        // The same segment entered far too fast: 10 km/h steadies around 170 bpm.
        var loop = GovernorLoop(target: speedTarget(min: 4, max: 10), basis: basis,
                                plant: LaggedHeartRatePlant(),
                                startCommand: speedCommand(10.0))
        loop.run(forSeconds: 2400)
        assertSettled(loop, band: 144...155)
        XCTAssertLessThan(loop.command.speedKmh, 9.0)
        XCTAssertLessThanOrEqual(loop.directionChanges, 2,
                                 "hunted around the band: \(loop.commandTraceDescription)")
    }

    func testTheInclineActuatorSettlesIntoTheBandToo() {
        // At a fixed 6 km/h the plant steadies at 126 bpm; the band needs about
        // four incline levels, one 60 s settle window at a time.
        var loop = GovernorLoop(target: inclineTarget(minLevel: 0, maxLevel: 12), basis: basis,
                                plant: LaggedHeartRatePlant(),
                                startCommand: speedCommand(6.0, incline: 0))
        loop.run(forSeconds: 2400)
        assertSettled(loop, band: 144...155)
        XCTAssertGreaterThanOrEqual(loop.command.incline, 3)
        XCTAssertEqual(loop.command.speedKmh, 6.0, accuracy: 0.0001,
                       "an incline segment must never touch the speed")
        XCTAssertLessThan(loop.peakHeartRate, Governor.ceilings(for: basis).forceDownBpm)
        XCTAssertLessThanOrEqual(loop.directionChanges, 2,
                                 "hunted around the band: \(loop.commandTraceDescription)")
    }

    func testAnUnreachableBandEndsAtTheBoundAndSaysSo() {
        // The beta-blocker case end to end: a real ceiling of 118 bpm against a
        // band of 144–155 derived from 220 − age.
        var plant = LaggedHeartRatePlant()
        plant.ownCeilingBpm = 118
        var loop = GovernorLoop(target: speedTarget(min: 4, max: 10), basis: basis,
                                plant: plant, startCommand: speedCommand(6.0))
        loop.run(forSeconds: 3600)
        XCTAssertEqual(loop.command.speedKmh, 10.0, accuracy: 0.0001,
                       "it should have escalated to the segment's own bound and stopped")
        XCTAssertEqual(loop.trace.last?.decision, .hold(reason: .targetUnreachable))
        // And it must not have cut the segment short or pushed past the bound.
        XCTAssertFalse(loop.trace.contains { $0.decision == .emergencyStop })
        XCTAssertLessThanOrEqual(loop.maxCommandedSpeedKmh, 10.0 + 0.0001)
    }

    func testAnUnreachableBandIsAdmittedOnAConsoleThatPlateausATenthLow() {
        // **The same case on the belt the spec actually describes.** The console
        // obeys every command a tenth short and reports that tenth on every frame,
        // which is the first confusion the spec's hand-back rule names — well
        // inside the half a km/h that would be a person, so the loop must keep
        // governing and must still admit that 144–155 bpm is out of reach.
        //
        // The bound test used to be an exact comparison against the reference, and
        // the reference carries that measurement: `isAtUpperBound` was false on
        // every tick, `secondsAtUpperBoundBelowBand` never left zero, and the
        // ladder emitted `.adjust(10.0, .belowBand)` at every settle window for the
        // whole hour while the dashboard said "adjusting".
        var plant = LaggedHeartRatePlant()
        plant.ownCeilingBpm = 118
        plant.speedBiasKmh = 0.1
        var loop = GovernorLoop(target: speedTarget(min: 4, max: 10), basis: basis,
                                plant: plant, startCommand: speedCommand(6.0))
        loop.run(forSeconds: 3600)
        // Fact 1, not the client's target: the client's target reconciles down to
        // the belt's 9.9 ten seconds after the last write, which is exactly the
        // number that must not decide whether the loop has room left.
        XCTAssertEqual(loop.appCommand.speedKmh, 10.0, accuracy: 0.0001,
                       "it should have escalated to the segment's own bound and stopped")
        XCTAssertEqual(loop.trace.last?.decision, .hold(reason: .targetUnreachable),
                       loop.commandTraceDescription)
        // The give-up has to arrive inside the stall window once the bound is
        // reached, rather than an hour later: no evaluation after the first
        // `.targetUnreachable` may ask for more load again.
        guard let firstGiveUp = loop.trace.firstIndex(where: {
            $0.decision == .hold(reason: .targetUnreachable)
        }) else {
            return XCTFail("the give-up rule never fired: " + loop.commandTraceDescription)
        }
        XCTAssertFalse(loop.trace[firstGiveUp...].contains {
            if case .adjust(_, .belowBand) = $0.decision { return true }
            return false
        }, "it went back to pushing at an unreachable band: " + loop.commandTraceDescription)
        // A tenth of bias is not a takeover, and nothing may be sent above the
        // segment's own bound.
        XCTAssertFalse(loop.trace.contains { $0.decision == .manualControl },
                       "a tenth of console bias is not a person: "
                       + loop.commandTraceDescription)
        XCTAssertFalse(loop.trace.contains { $0.decision == .emergencyStop })
        XCTAssertLessThanOrEqual(loop.maxCommandedSpeedKmh, 10.0 + 0.0001)
    }

    func testALostFeedMidRunFreezesThenFallsBackAndNeverAccelerates() {
        var loop = GovernorLoop(target: speedTarget(min: 4, max: 10, fallback: 4.5),
                                basis: basis, plant: LaggedHeartRatePlant(),
                                startCommand: speedCommand(6.0))
        loop.run(forSeconds: 1200)
        let commandWhenLost = loop.command.speedKmh
        loop.heartRateFeedOn = false
        loop.run(forSeconds: 20)
        XCTAssertEqual(loop.trace.last?.decision, .frozen)
        XCTAssertEqual(loop.command.speedKmh, commandWhenLost, accuracy: 0.0001)
        loop.run(forSeconds: 40)
        XCTAssertEqual(loop.command.speedKmh, 4.5, accuracy: 0.0001)
        // Not one command after the feed died was faster than the one before it.
        XCTAssertLessThanOrEqual(loop.maxCommandedSpeedKmh, commandWhenLost + 0.0001)
    }

    func testASegmentEnteredFromAFasterOneIsNotReadAsAPerson() {
        // The entry command is a ramp of several km/h, so the belt is measured on
        // its way for the first ten-odd seconds and the client's target follows it
        // there. Neither is a person, and telling them apart no longer needs a
        // window around the write: the belt keeps moving toward the command, which
        // no hand on a dial does.
        //
        // The basis is deliberately high here: this test is about the manual
        // detection, not about the ceilings, and 12 km/h on this plant is 192 bpm.
        let highBasis = HeartRateBasis(restingBpm: 60, maxBpm: 220)
        var loop = GovernorLoop(target: speedTarget(min: 4, max: 10), basis: highBasis,
                                plant: LaggedHeartRatePlant(),
                                startCommand: speedCommand(4.0),
                                enteredFrom: speedCommand(12.0))
        loop.run(forSeconds: 3000)
        XCTAssertFalse(loop.trace.contains { $0.decision == .manualControl },
                       "a belt still travelling toward the entry command is not a person")
        assertSettled(loop, band: 144...155)
    }

    func testASmallConsoleNudgeIsRespectedWithoutBeingClassified() {
        // **Finding 61 end to end, and the inversion the spec now mandates.** This
        // used to assert that one press of speed-down read as a person. It no
        // longer does — a tenth is the same measurement as a console's own bias, a
        // footfall, or a write the queue dropped — and it does not need to: the
        // loop's command is one step from the *belt*, so the tenth simply stands.
        var loop = GovernorLoop(target: speedTarget(min: 4, max: 10), basis: basis,
                                plant: LaggedHeartRatePlant(),
                                startCommand: speedCommand(6.0))
        loop.run(forSeconds: 1500)
        let beforeNudge = loop.command.speedKmh
        loop.nudgeConsole(byKmh: -0.1)
        loop.run(forSeconds: 300)
        XCTAssertFalse(loop.trace.suffix(30).contains { $0.decision == .manualControl },
                       "a tenth is not a takeover: " + loop.commandTraceDescription)
        XCTAssertEqual(loop.command.speedKmh, beforeNudge - 0.1, accuracy: 0.0001,
                       "the loop put back the 0.1 the user had just taken off")
    }

    func testASmallConsoleChangeMidClimbIsSteppedFromRatherThanErased() {
        // The acceptance criterion as a closed-loop trace: **a small manual change
        // persists because the next command is one step from the belt, not from the
        // app's memory.** The loop is still climbing toward the band when the user
        // takes a tenth off; the next step has to come out one step above *their*
        // value. From memory it would be two tenths above it, and the change would
        // be gone with nothing having decided to discard it.
        var loop = GovernorLoop(target: speedTarget(min: 4, max: 10), basis: basis,
                                plant: LaggedHeartRatePlant(),
                                startCommand: speedCommand(6.0))
        loop.run(forSeconds: 105)
        let beforeNudge = loop.appCommand.speedKmh
        XCTAssertGreaterThan(beforeNudge, 6.0, "the loop has to have been climbing")
        loop.nudgeConsole(byKmh: -0.1)
        loop.run(forSeconds: 100)
        let next = loop.trace.first { step in
            guard step.second > 105, case .adjust(_, .belowBand) = step.decision else {
                return false
            }
            return true
        }
        guard case .adjust(let commanded, _)? = next?.decision else {
            return XCTFail("the loop has to keep climbing: " + loop.commandTraceDescription)
        }
        XCTAssertEqual(commanded.speedKmh, beforeNudge - 0.1 + Governor.maxSpeedStepKmh,
                       accuracy: 0.0001,
                       "the step was measured from memory: " + loop.commandTraceDescription)
        XCTAssertFalse(loop.trace.contains { $0.decision == .manualControl })
    }

    func testADecisiveConsoleReductionHandsControlBack() {
        // The other side of the same rule: half a km/h off, against the direction
        // the app asked for, is a person taking over — and the loop stops steering
        // for the rest of the segment however loudly the band argues.
        var loop = GovernorLoop(target: speedTarget(min: 4, max: 10), basis: basis,
                                plant: LaggedHeartRatePlant(),
                                startCommand: speedCommand(6.0))
        loop.run(forSeconds: 1800)
        let beforeNudge = loop.command.speedKmh
        loop.nudgeConsole(byKmh: -0.6)
        loop.run(forSeconds: 300)
        XCTAssertTrue(loop.trace.suffix(20).allSatisfy { $0.decision == .manualControl },
                      "half a km/h off is a takeover: " + loop.commandTraceDescription)
        XCTAssertEqual(loop.command.speedKmh, beforeNudge - 0.6, accuracy: 0.0001,
                       "the loop climbed away from the speed the user chose")
    }

    func testAnInAppNudgeHandsControlBackExactlyAsAConsoleDialDoes() {
        // Finding 90 end to end. The dashboard's ± tiles are enabled during a
        // governed segment, and they entered through the same call as the loop's own
        // writes — so the inference cleared its evidence on the app's own person and
        // the loop accelerated back through their change.
        var loop = GovernorLoop(target: speedTarget(min: 4, max: 10), basis: basis,
                                plant: LaggedHeartRatePlant(),
                                startCommand: speedCommand(6.0))
        loop.run(forSeconds: 1500)
        let before = loop.appCommand.speedKmh
        loop.nudgeInApp(byKmh: -0.3)
        loop.run(forSeconds: 300)
        XCTAssertTrue(loop.trace.suffix(30).contains { $0.decision == .manualControl },
                      "a press of the app's own minus tile has to read as a person: "
                      + loop.commandTraceDescription)
        XCTAssertLessThanOrEqual(loop.appCommand.speedKmh, before - 0.3 + 0.0001,
                                 "the loop put back what the user had just taken off")
    }

    func testAConsoleChangeDuringTheEntryRampIsNotCompoundedForTheWholeSegment() {
        // Finding 77 end to end. The segment is entered at 4.0 from a belt running
        // at 12.0, and while it is still coming down the user stops its descent at
        // 6.0 by hand. The old corridor could never close — a manual intervention
        // is exactly what keeps the belt from arriving — so the intervention was
        // invisible for the whole segment and the loop accelerated away from the
        // value the person had chosen, 0.2 km/h at a time.
        let highBasis = HeartRateBasis(restingBpm: 60, maxBpm: 220)
        var loop = GovernorLoop(target: speedTarget(min: 4, max: 10), basis: highBasis,
                                plant: LaggedHeartRatePlant(),
                                startCommand: speedCommand(4.0),
                                enteredFrom: speedCommand(12.0))
        // Four seconds in, the belt is around 10 km/h and heading down; the user
        // presses up until the console holds 6.0.
        loop.run(forSeconds: 4)
        loop.nudgeConsole(byKmh: 2.0)
        loop.run(forSeconds: 600)
        XCTAssertTrue(loop.trace.contains { $0.decision == .manualControl },
                      "the intervention has to be seen: " + loop.commandTraceDescription)
        // And nothing was written above the app's own entry command.
        XCTAssertLessThanOrEqual(loop.maxCommandedSpeedKmh, 4.0 + 0.0001,
                                 loop.commandTraceDescription)
    }

    func testAConsoleDialBelowTheEntryCommandIsSeenRatherThanClimbedAwayFrom() {
        // **Finding 110 end to end, in the direction the criterion used to miss.**
        // The segment is entered at 12.0 from a belt walking at 4.0, and while it is
        // still climbing the user dials the console down to 6.0 to keep jogging. The
        // belt then sits *below* the app's outstanding command, which satisfied
        // neither of the old clauses — the departure clause needs a value it had
        // reached, and the other one fired only on an over-load — so nothing was
        // inferred, the loop read "a machine", and the band law walked the belt back
        // up from the person's own 6.0, 0.2 km/h every 45 s.
        let highBasis = HeartRateBasis(restingBpm: 60, maxBpm: 220)
        var loop = GovernorLoop(target: speedTarget(min: 4, max: 12), basis: highBasis,
                                plant: LaggedHeartRatePlant(),
                                startCommand: speedCommand(12.0),
                                enteredFrom: speedCommand(4.0))
        // Four seconds in the belt is around 6 km/h and still climbing; the user
        // dials the console back to where they are and stays there.
        loop.run(forSeconds: 4)
        loop.nudgeConsole(byKmh: -6.0)
        loop.run(forSeconds: 600)
        XCTAssertTrue(loop.trace.contains { $0.decision == .manualControl },
                      "a dial below the app's own command has to be seen: "
                      + loop.commandTraceDescription)
        XCTAssertFalse(loop.trace.contains {
            if case .adjust(_, .belowBand) = $0.decision { return true }
            return false
        }, "the loop climbed away from the speed the user chose: " + loop.commandTraceDescription)
        XCTAssertEqual(loop.command.speedKmh, 6.0, accuracy: 0.0001)
    }

    func testAConsoleInclinePressIsSeenOnAnInclineSegment() {
        // The axis the deleted dead band blinded (finding 75): a change was
        // invisible for ever, and the loop then pushed the incline back up past the
        // user's hand. **Two levels rather than one**, which is what the spec now
        // calls decisive on this axis — one level is inside the same confusion as a
        // tenth of a km/h, and it is respected by the loop stepping from the belt
        // rather than by being classified.
        var loop = GovernorLoop(target: inclineTarget(minLevel: 0, maxLevel: 12), basis: basis,
                                plant: LaggedHeartRatePlant(),
                                startCommand: speedCommand(6.0, incline: 3))
        loop.run(forSeconds: 300)
        let commandedLevel = loop.appCommand.incline
        loop.nudgeConsole(byLevels: -2)
        loop.run(forSeconds: 300)
        XCTAssertTrue(loop.trace.contains { $0.decision == .manualControl },
                      "two levels of incline-down has to read as a person: "
                      + loop.commandTraceDescription)
        XCTAssertLessThanOrEqual(loop.appCommand.incline, commandedLevel,
                                 "the loop put back the levels the user had just taken off")
    }

    func testAZoneFiveBandRunsFixedInsteadOfHoldingTheUserAt92Percent() {
        // Karvonen zone 5 for resting 60 / max 180 is 168…180 and the force-down
        // ceiling is 166. The band rung used to climb while the heart rate was
        // under 168, the ceiling used to pull it back at 166, and the loop
        // sawtoothed at 92% of maximum for the whole segment while the give-up
        // rule stayed silent because the band was never reached.
        var loop = GovernorLoop(target: speedTarget(low: 168, high: 180, min: 4, max: 10),
                                basis: basis, plant: LaggedHeartRatePlant(),
                                startCommand: speedCommand(8.0))
        loop.run(forSeconds: 1800)
        XCTAssertEqual(loop.command.speedKmh, 8.0, accuracy: 0.0001,
                       "an unsteerable band runs fixed at its start command")
        XCTAssertLessThan(loop.peakHeartRate, Governor.ceilings(for: basis).forceDownBpm,
                          "it must not have climbed into the ceiling at all")
        XCTAssertTrue(loop.trace.allSatisfy { $0.decision == .hold(reason: .bandNotSteerable) },
                      loop.commandTraceDescription)
    }

    private func assertSettled(_ loop: GovernorLoop, band: ClosedRange<Int>,
                               evaluations: Int = 6) {
        let tail = loop.trace.suffix(evaluations)
        XCTAssertEqual(tail.count, evaluations)
        for step in tail {
            XCTAssertTrue(band.contains(step.heartRate),
                          "\(step.heartRate) bpm outside \(band) at \(step.second) s "
                          + "— \(loop.commandTraceDescription)")
        }
    }
}

// MARK: - The plant

/// A treadmill and the person on it, as the simplest model that reproduces the
/// behaviour the governor is designed around: the heart rate approaches a
/// load-dependent steady state with a first-order lag (τ ≈ 30 s), and the belt
/// itself takes time to reach a new command.
struct LaggedHeartRatePlant {
    var restingBpm: Double = 60
    /// Slope of the steady state in speed and incline. 11 bpm per km/h puts
    /// 8 km/h at 148 bpm, in the middle of a zone-3 band for resting 60 / max 180.
    var bpmPerKmh: Double = 11
    var bpmPerInclineLevel: Double = 5
    /// Heart rate lags load by 20–40 s, which is the reason the governor's
    /// evaluation interval and settle window exist.
    var tauSeconds: Double = 30
    /// The person's actual maximum, which may be far below the app's estimate.
    var ownCeilingBpm: Double = 200
    var beltRampKmhPerSecond: Double = 0.5
    /// The incline motor is the slower actuator: several seconds per level.
    var inclineLevelsPerSecond: Double = 0.2
    /// How far below the command this belt plateaus, in km/h. The spec's first
    /// named confusion — "a console with a one-tenth bias" — as a knob: with 0.1
    /// here the belt obeys every command a tenth short and reports that tenth on
    /// every frame, for ever. It is well inside the half-a-km/h a hand-back needs,
    /// so nothing about it is a person; it is simply the machine this app has to
    /// govern. The default 0 is the honest belt every other test uses.
    var speedBiasKmh: Double = 0
    /// The same for the incline motor, in levels.
    var inclineBiasLevels: Double = 0

    var heartRateBpm: Double = 60
    var speedKmh: Double = 0
    var inclineLevel: Double = 0

    mutating func advance(bySeconds delta: Double, command: HeartRateGovernor.Command) {
        speedKmh = tracked(speedKmh, towards: max(0, command.speedKmh - speedBiasKmh),
                           rate: beltRampKmhPerSecond * delta)
        inclineLevel = tracked(inclineLevel,
                               towards: max(0, Double(command.incline) - inclineBiasLevels),
                               rate: inclineLevelsPerSecond * delta)
        let steady = min(ownCeilingBpm,
                         restingBpm + bpmPerKmh * speedKmh + bpmPerInclineLevel * inclineLevel)
        heartRateBpm += (steady - heartRateBpm) * (1 - exp(-delta / tauSeconds))
    }

    private func tracked(_ value: Double, towards target: Double, rate: Double) -> Double {
        value < target ? min(target, value + rate) : max(target, value - rate)
    }
}

/// The plant plus the parts of `FitShowTreadmillClient` and `ProgramRunner` the
/// loop depends on — and the client's own rules are *called*, not re-modelled:
/// `FitShowTreadmillClient.reconciled` produces the client's target and
/// `ConsoleDialDetector` produces fact 3, exactly as they do on the device. A
/// fake that models a rule production does not have validates a client that does
/// not exist (finding 80).
struct GovernorLoop {
    let target: HeartRateTarget
    let basis: HeartRateBasis
    var limits = TreadmillLimits()
    var plant: LaggedHeartRatePlant
    var heartRateFeedOn = true

    /// **Fact 1**: the app's own last command. No observation touches it.
    private(set) var appCommand: HeartRateGovernor.Command
    /// The *client's* target: fact 1 reconciled with the belt's measured value by
    /// the client's one reconcile rule. The governor may read it only to lower
    /// its reference.
    private(set) var command: HeartRateGovernor.Command
    /// What the console is actually driving the belt toward. A separate number on
    /// purpose: a person turning a dial moves this, and nothing else does.
    private var consoleSetpoint: HeartRateGovernor.Command
    /// **Fact 3**, from production code, driven frame by frame as the client
    /// drives it.
    private var dial = ConsoleDialDetector()
    private var lastAppliedChange: HeartRateGovernor.Change
    private var tallies = HeartRateGovernor.Tallies()
    private var secondsSinceSegmentStart: Double = 0
    private var secondsSinceLastCommand: Double = 0
    /// The runner's second clock: since the *load* last changed, whoever changed
    /// it. `ProgramRunner.GovernorRun.observing(_:)` keeps it on the device, with
    /// `HeartRateGovernor.isLoadChanged(from:to:)` — the production predicate — as
    /// the threshold (finding 137).
    private var secondsSinceLoadChange: Double = 0
    private var observedLoad: HeartRateGovernor.Command
    private var second: Double = 0
    private(set) var trace: [Step] = []
    private(set) var peakHeartRate = 0
    private(set) var maxCommandedSpeedKmh: Double

    struct Step {
        let second: Double
        let heartRate: Int
        let command: HeartRateGovernor.Command
        let decision: HeartRateGovernor.Decision
    }

    /// `enteredFrom` is the command the *previous* segment was running at: with
    /// it the belt and the heart rate start there, so the entry write has a real
    /// ramp to travel and the loop has to tell that ramp from a person without a
    /// corridor to hide behind.
    init(target: HeartRateTarget, basis: HeartRateBasis, plant: LaggedHeartRatePlant,
         startCommand: HeartRateGovernor.Command,
         enteredFrom previous: HeartRateGovernor.Command? = nil) {
        self.target = target
        self.basis = basis
        self.plant = plant
        appCommand = startCommand
        command = startCommand
        consoleSetpoint = startCommand
        observedLoad = startCommand
        maxCommandedSpeedKmh = startCommand.speedKmh
        let handover = previous ?? startCommand
        // `ProgramRunner.write(_:to:)` reports the change from where the belt *is*.
        lastAppliedChange = HeartRateGovernor.Change(from: handover, to: startCommand)
        self.plant.speedKmh = handover.speedKmh
        self.plant.inclineLevel = Double(handover.incline)
        self.plant.heartRateBpm = plant.restingBpm + plant.bpmPerKmh * handover.speedKmh
            + plant.bpmPerInclineLevel * Double(handover.incline)
        dial.commanded(speedUnits: HeartRateGovernor.speedUnits(startCommand.speedKmh),
                       incline: startCommand.incline,
                       measuredSpeedUnits: HeartRateGovernor.speedUnits(handover.speedKmh),
                       measuredIncline: handover.incline)
    }

    /// The user pressing the console's speed button. It moves the console's own
    /// setpoint and nothing else — what the app makes of that is the whole
    /// question.
    mutating func nudgeConsole(byKmh delta: Double) {
        consoleSetpoint.speedKmh = HeartRateGovernor.speedKmh(
            units: HeartRateGovernor.speedUnits(consoleSetpoint.speedKmh + delta))
    }

    mutating func nudgeConsole(byLevels delta: Int) {
        consoleSetpoint.incline += delta
    }

    /// The user pressing the **app's** ± tile: `FitShowTreadmillClient
    /// .adjustSpeed`, which records fact 1 like any write and latches the dial the
    /// way a console press does (finding 90). `lastAppliedChange` deliberately does
    /// *not* move: that is the runner's record of its own last write, and the
    /// runner does not know the user touched a tile.
    mutating func nudgeInApp(byKmh delta: Double) {
        let units = HeartRateGovernor.speedUnits(command.speedKmh + delta)
        let next = HeartRateGovernor.Command(speedKmh: HeartRateGovernor.speedKmh(units: units),
                                            incline: command.incline)
        appCommand = next
        command = next
        consoleSetpoint = next
        dial.setByHand(.speed, speedUnits: units, incline: next.incline,
                       measuredSpeedUnits: measuredSpeedUnits, measuredIncline: measuredIncline)
        secondsSinceLastCommand = 0
        secondsSinceLoadChange = 0
    }

    mutating func run(forSeconds seconds: Double) {
        for _ in 0..<Int(seconds) {
            step()
        }
    }

    private var measuredSpeedUnits: Int {
        HeartRateGovernor.speedUnits((plant.speedKmh * 10).rounded() / 10)
    }

    private var measuredIncline: Int { Int(plant.inclineLevel.rounded()) }

    private var measuredCommand: HeartRateGovernor.Command {
        HeartRateGovernor.Command(speedKmh: HeartRateGovernor.speedKmh(units: measuredSpeedUnits),
                                  incline: measuredIncline)
    }

    private mutating func step() {
        second += 1
        plant.advance(bySeconds: 1, command: consoleSetpoint)
        let heartRate = heartRateFeedOn ? Int(plant.heartRateBpm.rounded()) : 0
        peakHeartRate = max(peakHeartRate, heartRate)
        secondsSinceSegmentStart += 1
        secondsSinceLastCommand += 1
        secondsSinceLoadChange += 1
        // The client's frame path, in the client's own order: fact 3 is inferred
        // from the measurement, then the one reconcile rule recomputes the
        // client's target from the two facts.
        dial.observe(measuredSpeedUnits: measuredSpeedUnits, measuredIncline: measuredIncline,
                     deltaSeconds: 1)
        command = HeartRateGovernor.Command(
            speedKmh: HeartRateGovernor.speedKmh(units: FitShowTreadmillClient.reconciled(
                commandUnits: HeartRateGovernor.speedUnits(appCommand.speedKmh),
                measuredUnits: measuredSpeedUnits,
                secondsSinceCommand: secondsSinceLastCommand, ignoreZeroMeasurement: true)),
            incline: FitShowTreadmillClient.reconciled(
                commandUnits: appCommand.incline, measuredUnits: measuredIncline,
                secondsSinceCommand: secondsSinceLastCommand, ignoreZeroMeasurement: false))
        let belt = beltFacts
        // `ProgramRunner.advancing`'s own line: an observed change of load re-arms
        // the settle window whoever made it, and only that window — the app's own
        // clock is the floor under two forced reductions and no dial may postpone a
        // brake.
        if HeartRateGovernor.isLoadChanged(from: observedLoad, to: measuredCommand) {
            secondsSinceLoadChange = 0
            observedLoad = measuredCommand
        }
        // `ProgramRunner.advancing`'s own bound test, and the governor's: fact 1
        // decides whether the loop has room left, and the reference — which carries
        // the measurement — only has to be within one step of the bound. An exact
        // test against the reference reset this tally on any tick a belt reported a
        // tenth short, so a persistent bias meant the give-up rule never fired.
        let reference = HeartRateGovernor.reference(command: command,
                                                    lastAppliedChange: lastAppliedChange,
                                                    appCommand: appCommand, belt: belt)
        tallies = tallies.advanced(
            bySeconds: 1, heartRate: heartRate,
            ceilings: HeartRateGovernor.ceilings(for: basis),
            band: HeartRateGovernor.band(for: target),
            isAtUpperBound: HeartRateGovernor.isAtUpperBound(reference: reference,
                                                            appCommand: appCommand,
                                                            target: target, limits: limits))
        guard second.truncatingRemainder(
            dividingBy: HeartRateGovernor.evaluationIntervalSeconds) == 0 else { return }
        let decision = HeartRateGovernor.decide(HeartRateGovernor.Input(
            target: target, basis: basis, limits: limits, heartRate: heartRate,
            command: command, lastAppliedChange: lastAppliedChange, appCommand: appCommand,
            secondsSinceSegmentStart: secondsSinceSegmentStart,
            secondsSinceLastCommand: secondsSinceLastCommand,
            secondsSinceLoadChange: secondsSinceLoadChange, tallies: tallies, belt: belt))
        trace.append(Step(second: second, heartRate: heartRate, command: command,
                          decision: decision))
        switch decision {
        case .adjust(let next, _), .fallback(let next):
            apply(next)
        case .hold, .frozen, .emergencyStop, .manualControl:
            break
        }
    }

    /// Facts 2 and 3 as `FitShowTreadmillClient.beltFacts` reports them.
    private var beltFacts: HeartRateGovernor.BeltFacts {
        HeartRateGovernor.BeltFacts(measured: measuredCommand,
                                    isSpeedSetByHand: dial.speed.isSetByHand,
                                    isInclineSetByHand: dial.incline.isSetByHand)
    }

    /// `FitShowTreadmillClient.setTarget`: it clamps to the machine's limits and
    /// sends whole 0.1 km/h units, records fact 1, and re-anchors the dial
    /// detector — every piece of whose evidence is about the previous command.
    private mutating func apply(_ next: HeartRateGovernor.Command) {
        // `from` is the *previous command* (`appCommand`), not the belt's
        // measured value — matching `ProgramRunner.write(_:to:)` and
        // `WiringLoop.apply` below. This fake used to read it from the belt,
        // which is the semantics the runner packet deliberately retired: it
        // made a resume that restarts a belt from zero look like a large
        // upward change and earned the next reduction a reversal margin it had
        // not earned. Captured before `appCommand` is overwritten.
        let from = appCommand
        let speedRaw = min(max(HeartRateGovernor.speedUnits(next.speedKmh), limits.minSpeedRaw),
                           limits.maxSpeedRaw)
        let clamped = HeartRateGovernor.Command(
            speedKmh: HeartRateGovernor.speedKmh(units: speedRaw),
            incline: min(max(next.incline, limits.minIncline), limits.maxIncline))
        lastAppliedChange = HeartRateGovernor.Change(from: from, to: clamped)
        appCommand = clamped
        command = clamped
        consoleSetpoint = clamped
        dial.commanded(speedUnits: speedRaw, incline: clamped.incline,
                       measuredSpeedUnits: measuredSpeedUnits, measuredIncline: measuredIncline)
        maxCommandedSpeedKmh = max(maxCommandedSpeedKmh, clamped.speedKmh)
        // `GovernorRun.commandApplied(_:)`: the app's own write re-arms both clocks
        // and moves the load the settle window is measured from.
        secondsSinceLastCommand = 0
        secondsSinceLoadChange = 0
        observedLoad = clamped
    }

    /// How many times the commanded direction reversed — the trace assertion for
    /// "it settles without oscillating".
    var directionChanges: Int {
        var previous = 0
        var changes = 0
        var last = trace.first?.command
        for step in trace.dropFirst() {
            guard let previousCommand = last else { break }
            let delta = step.command.speedKmh - previousCommand.speedKmh
                + Double(step.command.incline - previousCommand.incline)
            let direction = abs(delta) < 0.0001 ? 0 : (delta > 0 ? 1 : -1)
            if direction != 0 {
                if previous != 0, direction != previous { changes += 1 }
                previous = direction
            }
            last = step.command
        }
        return changes
    }

    var commandTraceDescription: String {
        trace.map { String(format: "%.0fs %.1fkm/h %d%% %dbpm", $0.second, $0.command.speedKmh,
                           $0.command.incline, $0.heartRate) }
            .joined(separator: " | ")
    }
}
