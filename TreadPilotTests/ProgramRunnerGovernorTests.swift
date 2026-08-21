// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import XCTest
@testable import TreadPilot

/// The wiring between the runner and the governor: the opt-in gate, the frozen
/// basis, what belongs to the workout rather than to the segment, the hand-back
/// latch, what a stale link may write, and what a resume re-writes. The control
/// law itself is `HeartRateGovernorTests`; everything here is about the runner
/// deciding whether the law may act at all.
final class ProgramRunnerGovernorTests: XCTestCase {

    typealias Governor = HeartRateGovernor
    typealias Command = HeartRateGovernor.Command
    typealias Change = HeartRateGovernor.Change
    typealias Run = ProgramRunner.GovernorRun
    typealias Session = ProgramRunner.GovernorSession
    typealias Status = ProgramRunner.GovernorStatus

    // Resting 60 / max 180: the force-down ceiling is 166, the stop ceiling 175.
    private let basis = HeartRateBasis(restingBpm: 60, maxBpm: 180)
    private let limits = TreadmillLimits()

    private func speedTarget(low: Int = 144, high: Int = 155,
                             min: Double = 4.0, max: Double = 10.0,
                             start: Double = 6.0, fallback: Double = 4.5) -> HeartRateTarget {
        HeartRateTarget(lowBpm: low, highBpm: high, actuator: .speed,
                        startSpeedKmh: start, startIncline: 0,
                        minSpeedKmh: min, maxSpeedKmh: max,
                        minIncline: 0, maxIncline: 0, fallbackSpeedKmh: fallback)
    }

    private func inclineTarget(low: Int = 144, high: Int = 155,
                               minLevel: Int = 0, maxLevel: Int = 12,
                               startSpeed: Double = 6.0,
                               startLevel: Int = 6) -> HeartRateTarget {
        HeartRateTarget(lowBpm: low, highBpm: high, actuator: .incline,
                        startSpeedKmh: startSpeed, startIncline: startLevel,
                        minSpeedKmh: startSpeed, maxSpeedKmh: startSpeed,
                        minIncline: minLevel, maxIncline: maxLevel)
    }

    private func heartRateSegment(_ target: HeartRateTarget? = nil,
                                  goal: SegmentGoal = .time(seconds: 600)) -> WorkoutSegment {
        WorkoutSegment(name: "Zone 3", goal: goal,
                       target: .heartRate(target ?? speedTarget()))
    }

    private func fixedSegment() -> WorkoutSegment {
        WorkoutSegment(name: "Steady", duration: 600, targetSpeedKmh: 8.0, targetIncline: 1)
    }

    private func command(_ speedKmh: Double, incline: Int = 0) -> Command {
        Command(speedKmh: speedKmh, incline: incline)
    }

    private func governedRun(_ target: HeartRateTarget? = nil, at entry: Command) -> Run {
        Run(target: target ?? speedTarget(), lastAppliedChange: .settled(at: entry))
    }

    private func governedSession(_ target: HeartRateTarget? = nil, at entry: Command) -> Session {
        var session = Session()
        session.beginSegment(governedRun(target, at: entry))
        return session
    }

    // MARK: - The opt-in gate

    func testTheOptInIsOffUntilSomethingWritesTheKey() {
        let suite = "hu.backlog.treadpilot.tests.governor"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        // Off is the absence of the key, so no registered default can be forgotten.
        XCTAssertFalse(ProgramRunner.isHeartRateControlEnabled(in: defaults))
        defaults.set(true, forKey: ProgramRunner.heartRateControlDefaultsKey)
        XCTAssertTrue(ProgramRunner.isHeartRateControlEnabled(in: defaults))
        defaults.removePersistentDomain(forName: suite)
    }

    func testWithTheOptInOffNoHeartRateSegmentIsGoverned() {
        let segment = heartRateSegment()
        let gate = ProgramRunner.gate(for: segment, isControlEnabled: false,
                                      entry: .settled(at: command(6.0)))
        XCTAssertEqual(gate, .controlOff)
        // No run means `steer` has nothing to evaluate: not one write can happen.
        XCTAssertNil(gate.run)
        XCTAssertEqual(gate.initialStatus, .controlOff)
    }

    func testWithTheOptInOffTheSegmentRunsFixedAtItsStartCommand() {
        // The whole "runs as a plain fixed segment" rule: the nominal pair a
        // refused segment is commanded with is its own start command.
        let segment = heartRateSegment(speedTarget(start: 6.4))
        XCTAssertEqual(segment.nominalSpeedKmh, 6.4, accuracy: 0.0001)
        XCTAssertEqual(segment.nominalIncline, 0)
        XCTAssertEqual(ProgramRunner.resumeCommand(for: segment, run: nil), command(6.4))
    }

    func testAFixedSegmentHasNoGovernorStateAndNoStatus() {
        let gate = ProgramRunner.gate(for: fixedSegment(), isControlEnabled: true,
                                      entry: .settled(at: command(8.0, incline: 1)))
        XCTAssertEqual(gate, .notHeartRateDriven)
        XCTAssertNil(gate.run)
        XCTAssertNil(gate.initialStatus)
    }

    func testAnUnsteerableTargetIsRefusedEvenWithTheOptInOn() {
        // Bounds pinned to one value: the loop could never take a step, so it
        // would chase the band from a command it cannot move.
        let pinned = speedTarget(min: 6.0, max: 6.0)
        XCTAssertFalse(pinned.isUsable)
        let gate = ProgramRunner.gate(for: heartRateSegment(pinned), isControlEnabled: true,
                                      entry: .settled(at: command(6.0)))
        XCTAssertEqual(gate, .targetNotUsable)
        XCTAssertNil(gate.run)
    }

    func testAGovernedRunStartsFromTheEntryWriteItself() {
        // The run starts from the write the runner actually made, and that write
        // is fact 1 for the whole segment: nothing the belt reports may overwrite
        // it, which is what makes every reduction measurable from it.
        let entry = Change(from: command(12.0), to: command(4.0))
        let gate = ProgramRunner.gate(for: heartRateSegment(speedTarget(start: 4.0)),
                                      isControlEnabled: true, entry: entry)
        guard let run = gate.run else { return XCTFail("the gate refused a usable segment") }
        XCTAssertEqual(run.lastAppliedChange, entry)
        XCTAssertEqual(run.lastAppliedChange.to, command(4.0))
        XCTAssertEqual(run.secondsSinceSegmentStart, 0)
        XCTAssertFalse(run.isHandedBack)
        XCTAssertFalse(run.isSurrendered)
        XCTAssertEqual(gate.initialStatus, .holding)
    }

    // MARK: - The frozen basis

    func testWithoutABasisNoTallyMoves() {
        var session = governedSession(at: command(6.0))
        for _ in 0..<60 {
            session = ProgramRunner.advancing(session, bySeconds: 1, heartRate: 175, basis: nil,
                                              command: command(6.0), belt: .unobserved,
                                              limits: limits)
        }
        // A minute above what would be the stop ceiling, and nothing was counted:
        // without a basis there is no ceiling to be above.
        XCTAssertNil(session.basis)
        XCTAssertEqual(session.tallies, Governor.Tallies())
        // The clocks still run, so the first evaluation after a basis arrives is
        // due at once — and it holds, because the settle window has not passed.
        XCTAssertEqual(session.run?.secondsSinceSegmentStart ?? 0, 60, accuracy: 0.0001)
    }

    func testAnEvaluationWithoutABasisWritesNothing() {
        var loop = WiringLoop(run: governedRun(at: command(6.0)), command: command(6.0),
                             basis: nil)
        loop.heartRate = 100 // far below the band: the one input that could accelerate
        loop.advance(seconds: 120)
        XCTAssertEqual(loop.writes, [])
        XCTAssertEqual(loop.status, .noBasis)
        XCTAssertEqual(loop.command, command(6.0))
    }

    func testTheFirstBasisIsAdoptedAndALaterOneCannotReplaceIt() {
        var session = governedSession(at: command(6.0))
        session = ProgramRunner.advancing(session, bySeconds: 1, heartRate: 150, basis: basis,
                                          command: command(6.0), belt: .unobserved, limits: limits)
        XCTAssertEqual(session.basis, basis)
        // A profile edit mid-workout must not move a ceiling under a running loop.
        session = ProgramRunner.advancing(session, bySeconds: 1, heartRate: 150,
                                          basis: HeartRateBasis(restingBpm: 60, maxBpm: 220),
                                          command: command(6.0), belt: .unobserved, limits: limits)
        XCTAssertEqual(session.basis, basis)
        // And a segment boundary does not re-open the question either: the basis
        // is the workout's, not the segment's.
        session.beginSegment(governedRun(at: command(6.0)))
        XCTAssertEqual(session.basis, basis)
    }

    // MARK: - Cadence and clocks

    func testTheEvaluationCadenceIsTheGovernorsNotTheTimers() {
        var session = governedSession(at: command(6.0))
        for _ in 0..<9 {
            session = ProgramRunner.advancing(session, bySeconds: 1, heartRate: 150, basis: basis,
                                              command: command(6.0), belt: .unobserved,
                                              limits: limits)
        }
        XCTAssertFalse(ProgramRunner.isEvaluationDue(session))
        session = ProgramRunner.advancing(session, bySeconds: 1, heartRate: 150, basis: basis,
                                          command: command(6.0), belt: .unobserved, limits: limits)
        XCTAssertTrue(ProgramRunner.isEvaluationDue(session))
    }

    func testOneTickCreditsAtMostOneFreshnessHorizon() {
        // A 30 s gap (a background window) credits 3 s, the client's horizon: the
        // under-credit lengthens every settle window instead of shortening it.
        let session = ProgramRunner.advancing(governedSession(at: command(6.0)), bySeconds: 30,
                                              heartRate: 175, basis: basis,
                                              command: command(6.0), belt: .unobserved,
                                              limits: limits)
        XCTAssertEqual(session.run?.secondsSinceSegmentStart ?? 0, ProgramRunner.maxTickSeconds,
                       accuracy: 0.0001)
        XCTAssertEqual(session.tallies.secondsAboveStopCeiling, ProgramRunner.maxTickSeconds,
                       accuracy: 0.0001)
    }

    func testANonPositiveDeltaChangesNothing() {
        let session = governedSession(at: command(6.0))
        XCTAssertEqual(ProgramRunner.advancing(session, bySeconds: 0, heartRate: 150,
                                               basis: basis, command: command(6.0),
                                               belt: .unobserved, limits: limits), session)
        XCTAssertEqual(ProgramRunner.advancing(session, bySeconds: .nan, heartRate: 150,
                                               basis: basis, command: command(6.0),
                                               belt: .unobserved, limits: limits), session)
    }

    // MARK: - What belongs to the workout and what to the segment

    func testASegmentBoundaryKeepsThePersonsClocksAndDropsTheBandsTallies() {
        // The split finding 64 is about: the two ceilings and the feed belong to
        // the person on the belt, while "at the upper bound below the band" and
        // the force-down signature are statements about a band the next segment
        // re-states.
        var tallies = Governor.Tallies()
        tallies.secondsWithoutHeartRate = 4
        tallies.secondsAboveForceDownCeiling = 8
        tallies.secondsAboveStopCeiling = 12
        tallies.secondsAtUpperBoundBelowBand = 90
        tallies.didForceDown = true
        tallies.secondsBelowBandAfterForceDown = 60
        let carried = Session.carriedOver(tallies)
        XCTAssertEqual(carried.secondsWithoutHeartRate, 4, accuracy: 0.0001)
        XCTAssertEqual(carried.secondsAboveForceDownCeiling, 8, accuracy: 0.0001)
        XCTAssertEqual(carried.secondsAboveStopCeiling, 12, accuracy: 0.0001)
        XCTAssertEqual(carried.secondsAtUpperBoundBelowBand, 0, accuracy: 0.0001)
        XCTAssertFalse(carried.didForceDown)
        XCTAssertEqual(carried.secondsBelowBandAfterForceDown, 0, accuracy: 0.0001)
    }

    func testTheEvaluationGridBelongsToTheWorkoutNotTheSegment() {
        var session = governedSession(at: command(6.0))
        for _ in 0..<7 {
            session = ProgramRunner.advancing(session, bySeconds: 1, heartRate: 150, basis: basis,
                                              command: command(6.0), belt: .unobserved,
                                              limits: limits)
        }
        // A boundary seven seconds in: the grid keeps its phase, so the next
        // evaluation is three seconds away and not ten. Re-anchoring it here is
        // what put the first evaluation of a short segment past its own end.
        session.beginSegment(governedRun(at: command(6.0)))
        for _ in 0..<3 {
            session = ProgramRunner.advancing(session, bySeconds: 1, heartRate: 150, basis: basis,
                                              command: command(6.0), belt: .unobserved,
                                              limits: limits)
        }
        XCTAssertTrue(ProgramRunner.isEvaluationDue(session))
    }

    func testAFixedSegmentInAGovernedWorkoutStillRunsThePersonsClocks() {
        var session = Session()
        session.beginSegment(nil) // the gate refused this one: a plain fixed segment
        for _ in 0..<20 {
            session = ProgramRunner.advancing(session, bySeconds: 1, heartRate: 176, basis: basis,
                                              command: command(8.0), belt: .unobserved,
                                              limits: limits)
        }
        // Neither reset nor frozen: a breach that ends during a fixed segment
        // must not still be standing at the next governed segment's first
        // evaluation, and one that continues must not have to start over.
        XCTAssertEqual(session.tallies.secondsAboveStopCeiling, 20, accuracy: 0.0001)
        XCTAssertEqual(session.tallies.secondsAboveForceDownCeiling, 20, accuracy: 0.0001)
        // And no band was in play, so the band-scoped fields stayed at zero.
        XCTAssertEqual(session.tallies.secondsAtUpperBoundBelowBand, 0, accuracy: 0.0001)
        XCTAssertEqual(session.tallies.secondsBelowBandAfterForceDown, 0, accuracy: 0.0001)
    }

    func testTheStopCeilingFiresInFifteenSecondSegments() {
        // Finding 64 end to end. The editor's shortest segment is 15 s, the stop
        // needs 15 s of breach *and* an evaluation to act on it, and evaluations
        // sit on a 10 s grid — so with the clocks rebuilt at every boundary a
        // HIIT program of 15 s segments could hold a user above 97% of their
        // frozen maximum for as long as they lasted and never call `requestStop`.
        let segment = heartRateSegment(goal: .time(seconds: 15))
        var loop = WiringLoop(run: nil, command: command(8.0), basis: basis)
        loop.heartRate = 176 // above the 175 stop ceiling
        loop.beginSegment(segment)
        for _ in 0..<8 where !loop.didStop {
            loop.advance(seconds: 15)
            if loop.didStop { break }
            loop.beginSegment(segment)
        }
        XCTAssertTrue(loop.didStop, "the stop never fired: \(loop.traceDescription)")
        // Tightened from 20 s by finding 81: the stop is asked at workout scope on
        // every tick now, not on the 10 s evaluation grid, so it fires on the tick
        // the 15 s hold window closes and not five seconds later.
        XCTAssertEqual(loop.stoppedAtSecond ?? .infinity, 15, accuracy: 0.0001,
                       "the stop belongs on the tick the hold window closes, "
                       + "boundary, evaluation or neither: \(loop.traceDescription)")
        XCTAssertEqual(loop.status, .stopping)
    }

    func testAStandingStopCeilingRefusesTheSegmentBoundary() {
        // Finding 81, with its own numbers: a 10 min zone-3 segment followed by a
        // 3 min fixed 12 km/h one, a frozen 60/180 basis so the stop threshold is
        // 175 bpm, and the user 14 s into a breach on the segment's last tick. The
        // tally was one second short of its window, no evaluation was due, and the
        // boundary wrote 12.0 km/h into a person the app was a second away from
        // judging unsafe — into a segment with no governor run, so nothing
        // downstream would ever evaluate the rung that stops the belt.
        let next = WorkoutSegment(name: "Fast", duration: 180, targetSpeedKmh: 12.0,
                                  targetIncline: 0)
        var loop = WiringLoop(run: governedRun(at: command(6.0)), command: command(6.0),
                              basis: basis)
        loop.heartRate = 176 // one bpm above the 175 stop ceiling
        loop.advance(seconds: 14, thenBeginning: nil)
        XCTAssertFalse(loop.didStop, "14 s is inside the 15 s hold window")
        XCTAssertEqual(loop.tallies.secondsAboveStopCeiling, 14, accuracy: 0.0001)
        XCTAssertFalse(loop.isEvaluationDue,
                       "the reproduction needs the boundary to land between evaluations")
        // The segment's last tick, and then the boundary the runner would take.
        loop.advance(seconds: 1, thenBeginning: next)
        XCTAssertTrue(loop.didStop, "the stop ceiling did not fire: \(loop.traceDescription)")
        XCTAssertEqual(loop.stoppedAtSecond ?? .infinity, 15, accuracy: 0.0001)
        XCTAssertEqual(loop.status, .stopping)
        // 5.8 and not 12.0: the force-down ceiling had already stepped the entry's
        // 6.0 down by one 0.2 km/h step at the 10 s evaluation, and the belt never
        // heard about the next segment.
        XCTAssertEqual(loop.appCommand, command(5.8),
                       "the boundary wrote the next segment's 12.0 km/h anyway")
    }

    func testTheStopCeilingFiresOnAFixedSegmentOfAGovernedWorkout() {
        // The other half of finding 81: the second segment of that program has no
        // governor run at all, so read inside the ladder the stop was never
        // evaluated. It is a property of the person on the belt, so within a
        // workout the loop is armed for it is read at workout scope from the tally
        // alone — a fixed segment included.
        var loop = WiringLoop(run: nil, command: command(12.0), basis: basis)
        loop.heartRate = 176
        loop.beginSegment(fixedSegment())
        XCTAssertNil(loop.run, "the gate must refuse a fixed segment")
        loop.advance(seconds: 15, thenBeginning: nil)
        XCTAssertTrue(loop.didStop, "the stop never fired")
        XCTAssertEqual(loop.stoppedAtSecond ?? .infinity, 15, accuracy: 0.0001)
    }

    func testWithTheOptInOffNothingAboutHeartRateTouchesTheBelt() {
        // **Inverted deliberately.** This test used to assert the opposite — that
        // the 97% stop fires on a heart-rate segment with the opt-in *off* — and
        // locking that in was finding 100: the 92% force-down and the 97% stop
        // armed on every program workout, so a user who had never switched
        // heart-rate control on, and to whom the app had never disclosed that it
        // acts on heart rate, got their belt stopped mid-run on a `220 - age`
        // estimate.
        //
        // Spec section 4, "The ceilings belong to the opt-in", is now the
        // contract, and the reasoning matters because a ceiling can only ever slow
        // the belt: stopping someone's belt mid-run is itself a hazard, and the
        // number it stops on is an estimate this release has already proved can be
        // badly wrong. The ceilings exist to protect a user *from the governor*;
        // when the governor is not driving, the user is.
        var loop = WiringLoop(run: nil, command: command(12.0), basis: basis,
                              isControlEnabled: false)
        loop.heartRate = 200 // above every ceiling any basis could produce
        loop.beginSegment(heartRateSegment(), isControlEnabled: false)
        XCTAssertNil(loop.run, "the gate must refuse a segment with the opt-in off")
        XCTAssertNil(loop.session, "no session means no clock for a ceiling to fire on")
        XCTAssertEqual(loop.status, .controlOff)
        loop.advance(seconds: 600, thenBeginning: nil)
        XCTAssertFalse(loop.didStop, "the stop fired with heart-rate control off")
        XCTAssertEqual(loop.writes, [], "a write happened with heart-rate control off")
        XCTAssertEqual(loop.tallies, HeartRateGovernor.Tallies(),
                       "ten minutes above 97% and not one second was counted")
        // The segment ran fixed at its own start command, which is exactly what
        // the opt-in's own rule says it does.
        XCTAssertEqual(loop.appCommand, command(6.0))
    }

    func testTheOptInGoingOffMidSegmentTakesBothCeilingsWithIt() {
        // **Inverted deliberately**, and for the same ruling: this used to assert
        // that the stop still fires after a surrender. It cannot, or the brakes
        // would depend on whether the user switched the feature off before the
        // workout or during it — and "do not steer my belt" is the same
        // instruction either way.
        var loop = WiringLoop(run: governedRun(at: command(8.0)), command: command(8.0),
                              basis: basis)
        loop.heartRate = 176
        loop.advance(seconds: 10) // the clocks were running while control was on
        XCTAssertGreaterThan(loop.tallies.secondsAboveStopCeiling, 0)
        loop.surrender()
        // Zeroed rather than frozen: a tally left standing is a ceiling waiting to
        // clamp the next segment boundary.
        XCTAssertEqual(loop.tallies, HeartRateGovernor.Tallies())
        loop.advance(seconds: 600, thenBeginning: nil)
        XCTAssertFalse(loop.didStop, "the stop fired after heart-rate control went off")
        XCTAssertEqual(loop.tallies, HeartRateGovernor.Tallies())
        // And the run survives, inert, so a later resume still restates the
        // loop's own last command rather than the segment's programmed start
        // (finding 68).
        XCTAssertEqual(loop.run?.isSurrendered, true)
    }

    func testSwitchingTheOptInBackOnStartsAFreshSessionRatherThanInheritingDeadClocks() {
        // `isControlOn` never goes back to true, so the next segment boundary that
        // finds control on builds a new session. Inheriting the surrendered one
        // would arm a workout that is being steered again with clocks that can no
        // longer move.
        var surrendered = Session()
        surrendered.tallies.secondsAboveStopCeiling = 99
        surrendered.surrender()
        XCTAssertFalse(surrendered.isControlOn)
        let continued = Session.continuing(surrendered)
        XCTAssertTrue(continued.isControlOn)
        XCTAssertEqual(continued.tallies, Governor.Tallies())
        // A session control is still on for is continued as it stands: that is
        // finding 64, and it is what carries the person's clocks over a boundary.
        var live = Session()
        live.tallies.secondsAboveStopCeiling = 12
        XCTAssertEqual(Session.continuing(live).tallies.secondsAboveStopCeiling, 12)
        XCTAssertTrue(Session.continuing(nil).isControlOn)
    }

    func testOnlyAProgramThatAsksForHeartRateControlArmsTheCeilings() {
        // The ruling's own complaint had two halves, and the opt-in only answers
        // one of them: the ceilings also armed "on programs containing no
        // heart-rate segment". Same reasoning — there is no governor there for a
        // ceiling to protect anybody from.
        XCTAssertFalse(ProgramRunner.isHeartRateDriven(
            WorkoutProgram(name: "Plain", segments: [fixedSegment(), fixedSegment()])))
        XCTAssertTrue(ProgramRunner.isHeartRateDriven(
            WorkoutProgram(name: "Mixed", segments: [fixedSegment(), heartRateSegment()])))
        // Every built-in program is a plain one, so none of them arms a ceiling.
        for program in WorkoutProgram.builtIn {
            XCTAssertFalse(ProgramRunner.isHeartRateDriven(program), program.name)
        }
    }

    func testTheStopCeilingIsReadFromTheTallyAlone() {
        var session = Session()
        session.tallies.secondsAboveStopCeiling = HeartRateGovernor.stopHoldSeconds - 0.001
        XCTAssertFalse(ProgramRunner.isStopCeilingReached(session))
        session.tallies.secondsAboveStopCeiling = HeartRateGovernor.stopHoldSeconds
        XCTAssertTrue(ProgramRunner.isStopCeilingReached(session))
        // No run, no band, no bounds, no basis in hand: the tally is the whole
        // question, which is what makes it answerable at workout scope.
        XCTAssertNil(session.run)
        XCTAssertNil(session.basis)
    }

    func testASegmentBoundaryCannotRaiseTheLoadWhileTheCeilingTallyStands() {
        // Finding 82, with its own numbers: a 60 s recovery at 6.0 km/h followed
        // by a 12.0 km/h segment, the person at 94% of the frozen 180 — 169 bpm,
        // above the 166 force-down ceiling and below the 175 stop — with the
        // force-down tally standing at 8 s. The boundary used to write 12.0
        // unconditionally: a 6 km/h acceleration into somebody already above the
        // line, which the ceiling then unwound at 0.2 km/h every 10 s.
        let next = WorkoutSegment(name: "Fast", duration: 180, targetSpeedKmh: 12.0,
                                  targetIncline: 0)
        var loop = WiringLoop(run: nil, command: command(6.0), basis: basis)
        loop.heartRate = 169
        loop.advance(seconds: 8, thenBeginning: next)
        XCTAssertEqual(loop.tallies.secondsAboveForceDownCeiling, 8, accuracy: 0.0001,
                       "the reproduction needs the tally standing and the ceiling unfired")
        XCTAssertEqual(loop.appCommand, command(6.0),
                       "the boundary raised the load over the force-down ceiling")
        XCTAssertEqual(loop.status, .ceiling,
                       "a belt that did not speed up at a boundary has to say why")
        XCTAssertFalse(loop.didStop, "169 bpm is below the 175 stop ceiling")
    }

    func testABoundaryWritesTheProgrammedEntryOnceTheCeilingIsClear() {
        // The control case: nothing standing, so nothing is clamped. The clamp is
        // the ceiling's authority over the boundary, not a new speed limit.
        let next = WorkoutSegment(name: "Fast", duration: 180, targetSpeedKmh: 12.0,
                                  targetIncline: 0)
        var loop = WiringLoop(run: nil, command: command(6.0), basis: basis)
        loop.heartRate = 140 // inside nobody's ceiling
        loop.advance(seconds: 8, thenBeginning: next)
        XCTAssertEqual(loop.tallies.secondsAboveForceDownCeiling, 0, accuracy: 0.0001)
        XCTAssertEqual(loop.appCommand, command(12.0))
        XCTAssertNil(loop.status, "a fixed segment nothing clamped has nothing to report")
    }

    func testTheBoundaryClampOnlyEverReduces() {
        let programmed = command(12.0, incline: 4)
        let held = command(6.0, incline: 1)
        XCTAssertEqual(ProgramRunner.boundedByCeiling(programmed, notAbove: held,
                                                      isCeilingStanding: true), held)
        XCTAssertEqual(ProgramRunner.boundedByCeiling(programmed, notAbove: held,
                                                      isCeilingStanding: false), programmed)
        // It clamps, so it can never raise either axis.
        XCTAssertEqual(ProgramRunner.boundedByCeiling(held, notAbove: programmed,
                                                      isCeilingStanding: true), held)
        // Per axis, and in tenths — one quantum is 0.09999999999999964 as a Double.
        XCTAssertEqual(ProgramRunner.boundedByCeiling(command(8.3, incline: 0),
                                                      notAbove: command(8.2, incline: 5),
                                                      isCeilingStanding: true),
                       command(8.2, incline: 0))
    }

    func testTheBoundaryIsClampedByTheBeltAndNotByTheAppsCommandAlone() {
        // Finding 101, as the arithmetic. Fact 1 alone was the bug: after a
        // console hand-back nothing ever lowers the app's own command, so it
        // diverges upward from the belt and stays there.
        let appCommand = command(10.0, incline: 4)
        let belt = Governor.BeltFacts(measured: command(6.0, incline: 1))
        XCTAssertEqual(ProgramRunner.ceilingReference(appCommand: appCommand, belt: belt),
                       command(6.0, incline: 1),
                       "the boundary must be clamped by min(fact 1, fact 2) per axis")
        // Per axis, in either direction: the belt above the command on one axis
        // and below it on the other still yields the lower of the two on each.
        XCTAssertEqual(ProgramRunner.ceilingReference(
            appCommand: command(6.0, incline: 4),
            belt: Governor.BeltFacts(measured: command(9.0, incline: 1))),
                       command(6.0, incline: 1))
        // Nothing measured: fact 1 is the only number there is.
        XCTAssertEqual(ProgramRunner.ceilingReference(appCommand: appCommand,
                                                      belt: .unobserved), appCommand)
        // A measured 0 km/h is a belt that has stopped, not a target the machine
        // can be set to — the same asymmetry `boundedByStop` makes. A 0% incline
        // is a legitimate setting and is folded in.
        XCTAssertEqual(ProgramRunner.ceilingReference(
            appCommand: appCommand,
            belt: Governor.BeltFacts(measured: command(0, incline: 0))),
                       command(10.0, incline: 0))
    }

    func testASegmentBoundaryCannotRaiseTheLoadOverAHandBackWhileTheCeilingStands() {
        // Finding 101 end to end, with its own numbers. Segment 1 is governed with
        // an entry write of 10.0; at 0:06 the user dials the console down to 6.0
        // and the hand-back latches; the heart rate crosses the 166 force-down
        // ceiling on the segment's last second, so the tally stands but the rule
        // has not fired and nothing has lowered the app's own 10.0. The boundary
        // into a 12.0 km/h segment then used to write that 10.0: four km/h added
        // to a belt whose user is above the line the dashboard was reporting.
        let target = speedTarget(min: 4.0, max: 12.0, start: 10.0)
        let next = WorkoutSegment(name: "Fast", duration: 180, targetSpeedKmh: 12.0,
                                  targetIncline: 0)
        var loop = WiringLoop(run: governedRun(target, at: command(10.0)),
                              command: command(10.0), basis: basis)
        loop.heartRate = 150 // inside the 144–155 band: nothing to steer
        loop.advance(seconds: 6)
        loop.consoleSetsSpeed(6.0)
        loop.advance(seconds: 33)
        XCTAssertEqual(loop.run?.isHandedBack, true, loop.traceDescription)
        XCTAssertEqual(loop.appCommand, command(10.0),
                       "the reproduction needs fact 1 left at 10.0 by the hand-back")
        // One second above the force-down ceiling: standing, unfired, nothing
        // written. Then the boundary.
        loop.heartRate = 169
        loop.advance(seconds: 1, thenBeginning: next)
        XCTAssertEqual(loop.appCommand, command(6.0),
                       "the boundary wrote the app's own command over the belt's 6.0")
        XCTAssertEqual(loop.status, .ceiling,
                       "a belt that did not speed up at a boundary has to say why")
        XCTAssertFalse(loop.didStop, "169 bpm is below the 175 stop ceiling")
    }

    func testTheForceDownTallyAndItsLatchBothStandTheBoundaryDown() {
        var session = Session()
        XCTAssertFalse(ProgramRunner.isForceDownCeilingStanding(session))
        XCTAssertFalse(ProgramRunner.isForceDownCeilingStanding(nil))
        // The person above the line this second.
        session.tallies.secondsAboveForceDownCeiling = 0.5
        XCTAssertTrue(ProgramRunner.isForceDownCeilingStanding(session))
        // And the ceiling having already had to pull the load back in the segment
        // that is ending, which is evidence about the load the next one raises.
        session.tallies.secondsAboveForceDownCeiling = 0
        session.tallies.didForceDown = true
        XCTAssertTrue(ProgramRunner.isForceDownCeilingStanding(session))
    }

    // MARK: - What the runner may act on

    func testOnlyTheRulesThatCannotAddLoadSurviveAHandBack() {
        let next = command(6.8)
        // Both ceilings reduce load or stop the belt, so a user who nudged the
        // dial once keeps the gentle step-down rather than only the belt stop.
        XCTAssertEqual(ProgramRunner.action(for: .emergencyStop, isHandedBack: true), .stop)
        XCTAssertEqual(ProgramRunner.action(for: .adjust(command: next,
                                                         reason: .ceilingForceDown),
                                            isHandedBack: true), .write(next))
        // And so does the feed-loss fallback, which is a **tightening**: this
        // assertion used to demand `.none`, so a falsely inferred person silently
        // disabled the one rule that answers a dead feed (spec section 4, "The
        // fallback survives a hand-back, for the same reason the ceilings do";
        // finding 98). The governor's ladder already ranked `feedLostFallback`
        // above `manualControl`, so refusing it here was this function
        // contradicting the law it acts on.
        XCTAssertEqual(ProgramRunner.action(for: .fallback(command: next),
                                            isHandedBack: true), .write(next))
        XCTAssertEqual(ProgramRunner.action(for: .fallback(command: next),
                                            isHandedBack: false), .write(next))
        // Everything else is refused for the rest of the segment.
        for reason in [Governor.Reason.belowBand, .aboveBand, .outOfBounds] {
            XCTAssertEqual(ProgramRunner.action(for: .adjust(command: next, reason: reason),
                                                isHandedBack: true), ProgramRunner.GovernorAction.none,
                           "\(reason) must not write after a hand-back")
            XCTAssertEqual(ProgramRunner.action(for: .adjust(command: next, reason: reason),
                                                isHandedBack: false), .write(next))
        }
        XCTAssertEqual(ProgramRunner.action(for: .manualControl, isHandedBack: false),
                       .handBack)
        XCTAssertEqual(ProgramRunner.action(for: .frozen, isHandedBack: false),
                       ProgramRunner.GovernorAction.none)
        XCTAssertEqual(ProgramRunner.action(for: .hold(reason: .insideBand),
                                            isHandedBack: false), ProgramRunner.GovernorAction.none)
    }

    func testEveryDecisionHasADashboardStatus() {
        XCTAssertEqual(ProgramRunner.status(for: .hold(reason: .insideBand),
                                            isHandedBack: false), .holding)
        XCTAssertEqual(ProgramRunner.status(for: .hold(reason: .settling),
                                            isHandedBack: false), .holding)
        XCTAssertEqual(ProgramRunner.status(for: .hold(reason: .hysteresis),
                                            isHandedBack: false), .holding)
        XCTAssertEqual(ProgramRunner.status(for: .hold(reason: .atBound),
                                            isHandedBack: false), .holding)
        XCTAssertEqual(ProgramRunner.status(for: .adjust(command: command(6.2),
                                                         reason: .belowBand),
                                            isHandedBack: false), .adjusting)
        XCTAssertEqual(ProgramRunner.status(for: .adjust(command: command(5.8),
                                                         reason: .outOfBounds),
                                            isHandedBack: false), .adjusting)
        XCTAssertEqual(ProgramRunner.status(for: .hold(reason: .targetUnreachable),
                                            isHandedBack: false), .targetNotReached)
        // A band the loop is forbidden to chase is its own answer, not "holding":
        // the segment runs fixed and the dashboard has to say why.
        XCTAssertEqual(ProgramRunner.status(for: .hold(reason: .bandNotSteerable),
                                            isHandedBack: false), .bandNotSteerable)
        XCTAssertEqual(ProgramRunner.status(for: .frozen, isHandedBack: false), .frozen)
        XCTAssertEqual(ProgramRunner.status(for: .fallback(command: command(4.5)),
                                            isHandedBack: false), .fallback)
        XCTAssertEqual(ProgramRunner.status(for: .manualControl, isHandedBack: false),
                       .handedBack)
        XCTAssertEqual(ProgramRunner.status(for: .emergencyStop, isHandedBack: false),
                       .stopping)
        // A ceiling is reported as a ceiling even after a hand-back, because it is
        // still what is happening; everything else reads as the hand-back.
        XCTAssertEqual(ProgramRunner.status(for: .hold(reason: .ceilingForceDown),
                                            isHandedBack: true), .ceiling)
        // The fallback too, now that it writes under a hand-back: "control is
        // yours" while the app is lowering the belt is the one thing the dashboard
        // must not say (finding 98). A **tightening** of this test: the assertion
        // did not exist before, and the case fell through to `.handedBack`.
        XCTAssertEqual(ProgramRunner.status(for: .fallback(command: command(4.5)),
                                            isHandedBack: true), .fallback)
        XCTAssertEqual(ProgramRunner.status(for: .hold(reason: .insideBand),
                                            isHandedBack: true), .handedBack)
        // `.frozen` stays *below* the hand-back, mirroring the ladder — which puts
        // `feedLostFallback` above `manualControl` and `feedLostFreeze` below it —
        // and a freeze writes nothing, so the hand-back is the truthful label.
        XCTAssertEqual(ProgramRunner.status(for: .frozen, isHandedBack: true), .handedBack)
    }

    func testTheNonActuatedAxisIsTheMinimumOfFactOneAndFactTwo() {
        // **The runner half of finding 124, and the inversion it mandates.** This
        // used to assert that a fallback firing while the speed axis was still
        // travelling toward the segment's own 8.0 came out at 8.0 rather than at the
        // 5.0 the belt was reporting. The spec now rules that the reference is
        // `min(fact 1, fact 2)` per axis with no travelling exception, because the
        // exception is a window in which a brake re-commands a remembered value and
        // a person holding the belt away from it is what keeps the window open. So
        // the fallback comes out at the belt's 5.0, travelling or not.
        let target = inclineTarget(startSpeed: 8.0, startLevel: 6)
        let run = Run(target: target, lastAppliedChange: .settled(at: command(8.0, incline: 6)))
        var session = Session()
        session.beginSegment(run)
        session.tallies.secondsWithoutHeartRate = Governor.feedLossFallbackSeconds
        let belt = Governor.BeltFacts(measured: command(5.0, incline: 2))
        let input = ProgramRunner.governorInput(session, run: run, basis: basis, heartRate: 0,
                                                command: command(5.0, incline: 2),
                                                appCommand: command(8.0, incline: 6),
                                                belt: belt, limits: limits)
        guard case .fallback(let wired) = Governor.decide(input) else {
            return XCTFail("30 s without a reading is the fallback")
        }
        XCTAssertEqual(wired.speedKmh, 5.0, accuracy: 0.0001,
                       "a brake may not raise the axis it is not steering")
        // `Input.appCommand` is still wired, and still load-bearing: it is the one
        // copy of fact 1 that an in-app "−" press brings down at once, and it can
        // only ever lower the reference.
        var lowered = input
        lowered.appCommand = command(4.0, incline: 1)
        guard case .fallback(let held) = Governor.decide(lowered) else {
            return XCTFail("the same input, one field lower, is the same decision")
        }
        XCTAssertEqual(held.speedKmh, 4.0, accuracy: 0.0001)
        // The actuated axis is unaffected either way: a brake bounded by the
        // device, so the incline comes all the way down.
        XCTAssertEqual(wired.incline, 0)
        XCTAssertEqual(held.incline, 0)
    }

    // MARK: - A stale treadmill link

    func testAStaleLinkRefusesEveryWriteAndKeepsOnlyTheStop() {
        // **Inverted from "refuses only the writes that add load" (finding 136).**
        // The old rule refused `.belowBand` alone, reasoning that every other write
        // is a reduction against the app's own last command by construction. True,
        // and the wrong invariant: while the link is stale the measured speed, the
        // client's target and the app's command are *all* remembered numbers, so a
        // reduction against a remembered command can be well above the speed the
        // user has just dialled down unseen — the belt accelerates back toward the
        // app's own number while the dashboard reports a reduction.
        for decision in [Governor.Decision.adjust(command: command(9.2), reason: .belowBand),
                         .adjust(command: command(5.8), reason: .aboveBand),
                         .adjust(command: command(5.8), reason: .ceilingForceDown),
                         .adjust(command: command(5.8), reason: .outOfBounds),
                         .fallback(command: command(4.5))] {
            XCTAssertTrue(ProgramRunner.isRefusedWhileStale(decision),
                          "\(decision) was computed from remembered numbers")
            XCTAssertEqual(ProgramRunner.action(for: decision, isHandedBack: false,
                                                isLinkStale: true),
                           ProgramRunner.GovernorAction.none)
            // And it has to *read* as the stale link rather than as the decision it
            // swallowed: "slowing you down" while nothing was sent is the one thing
            // the dashboard must not say.
            XCTAssertEqual(ProgramRunner.status(for: decision, isHandedBack: false,
                                                isLinkStale: true),
                           .linkStale)
        }
        // The stop survives: it writes no target, it needs no trustworthy picture of
        // anything, and the radio gap that lets a heart rate sit unobserved at 97%
        // of the frozen maximum is exactly the gap that would otherwise silence it.
        XCTAssertFalse(ProgramRunner.isRefusedWhileStale(.emergencyStop))
        XCTAssertEqual(ProgramRunner.action(for: .emergencyStop, isHandedBack: false,
                                            isLinkStale: true),
                       .stop)
        XCTAssertEqual(ProgramRunner.status(for: .emergencyStop, isHandedBack: false,
                                            isLinkStale: true),
                       .stopping)
        // Nor does a stale link swallow the two decisions that write nothing anyway:
        // a hand-back only ever takes authority away from the loop, and a freeze is
        // the loop declining to act.
        for decision in [Governor.Decision.manualControl, .frozen,
                         .hold(reason: .ceilingForceDown)] {
            XCTAssertFalse(ProgramRunner.isRefusedWhileStale(decision), "\(decision)")
        }
    }

    func testAStaleLinkCannotStepUpFromARememberedTarget() {
        // Reproduction: backgrounded on bluetooth-central, notifications stop, and
        // the user taps the console down. No frame carries that, so the client's
        // target is still the app's own last write and the manual test sees
        // nothing — while the Watch feed is a different feed and legitimately
        // fresh. Writes still succeed in that state, so the step would be
        // delivered to a console the user had already turned down.
        var loop = WiringLoop(run: governedRun(at: command(9.0)), command: command(9.0),
                             basis: basis)
        loop.isLinkStale = true
        loop.heartRate = 138 // below the 144–155 band: the loop wants more load
        loop.advance(seconds: 600)
        XCTAssertEqual(loop.writes, [])
        XCTAssertEqual(loop.command, command(9.0))
        XCTAssertEqual(loop.status, .linkStale)
    }

    func testAStaleLinkKeepsTheHeartRateTalliesAdvancingButRefusesTheReduction() {
        var loop = WiringLoop(run: governedRun(at: command(6.0)), command: command(6.0),
                             basis: basis)
        loop.isLinkStale = true
        loop.heartRate = 170 // at 92% of the frozen maximum
        loop.advance(seconds: 10)
        // The heart rate arrives on a feed the treadmill link has nothing to do
        // with, so its clocks keep running — that part is unchanged, and it is why
        // this is not simply "staleness stops everything".
        XCTAssertEqual(loop.tallies.secondsAboveForceDownCeiling, 10, accuracy: 0.0001)
        // **Inverted (finding 136).** The ceiling's reduction used to be let through
        // as "a reduction against the app's own command by construction". While the
        // link is stale that command is itself a memory, and 5.8 km/h can be *above*
        // the speed the console has been dialled to unseen — the app accelerating
        // the belt while the dashboard reads "slowing down".
        XCTAssertEqual(loop.writes, [])
        XCTAssertEqual(loop.command, command(6.0))
        XCTAssertEqual(loop.status, .linkStale)
        // And the stop still fires: it is the one rule a dropped write would silence,
        // and it needs no trustworthy picture of the belt at all.
        loop.heartRate = 176
        loop.advance(seconds: 30)
        XCTAssertTrue(loop.didStop)
        XCTAssertEqual(loop.status, .stopping)
    }

    func testAStaleLinkRefusesTheFallbackOntoADialTheAppCannotSee() {
        // **Finding 136's own reproduction.** The user dials the console down to a
        // walk while the link is stale — no frame carries it, so the measured speed,
        // the client's target and the app's own command are all the memory of a belt
        // at 9.0 — and then the Watch feed dies as well. `min(remembered command,
        // declared fallback)` is 4.5 km/h, which is a *reduction* against every
        // number the app holds and an **acceleration** on the belt the person is
        // standing on. The dashboard would have said "fallback" while the belt sped
        // up.
        var loop = WiringLoop(run: governedRun(at: command(9.0)), command: command(9.0),
                             basis: basis)
        loop.isLinkStale = true
        loop.heartRate = 0 // no fresh Watch reading either
        loop.consoleSetsSpeedUnseen(4.0)
        loop.advance(seconds: 40) // past the 30 s feed-loss window
        XCTAssertEqual(loop.writes, [], loop.traceDescription)
        XCTAssertEqual(loop.command, command(9.0))
        XCTAssertEqual(loop.status, .linkStale)
        // Non-vacuity: on a fresh link the same run does fall back.
        var fresh = WiringLoop(run: governedRun(at: command(9.0)), command: command(9.0),
                              basis: basis)
        fresh.heartRate = 0
        fresh.advance(seconds: 30) // the 30 s feed-loss window, to the second
        XCTAssertEqual(fresh.writes, [command(4.5)])
        XCTAssertEqual(fresh.status, .fallback)
    }

    // MARK: - The loop, wired

    func testALostFeedFreezesThenFallsBackAndNeverAccelerates() {
        var loop = WiringLoop(run: governedRun(at: command(6.0)), command: command(6.0),
                             basis: basis)
        loop.heartRate = 150 // inside the band: nothing to do
        loop.advance(seconds: 120)
        XCTAssertEqual(loop.writes, [])
        loop.heartRate = 0 // the Watch goes quiet
        loop.advance(seconds: 20)
        XCTAssertEqual(loop.status, .frozen)
        XCTAssertEqual(loop.command, command(6.0))
        loop.advance(seconds: 10) // 30 s without a reading
        XCTAssertEqual(loop.status, .fallback)
        XCTAssertEqual(loop.command, command(4.5))
        // And it sits there: the fallback is written once, not walked downward.
        loop.advance(seconds: 120)
        XCTAssertEqual(loop.writes, [command(4.5)])
        // A missing reading may only ever lower the command.
        XCTAssertLessThanOrEqual(loop.maxCommandedSpeedKmh, 6.0 + 0.0001)
    }

    func testAConsoleChangeHandsControlBackForTheRestOfTheSegment() {
        var loop = WiringLoop(run: governedRun(at: command(6.0)), command: command(6.0),
                             basis: basis)
        loop.heartRate = 150
        loop.advance(seconds: 120)
        loop.consoleSetsSpeed(7.0) // the user turns the dial mid-segment
        loop.advance(seconds: 10)
        XCTAssertEqual(loop.run?.isHandedBack, true)
        XCTAssertEqual(loop.status, .handedBack)
        // And now the one thing that must not happen: the loop pushing back.
        loop.heartRate = 100 // far below the band for five minutes
        loop.advance(seconds: 300)
        XCTAssertEqual(loop.writes, [])
        XCTAssertEqual(loop.command, command(7.0))
        XCTAssertEqual(loop.status, .handedBack)
    }

    func testADecisiveConsoleReductionHandsBackWhileTheBeltIsStillTravelling() {
        // **Finding 134, end to end.** A two km/h console reduction is about four
        // seconds of belt travel; evaluations sit on a ten-second grid, so one of
        // them lands mid-travel. The verdict used to need two seconds of settling
        // *at* the value the person had dialled, so that evaluation saw nothing:
        // it wrote one step from the mid-travel measurement, which turned the belt
        // around before it ever reached the person's value, and the pending
        // departure was then discarded at the plateau the app's own write produced.
        // A 2 km/h reduction became 0.3 and no hand-back fired for the rest of the
        // segment.
        var plant = LaggedHeartRatePlant()
        plant.speedKmh = 8.0
        plant.heartRateBpm = plant.restingBpm + plant.bpmPerKmh * 8.0 // 148 bpm
        // A band above the reading, so the loop actively wants more load: that is
        // what made the mid-travel write an acceleration into a person's reduction.
        let target = speedTarget(low: 152, high: 165, min: 4.0, max: 12.0, start: 8.0)
        var loop = WiringLoop(run: governedRun(target, at: command(8.0)),
                             command: command(8.0), basis: basis, plant: plant)
        loop.advance(seconds: 98) // the next evaluation is two seconds away
        let beforeTheDial = loop.writes
        XCTAssertFalse(beforeTheDial.isEmpty, "non-vacuity: the loop was steering")
        loop.consoleSetsSpeed(6.0) // the dial goes down two km/h
        loop.advance(seconds: 2) // the evaluation lands with the belt around 7 km/h
        XCTAssertEqual(loop.run?.isHandedBack, true,
                       "the departure is decisive now, not in four seconds: "
                       + loop.traceDescription)
        XCTAssertEqual(loop.status, .handedBack)
        XCTAssertEqual(loop.writes, beforeTheDial,
                       "nothing may be written from a mid-travel measurement")
        // And the belt goes where the person sent it instead of being turned around.
        loop.advance(seconds: 120)
        XCTAssertEqual(loop.plant?.speedKmh ?? 0, 6.0, accuracy: 0.05, loop.traceDescription)
        XCTAssertEqual(loop.writes, beforeTheDial)
    }

    func testAConsoleInclineChangeHandsControlBackOnASpeedSegmentToo() {
        // The axis the deleted incline dead band made blind (finding 75): a
        // one-level change was invisible for ever, because the condition was not
        // time-based, and the loop then pushed the incline back up past the user's
        // hand. The segment here steers speed, so the incline is the pass-through
        // axis — the one a reduction used to re-command from an observation.
        var loop = WiringLoop(run: governedRun(at: command(6.0, incline: 2)),
                             command: command(6.0, incline: 2), basis: basis)
        loop.heartRate = 150
        loop.advance(seconds: 120)
        loop.consoleSetsIncline(4) // two levels: what the spec calls decisive
        loop.advance(seconds: 10)
        XCTAssertEqual(loop.run?.isHandedBack, true)
        XCTAssertEqual(loop.status, .handedBack)
        loop.heartRate = 100
        loop.advance(seconds: 300)
        XCTAssertEqual(loop.writes, [], loop.traceDescription)
    }

    func testAHandBackKeepsTheForceDownCeilingAndSurvivesIt() {
        var loop = WiringLoop(run: governedRun(at: command(6.0)), command: command(6.0),
                             basis: basis)
        loop.heartRate = 150
        loop.advance(seconds: 120)
        loop.consoleSetsSpeed(7.0)
        loop.advance(seconds: 10)
        XCTAssertEqual(loop.run?.isHandedBack, true)

        // 92% of the frozen maximum, held: the load comes down even though the
        // command being held is the user's own. One step below the *app's* own
        // last write of 6.0, not one step below the user's 7.0: a reduction may
        // never come out above what the app itself last asked for, because the
        // number it would otherwise start from is the client's target, which
        // follows the belt's measured value and reads high exactly while the belt
        // is coming down.
        loop.heartRate = 170
        loop.advance(seconds: 10)
        XCTAssertEqual(loop.status, .ceiling)
        XCTAssertEqual(loop.command, command(5.8))
        XCTAssertEqual(loop.writes, [command(5.8)])

        // The forced reduction rewrote the app's own last command, so the user's
        // value now looks like ours. The latch is what keeps the segment theirs.
        loop.heartRate = 100
        loop.advance(seconds: 300)
        XCTAssertEqual(loop.writes, [command(5.8)])
        XCTAssertLessThanOrEqual(loop.maxCommandedSpeedKmh, 7.0 + 0.0001)
        XCTAssertEqual(loop.status, .handedBack)
    }

    func testTheHandBackIsLatchedFromTheEvidenceEvenWhenTheCeilingWins() {
        // Finding 65. The force-down rung outranks the manual-control rung and
        // rewrites the record of the app's last command, so an intervention made
        // while the 92% tally stands used to be consumed, forgotten, and the loop
        // then re-accelerated past the speed the user had set by hand.
        var loop = WiringLoop(run: governedRun(at: command(6.0)), command: command(6.0),
                             basis: basis)
        loop.heartRate = 150
        loop.advance(seconds: 120)
        // The dial goes up and the ceiling fills in the same ten seconds, so both
        // the evidence and the reduction land in one evaluation.
        loop.heartRate = 170
        loop.consoleSetsSpeed(7.0)
        loop.advance(seconds: 10)
        XCTAssertEqual(loop.status, .ceiling, "the ceiling still outranks and still writes")
        XCTAssertEqual(loop.writes, [command(5.8)])
        XCTAssertEqual(loop.run?.isHandedBack, true,
                       "the ceiling consumed the evidence of the intervention")

        // The rest of the segment is the user's, whatever the band says.
        loop.heartRate = 100
        loop.advance(seconds: 600)
        XCTAssertEqual(loop.writes, [command(5.8)])
        XCTAssertEqual(loop.status, .handedBack)
    }

    func testTheStopCeilingEndsTheWorkoutEvenAfterAHandBack() {
        var loop = WiringLoop(run: governedRun(at: command(6.0)), command: command(6.0),
                             basis: basis)
        loop.heartRate = 150
        loop.advance(seconds: 120)
        loop.consoleSetsSpeed(7.0)
        loop.advance(seconds: 10)
        XCTAssertEqual(loop.run?.isHandedBack, true)
        loop.heartRate = 176 // above 175 for longer than the 15 s hold
        loop.advance(seconds: 20)
        XCTAssertTrue(loop.didStop)
        XCTAssertEqual(loop.status, .stopping)
    }

    func testTheLoopClimbsOneStepAtATimeTowardsTheBand() {
        // Non-vacuity for everything above: with a feed, a basis, no hand-back and
        // a heart rate below the band, the loop does escalate — one 0.2 km/h step
        // per evaluation, inside the segment's bounds.
        var loop = WiringLoop(run: governedRun(at: command(6.0)), command: command(6.0),
                             basis: basis)
        loop.heartRate = 120
        loop.advance(seconds: 200)
        XCTAssertGreaterThan(loop.command.speedKmh, 6.0)
        XCTAssertLessThanOrEqual(loop.command.speedKmh, 10.0)
        for (index, write) in loop.writes.enumerated() where index > 0 {
            XCTAssertLessThanOrEqual(write.speedKmh - loop.writes[index - 1].speedKmh,
                                     Governor.maxSpeedStepKmh + 0.0001)
        }
    }

    // MARK: - Entering a segment from somewhere else

    func testASegmentEnteredFromAFasterOneKeepsGoverningAfterTheRamp() {
        // Finding 67, closed loop: a walk-to-run interval whose previous segment
        // ran at 12 km/h and which starts at 4. The belt needs sixteen seconds to
        // get there, and the client re-points its target at the belt's measured
        // speed as soon as its own ten-second window opens — so an entry change
        // recorded as "settled at 4.0" makes the first evaluation read the ramp as
        // a person and disables the loop for the whole segment.
        //
        // The basis is deliberately high: this is about the manual detection, not
        // about the ceilings, and 12 km/h on this plant is 192 bpm.
        let highBasis = HeartRateBasis(restingBpm: 60, maxBpm: 220)
        var plant = LaggedHeartRatePlant()
        plant.speedKmh = 12
        plant.heartRateBpm = plant.restingBpm + plant.bpmPerKmh * 12
        var loop = WiringLoop(run: nil, command: command(12.0), basis: highBasis, plant: plant)
        loop.beginSegment(heartRateSegment(speedTarget(start: 4.0)))
        loop.advance(seconds: 2400)
        XCTAssertFalse(loop.decisions.contains(.manualControl),
                       "a belt still travelling toward the entry command is not a person")
        XCTAssertEqual(loop.run?.isHandedBack, false)
        // And it is demonstrably still steering: 4 km/h is 104 bpm on this plant,
        // so reaching a 144–155 band means it climbed the whole way.
        XCTAssertGreaterThan(loop.command.speedKmh, 6.0)
        XCTAssertTrue((144...155).contains(loop.reading),
                      "\(loop.reading) bpm outside the band after the ramp")
    }

    func testASegmentEnteredAtADifferentInclineIsNotReadAsAPerson() {
        // The incline axis is the worse of the two: the motor takes about five
        // seconds a level, and the client used to follow it on any difference at
        // all, so a segment entering at a new incline tripped the manual test with
        // near certainty.
        let highBasis = HeartRateBasis(restingBpm: 60, maxBpm: 220)
        var plant = LaggedHeartRatePlant()
        plant.speedKmh = 6
        plant.inclineLevel = 0
        plant.heartRateBpm = plant.restingBpm + plant.bpmPerKmh * 6
        var loop = WiringLoop(run: nil, command: command(6.0), basis: highBasis, plant: plant)
        loop.beginSegment(heartRateSegment(inclineTarget(startLevel: 6)))
        loop.advance(seconds: 600)
        XCTAssertFalse(loop.decisions.contains(.manualControl),
                       "an incline motor on its way is not a person: "
                       + loop.traceDescription)
        XCTAssertEqual(loop.run?.isHandedBack, false)
        XCTAssertEqual(loop.command.speedKmh, 6.0, accuracy: 0.0001,
                       "an incline segment must never touch the speed")
    }

    // MARK: - The settle window belongs to the load, not to the app (finding 137)

    func testASubDecisiveConsoleReductionArmsTheSettleWindow() {
        // The change the app deliberately does *not* classify as a takeover: three
        // tenths, inside the confusions a console's own bias and a footfall produce.
        // The loop is allowed to keep steering — but not from a heart rate that
        // still describes the load before the dial. Armed only by the app's own
        // writes, the window let the first step out ten seconds later, which is the
        // loop pushing back on evidence that predates the change.
        var loop = WiringLoop(run: governedRun(at: command(6.0)), command: command(6.0),
                             basis: basis)
        loop.heartRate = 130 // below the 144–155 band: the loop wants more load
        loop.advance(seconds: 50) // past the segment's own settle window
        XCTAssertEqual(loop.writes.count, 1, loop.traceDescription)
        let stepped = loop.command
        loop.advance(seconds: 46) // and past the window that write opened
        XCTAssertEqual(loop.writes.count, 1)
        loop.consoleSetsSpeed(stepped.speedKmh - 0.3)
        XCTAssertEqual(loop.run?.isHandedBack, false, "three tenths is not a takeover")
        loop.advance(seconds: 10) // the evaluation the old rule wrote from
        XCTAssertEqual(loop.writes.count, 1,
                       "the reading in hand describes the load before the dial: "
                       + loop.traceDescription)
        XCTAssertEqual(loop.status, .holding)
        // Past the window the loop may steer again — and it steps from the person's
        // value rather than from its own memory, so its next command is *below*
        // where it had got to.
        loop.advance(seconds: 45)
        XCTAssertEqual(loop.writes.count, 2, loop.traceDescription)
        XCTAssertLessThan(loop.command.speedKmh, stepped.speedKmh)
    }

    // MARK: - Resuming a suspended segment

    func testAGovernedSegmentResumesAtTheLoopsCommandNotItsStartSpeed() {
        // The segment was programmed at 8.0 and forced down to 6.4 by a ceiling.
        // Re-applying the plan on a resume would put the reduction straight back.
        var run = governedRun(speedTarget(start: 8.0), at: command(8.0))
        run.lastAppliedChange = Change(from: command(6.6), to: command(6.4))
        let segment = heartRateSegment(speedTarget(start: 8.0))
        XCTAssertEqual(ProgramRunner.resumeCommand(for: segment, run: run), command(6.4))
    }

    func testAHandedBackSegmentIsNotWrittenOnResume() {
        var run = governedRun(at: command(6.0))
        run.isHandedBack = true
        XCTAssertNil(ProgramRunner.resumeCommand(for: heartRateSegment(), run: run))
    }

    func testAPlainSegmentStillResumesAtItsProgrammedTarget() {
        // Phase 1's behaviour, unchanged: a fixed segment has no run at all.
        XCTAssertEqual(ProgramRunner.resumeCommand(for: fixedSegment(), run: nil),
                       command(8.0, incline: 1))
    }

    func testSwitchingControlOffMidSegmentCannotAccelerateOnResume() {
        // Finding 68: the segment is programmed at 10.0 and the loop has forced it
        // down to 7.0 because the user hit 92% of their maximum. They pause on the
        // console and switch heart-rate control off — the natural reaction to
        // "stop steering my belt" — and then restart the belt.
        let target = speedTarget(min: 6.0, max: 12.0, start: 10.0)
        var run = governedRun(target, at: command(10.0))
        run.lastAppliedChange = Change(from: command(7.2), to: command(7.0))
        run.isSurrendered = true
        let segment = heartRateSegment(target)
        XCTAssertEqual(ProgramRunner.resumeCommand(for: segment, run: run), command(7.0))
        // Dropping the run instead is what wrote the plan's 10.0 back — three
        // km/h faster than the speed the app had chosen for their safety.
        XCTAssertEqual(ProgramRunner.resumeCommand(for: segment, run: nil), command(10.0))
    }

    func testAResumeRefreshesTheHandBackLatchFromTheEvidence() {
        // **Finding 135.** The latch is mutated in exactly one place — `steer`, on
        // the evaluation grid — and `steer` does not run while the program is
        // suspended, so at a resume it was stale by exactly the amount that
        // matters.
        let run = governedRun(at: command(8.0))
        let segment = heartRateSegment()
        XCTAssertEqual(ProgramRunner.resumeCommand(for: segment, run: run), command(8.0))
        let dialled = ProgramRunner.resuming(
            run, belt: Governor.BeltFacts(measured: command(6.0), isSpeedSetByHand: true))
        XCTAssertTrue(dialled.isHandedBack)
        XCTAssertNil(ProgramRunner.resumeCommand(for: segment, run: dialled),
                     "a segment the user took over is not written at all")
        // A suspension nobody touched still resumes at the loop's own command, and
        // the refresh never un-latches a hand-back either.
        XCTAssertFalse(ProgramRunner.resuming(run, belt: .unobserved).isHandedBack)
        var handed = run
        handed.isHandedBack = true
        XCTAssertTrue(ProgramRunner.resuming(handed, belt: .unobserved).isHandedBack)
    }

    func testASpeedSetByHandDuringASuspensionSurvivesTheResume() {
        // The reproduction: the user pauses at the console, dials the belt down from
        // 6.0 to 5.0, and starts it again. No evaluation runs in between — that is
        // what being suspended means — while the client goes on seeing frames and
        // inferring the dial from them on its own poll. The resume used to write the
        // loop's remembered 6.0 straight back over the 5.0 they had just chosen.
        let segment = heartRateSegment()
        var loop = WiringLoop(run: governedRun(at: command(6.0)), command: command(6.0),
                             basis: basis)
        loop.heartRate = 150 // inside the band: the loop itself wants nothing
        loop.advance(seconds: 120)
        XCTAssertEqual(loop.writes, [])
        loop.consoleSetsSpeed(5.0)
        loop.observeWhileSuspended(seconds: 2)
        loop.resume(segment)
        XCTAssertEqual(loop.writes, [], "the resume wrote over a speed the user set")
        XCTAssertEqual(loop.run?.isHandedBack, true)
        XCTAssertEqual(loop.status, .handedBack)
        // Non-vacuity: with nobody's hand on the dial the same resume does write the
        // loop's own last command, which is what finding 68 put there.
        var untouched = WiringLoop(run: governedRun(at: command(6.0)), command: command(6.0),
                                  basis: basis)
        untouched.heartRate = 150
        untouched.advance(seconds: 120)
        untouched.observeWhileSuspended(seconds: 2)
        untouched.resume(segment)
        XCTAssertEqual(untouched.writes, [command(6.0)])
        XCTAssertEqual(untouched.run?.isHandedBack, false)
    }

    func testASurrenderedRunEvaluatesNothingAndWritesNothing() {
        var run = governedRun(at: command(6.0))
        run.isSurrendered = true
        var loop = WiringLoop(run: run, command: command(6.0), basis: basis)
        loop.heartRate = 100 // far below the band: the input that adds load
        loop.advance(seconds: 600)
        XCTAssertEqual(loop.writes, [])
        XCTAssertEqual(loop.decisions, [])
        XCTAssertEqual(loop.command, command(6.0))
    }

    // MARK: - A stop belongs to the client, not to the program

    func testTheRunnerConfirmsNothingOnAMerelyNotRunningBelt() {
        // Finding 84. The runner's own insistence read "no longer running" as a
        // confirmed stop, and a console winding the belt down reports `paused` —
        // a single paused frame arriving between two running frames was enough to
        // stop it asking. Its only reading of "not running" left is this one, and
        // it means stopped, not paused.
        XCTAssertTrue(ProgramRunner.isBeltStopped(.idle))
        XCTAssertTrue(ProgramRunner.isBeltStopped(.end))
        for status in [FitShow.Status.paused, .stopping, .running, .countdown,
                       .ready, .error, .safety, .study] {
            XCTAssertFalse(ProgramRunner.isBeltStopped(status),
                           "\(status) is not a stopped belt")
        }
        // And it is the same distinction the client's own rule makes, because a
        // stop is confirmed in exactly one place now.
        XCTAssertFalse(FitShowTreadmillClient.isObservedStopped(status: .paused, frameAge: 0))
        XCTAssertTrue(FitShowTreadmillClient.isObservedStopped(status: .idle, frameAge: 0))
    }

    func testAProgramWillNotStartWhileTheAppsOwnStopIsOutstanding() {
        // Finding 83's third half: `arm` ends in `client.startBelt`, the one call
        // that clears an outstanding stop, and `start` writes the first segment's
        // target onto a belt the app has just decided to stop.
        //
        // **Both halves of the client's fact** — finding 102. Reading
        // `stopNotObeyed` alone left the refusal false for the whole of the
        // failure window and for the whole of a disconnect, which is exactly when
        // a program could be armed and started, cancelling the app's own stop five
        // seconds later.
        XCTAssertTrue(ProgramRunner.isRefusedByOutstandingStop(isStopOutstanding: true,
                                                               stopNotObeyed: false),
                      "the first seconds of a stop are still an outstanding stop")
        XCTAssertTrue(ProgramRunner.isRefusedByOutstandingStop(isStopOutstanding: false,
                                                               stopNotObeyed: true),
                      "a stop the insistence gave up on is still not obeyed")
        XCTAssertTrue(ProgramRunner.isRefusedByOutstandingStop(isStopOutstanding: true,
                                                               stopNotObeyed: true))
        XCTAssertFalse(ProgramRunner.isRefusedByOutstandingStop(isStopOutstanding: false,
                                                                stopNotObeyed: false))
    }

    func testAnOutstandingStopEndsARunningProgramAndAbandonsAnArmedOne() {
        // Finding 94's runner half, as a function rather than as a line number.
        // Nothing may write a target onto a belt the app has decided to stop, and
        // the two answers differ only in what already happened: a workout that was
        // running ends, while a countdown or a wait for the belt — both of which
        // end in a write or in `startBelt` — is abandoned.
        for state in [ProgramRunner.RunnerState.running(segmentIndex: 0, remaining: 60),
                      .suspended(segmentIndex: 1, remaining: 30)] {
            XCTAssertEqual(ProgramRunner.outcome(whileStopOutstanding: true, in: state), .finish,
                           "\(state)")
        }
        for state in [ProgramRunner.RunnerState.armed(remaining: 3),
                      .waitingForBelt(elapsed: 2)] {
            XCTAssertEqual(ProgramRunner.outcome(whileStopOutstanding: true, in: state),
                           .abandon, "\(state)")
        }
        for state in [ProgramRunner.RunnerState.idle, .finished] {
            XCTAssertEqual(ProgramRunner.outcome(whileStopOutstanding: true, in: state),
                           .nothingToDo, "\(state)")
        }
        // And with no stop outstanding it never touches a program at all.
        for state in [ProgramRunner.RunnerState.idle, .armed(remaining: 3),
                      .waitingForBelt(elapsed: 2), .running(segmentIndex: 0, remaining: 60),
                      .suspended(segmentIndex: 0, remaining: 60), .finished] {
            XCTAssertEqual(ProgramRunner.outcome(whileStopOutstanding: false, in: state),
                           .nothingToDo, "\(state)")
        }
    }

    // MARK: - The heart-rate seam

    @MainActor
    func testTheGovernorsHeartRateArrivesThroughTheInjectedSource() {
        // Finding 70. The loop's heart rate comes from a
        // `GovernorHeartRateSource` and from nowhere else, and the conformers are
        // the Watch manager and demo mode's synthetic plant.
        // `FitShowTreadmillClient` is not one of them, so `state.heartRate` — the
        // handlebar byte that drops to 0 the moment the user lets go — has no
        // route in at all.
        let stub = StubHeartRateSource(bpm: 138)
        let sources: [any GovernorHeartRateSource] = [stub, WatchHeartRateManager.shared]
        XCTAssertEqual(sources.first?.governorHeartRateBpm(), 138)
        // With no mirrored Watch session the Watch conformer reports "no reading"
        // rather than a stale number, which is the value that freezes the loop.
        XCTAssertEqual(WatchHeartRateManager.shared.governorHeartRateBpm(), 0)
        stub.bpm = 0
        XCTAssertEqual(stub.governorHeartRateBpm(), 0)
    }

    // MARK: - The recovery goal

    private func recoveryTick(heartRate: Int, threshold: Int = 120,
                              delta: Double = 1) -> ProgramRunner.TickInput {
        ProgramRunner.TickInput(deltaSeconds: delta, speedKmh: 4.0, isBeltRunning: true,
                               isDataStale: false, heartRateBpm: heartRate,
                               heartRateBelowThresholdBpm: threshold)
    }

    func testARecoverySegmentEndsAfterTheHoldWindowBelowTheThreshold() {
        let goal = SegmentGoal.untilHeartRateBelow(bpm: 120, maxSeconds: 600)
        var progress = ProgramRunner.SegmentProgress()
        for _ in 0..<(WorkoutSegment.recoveryHeartRateHoldSeconds - 1) {
            progress = ProgramRunner.accumulating(progress, tick: recoveryTick(heartRate: 110))
        }
        XCTAssertFalse(ProgramRunner.isComplete(goal: goal, progress: progress))
        progress = ProgramRunner.accumulating(progress, tick: recoveryTick(heartRate: 110))
        XCTAssertTrue(ProgramRunner.isComplete(goal: goal, progress: progress))
    }

    func testOneLowReadingDoesNotEndARecoverySegment() {
        let goal = SegmentGoal.untilHeartRateBelow(bpm: 120, maxSeconds: 600)
        var progress = ProgramRunner.SegmentProgress()
        for _ in 0..<4 {
            progress = ProgramRunner.accumulating(progress, tick: recoveryTick(heartRate: 110))
        }
        // Back above the threshold: the count is consecutive seconds, so it resets.
        progress = ProgramRunner.accumulating(progress, tick: recoveryTick(heartRate: 130))
        XCTAssertEqual(progress.heartRateBelowSeconds, 0)
        XCTAssertFalse(ProgramRunner.isComplete(goal: goal, progress: progress))
    }

    func testAMissingReadingCannotEndARecoverySegmentButHoldsItsCount() {
        let goal = SegmentGoal.untilHeartRateBelow(bpm: 120, maxSeconds: 600)
        var progress = ProgramRunner.SegmentProgress()
        // 0 bpm is what a released handlebar and an absent Watch both report, and
        // it is the only value the recovery tally may never advance on.
        for _ in 0..<600 {
            progress = ProgramRunner.accumulating(progress, tick: recoveryTick(heartRate: 0))
        }
        XCTAssertEqual(progress.heartRateBelowSeconds, 0)
        // 600 s of moving belt: it ends on its cap, which is the required
        // behaviour of a failed sensor.
        XCTAssertTrue(ProgramRunner.isComplete(goal: goal, progress: progress))

        // And a gap in the middle of a count holds it rather than resetting it:
        // silence is not evidence that a heart rate went back up.
        var interrupted = ProgramRunner.SegmentProgress()
        for _ in 0..<3 {
            interrupted = ProgramRunner.accumulating(interrupted,
                                                     tick: recoveryTick(heartRate: 110))
        }
        for _ in 0..<10 {
            interrupted = ProgramRunner.accumulating(interrupted,
                                                     tick: recoveryTick(heartRate: 0))
        }
        XCTAssertEqual(interrupted.heartRateBelowSeconds, 3, accuracy: 0.0001)
        for _ in 0..<2 {
            interrupted = ProgramRunner.accumulating(interrupted,
                                                     tick: recoveryTick(heartRate: 110))
        }
        XCTAssertTrue(ProgramRunner.isComplete(goal: goal, progress: interrupted))
    }

    func testNoOtherGoalCountsHeartRateSeconds() {
        XCTAssertEqual(ProgramRunner.heartRateBelowThresholdBpm(.time(seconds: 600)), 0)
        XCTAssertEqual(ProgramRunner.heartRateBelowThresholdBpm(.distance(km: 5)), 0)
        XCTAssertEqual(ProgramRunner.heartRateBelowThresholdBpm(
            .untilHeartRateBelow(bpm: 120, maxSeconds: 600)), 120)
        // With no threshold the tally stays put whatever the reading says.
        let progress = ProgramRunner.accumulating(
            ProgramRunner.SegmentProgress(),
            tick: recoveryTick(heartRate: 90, threshold: 0))
        XCTAssertEqual(progress.heartRateBelowSeconds, 0)
    }

    // MARK: - Finding 87: one reconcile rule, and the two fakes agree with it

    /// `WiringLoop` (this file) exercises the loop through `ProgramRunner`'s own
    /// static functions; `GovernorLoop` (`HeartRateGovernorTests`) exercises it
    /// through `HeartRateGovernor.decide` directly. Both already call
    /// `FitShowTreadmillClient.reconciled` for the client's target and drive a
    /// real `ConsoleDialDetector` for fact 3 — finding 80's fix — but nothing
    /// before this test actually *ran* the two fakes side by side and checked
    /// they land on the same number. They do: given the same target, basis,
    /// entry command and plant, with no console intervention and nothing near
    /// either ceiling, 600 seconds of independent stepping — several
    /// evaluations, a climb into the band, and a hold once there — produces the
    /// same fact-1 and client-target sequence through both integration paths.
    /// A second, undetected reconcile rule in either fake would show up here as
    /// a diverging `command` or `appCommand`, which no amount of "both call the
    /// same named function" reading of the source can rule out by itself.
    func testWiringLoopAndGovernorLoopAgreeOnEveryCommand() {
        let target = HeartRateTarget(lowBpm: 140, highBpm: 152, actuator: .speed,
                                     startSpeedKmh: 6.0, startIncline: 1,
                                     minSpeedKmh: 5.0, maxSpeedKmh: 10.0,
                                     minIncline: 0, maxIncline: 3,
                                     fallbackSpeedKmh: 5.0)
        let basis = HeartRateBasis(restingBpm: 60, maxBpm: 190)
        let startCommand = HeartRateGovernor.Command(speedKmh: target.startSpeedKmh,
                                                      incline: target.startIncline)

        // A plant seeded already at the entry command — "arrived" — on both
        // sides: `GovernorLoop`'s own initializer does this internally when
        // `enteredFrom` is nil, and `WiringLoop` needs the same seeding done by
        // hand so the two start from identical physical conditions rather than
        // one starting mid-ramp from a bare `LaggedHeartRatePlant()`.
        func seededPlant() -> LaggedHeartRatePlant {
            var plant = LaggedHeartRatePlant()
            plant.speedKmh = startCommand.speedKmh
            plant.inclineLevel = Double(startCommand.incline)
            plant.heartRateBpm = plant.restingBpm + plant.bpmPerKmh * startCommand.speedKmh
                + plant.bpmPerInclineLevel * Double(startCommand.incline)
            return plant
        }

        let run = ProgramRunner.GovernorRun(target: target, lastAppliedChange: .settled(at: startCommand))
        var wiring = WiringLoop(run: run, command: startCommand, basis: basis, plant: seededPlant())
        var governor = GovernorLoop(target: target, basis: basis, plant: seededPlant(),
                                    startCommand: startCommand)

        wiring.advance(seconds: 600)
        governor.run(forSeconds: 600)

        XCTAssertEqual(wiring.command.speedKmh, governor.command.speedKmh, accuracy: 0.0001,
                       wiring.traceDescription)
        XCTAssertEqual(wiring.command.incline, governor.command.incline, wiring.traceDescription)
        XCTAssertEqual(wiring.appCommand.speedKmh, governor.appCommand.speedKmh, accuracy: 0.0001,
                       wiring.traceDescription)
        XCTAssertEqual(wiring.appCommand.incline, governor.appCommand.incline, wiring.traceDescription)
        XCTAssertFalse(wiring.didStop)
    }

}

// MARK: - The wiring under test

/// A stand-in for the injected heart-rate feed. That such a thing can exist at
/// all is the seam: the runner takes a `GovernorHeartRateSource`, never a
/// closure that could be written over `client.state.heartRate`.
@MainActor
private final class StubHeartRateSource: GovernorHeartRateSource {
    var bpm: Int
    init(bpm: Int) { self.bpm = bpm }
    func governorHeartRateBpm() -> Int { bpm }
}

/// `ProgramRunner.steer(_:on:deltaSeconds:heartRate:)` and `begin(_:at:)` with the
/// Bluetooth client replaced by the parts of it the loop depends on — and the
/// client's own rules *called* rather than re-modelled:
/// `FitShowTreadmillClient.reconciled` produces the client's target and
/// `ConsoleDialDetector` produces fact 3, so this fake and the closed-loop fake in
/// `HeartRateGovernorTests` can no longer drift into modelling two different
/// clients, one of which production does not have (finding 80). Every line of the
/// tick body below is the runner's own, assembled from its pure helpers — which is
/// the only way to test the wiring, since the runner itself takes a concrete
/// `FitShowTreadmillClient`.
///
/// Facts 2 and 3 travel as one argument now: `ProgramRunner.advancing` and
/// `governorInput` both take `belt:` with no default, and the runner fills it from
/// `client.beltFacts`. That was the missing wire — while `governorInput` did not
/// pass it, fact 3 never reached the governor and the mandatory hand-back could
/// not fire in production at all.
///
/// A `plant` is optional. With one, the belt and the person are modelled and the
/// belt reaches a command over time; without one the belt is ideal and stands
/// wherever it was last told to, which is what every test that does not care about
/// a ramp assumes anyway.
private struct WiringLoop {
    var limits = TreadmillLimits()
    var basis: HeartRateBasis?
    /// The reading, when there is no plant to produce one.
    var heartRate = 0
    /// `FitShowTreadmillClient.staleData`.
    var isLinkStale = false
    var plant: LaggedHeartRatePlant?

    /// The runner's `governorSession` — **nil while heart-rate control is off**,
    /// which is the whole of finding 100: no session means no clock for either
    /// ceiling to fire on, no stop, no band and no boundary clamp.
    private(set) var session: ProgramRunner.GovernorSession?
    /// **Fact 1**: `FitShowTreadmillClient.commandedSpeedKmh` / `commandedIncline`.
    private(set) var appCommand: HeartRateGovernor.Command
    /// The *client's* target: fact 1 reconciled with the measured belt by the
    /// client's one reconcile rule.
    private(set) var command: HeartRateGovernor.Command
    /// What the console is actually driving the belt toward. A separate number on
    /// purpose: a person turning a dial moves this, and nothing else does.
    private var consoleSetpoint: HeartRateGovernor.Command
    /// **Fact 2**: the belt's measured values. With no plant it is the console's
    /// setpoint, reached at once.
    private var measured: HeartRateGovernor.Command
    /// **Fact 3**, from production code.
    private var dial = ConsoleDialDetector()
    /// The client's own clock, not the run's: `lastTargetCommandAt`.
    private var secondsSinceLastCommand: Double = 0
    private(set) var status: ProgramRunner.GovernorStatus?
    private(set) var writes: [HeartRateGovernor.Command] = []
    private(set) var decisions: [HeartRateGovernor.Decision] = []
    private(set) var didStop = false
    /// The second the stop fired on, so a test can assert *when* rather than
    /// merely whether: the ticks after it are the caller's own loop running out.
    private(set) var stoppedAtSecond: Double?
    private(set) var maxCommandedSpeedKmh: Double
    private(set) var second: Double = 0
    /// One line per evaluation, for a failure message that shows the run.
    private(set) var trace: [String] = []

    init(run: ProgramRunner.GovernorRun?, command: HeartRateGovernor.Command,
         basis: HeartRateBasis?, plant: LaggedHeartRatePlant? = nil,
         isControlEnabled: Bool = true) {
        if isControlEnabled {
            var session = ProgramRunner.GovernorSession()
            session.beginSegment(run)
            self.session = session
        } else {
            session = nil
        }
        appCommand = command
        self.command = command
        consoleSetpoint = command
        measured = plant.map {
            HeartRateGovernor.Command(speedKmh: ($0.speedKmh * 10).rounded() / 10,
                                      incline: Int($0.inclineLevel.rounded()))
        } ?? command
        self.basis = basis
        self.plant = plant
        maxCommandedSpeedKmh = command.speedKmh
        dial.commanded(speedUnits: HeartRateGovernor.speedUnits(command.speedKmh),
                       incline: command.incline,
                       measuredSpeedUnits: HeartRateGovernor.speedUnits(measured.speedKmh),
                       measuredIncline: measured.incline)
    }

    var run: ProgramRunner.GovernorRun? { session?.run }

    /// The person's clocks, or empty ones when nothing is armed to keep them.
    var tallies: HeartRateGovernor.Tallies { session?.tallies ?? HeartRateGovernor.Tallies() }

    var isEvaluationDue: Bool { session.map(ProgramRunner.isEvaluationDue) ?? false }

    /// The opt-in, switched off mid-segment: `ProgramRunner.surrenderGoverning()`.
    mutating func surrender() { session?.surrender() }

    /// The heart rate this second, from the plant when there is one.
    var reading: Int {
        guard let plant else { return heartRate }
        return Int(plant.heartRateBpm.rounded())
    }

    /// Facts 2 and 3 as `FitShowTreadmillClient.beltFacts` reports them.
    var beltFacts: HeartRateGovernor.BeltFacts {
        HeartRateGovernor.BeltFacts(measured: measured,
                                    isSpeedSetByHand: dial.speed.isSetByHand,
                                    isInclineSetByHand: dial.incline.isSetByHand)
    }

    mutating func advance(seconds: Int) {
        for _ in 0..<seconds { tick() }
    }

    /// `ProgramRunner.tick()`'s `.running` branch in its own order: the loop is
    /// steered *before* the completion check, so a stop that becomes due on the
    /// tick a segment ends stops the belt instead of writing the next segment's
    /// entry command. A nil `next` is a segment that has not ended yet.
    mutating func advance(seconds: Int, thenBeginning next: WorkoutSegment?) {
        for _ in 0..<seconds where !didStop { tick() }
        guard !didStop, let next else { return }
        beginSegment(next)
    }

    /// `ProgramRunner.begin(_:at:)`: the entry write goes out first and hands its
    /// own change to the gate, and the session — the person's clocks and the
    /// frozen basis — survives the boundary.
    ///
    /// The entry passes through `ProgramRunner.boundedByCeiling` on the tallies as
    /// they stand *before* `beginSegment` clears the band-scoped ones, which is
    /// where the runner reads them too — and it is clamped by
    /// `ceilingReference`, `min(fact 1, fact 2)` per axis (finding 101).
    ///
    /// `isControlEnabled` stands for the runner's whole arming condition — the
    /// opt-in *and* the program carrying a heart-rate segment at all — because
    /// both have the same consequence here: with it false there is no session,
    /// exactly as `ProgramRunner.startGoverning` calls `clearGoverning()`.
    mutating func beginSegment(_ segment: WorkoutSegment, isControlEnabled: Bool = true) {
        let programmed = HeartRateGovernor.Command(speedKmh: segment.nominalSpeedKmh,
                                                   incline: segment.nominalIncline)
        let entry = ProgramRunner.boundedByCeiling(
            programmed,
            notAbove: ProgramRunner.ceilingReference(appCommand: appCommand, belt: beltFacts),
            isCeilingStanding: ProgramRunner.isForceDownCeilingStanding(session))
        let isClamped = !HeartRateGovernor.isSameCommand(entry, programmed)
        let change = apply(entry)
        let gate = ProgramRunner.gate(for: segment, isControlEnabled: isControlEnabled,
                                      entry: change)
        if isControlEnabled {
            var next = ProgramRunner.GovernorSession.continuing(session)
            next.beginSegment(gate.run)
            session = next
        } else {
            session = nil
        }
        status = isClamped ? .ceiling : gate.initialStatus
    }

    /// `ProgramRunner.tick()`'s `.suspended` branch, in its order: the state goes
    /// back to `.running` and `reapplyOnResume(_:on:)` decides what to re-write —
    /// with the hand-back latch refreshed from fact 3 *first*, because `steer` is
    /// the only other place that touches it and it does not run while the program
    /// is suspended (finding 135).
    mutating func resume(_ segment: WorkoutSegment) {
        guard var live = session, let suspended = live.run else { return }
        var run = ProgramRunner.resuming(suspended, belt: beltFacts)
        live.run = run
        session = live
        if run.isHandedBack, !suspended.isHandedBack { status = .handedBack }
        guard let command = ProgramRunner.resumeCommand(for: segment, run: run) else { return }
        let bounded = ProgramRunner.boundedByCeiling(
            command, notAbove: appCommand,
            isCeilingStanding: ProgramRunner.isForceDownCeilingStanding(live))
        run.commandApplied(apply(bounded))
        writes.append(self.command)
        live.run = run
        session = live
    }

    var traceDescription: String { trace.joined(separator: " | ") }

    /// One second of the **client's** own frame path, which is not the runner's:
    /// the belt moves, fact 3 is inferred from the measurement, and the one
    /// reconcile rule recomputes the client's target. The client polls at 200 ms
    /// and its lifetime is the connection, so this runs in states where nothing
    /// steers — see `observeWhileSuspended(seconds:)`.
    private mutating func observeFrame() {
        second += 1
        secondsSinceLastCommand += 1
        if var plant {
            plant.advance(bySeconds: 1, command: consoleSetpoint)
            self.plant = plant
            measured = HeartRateGovernor.Command(
                speedKmh: (plant.speedKmh * 10).rounded() / 10,
                incline: Int(plant.inclineLevel.rounded()))
        }
        dial.observe(measuredSpeedUnits: HeartRateGovernor.speedUnits(measured.speedKmh),
                     measuredIncline: measured.incline, deltaSeconds: 1)
        command = HeartRateGovernor.Command(
            speedKmh: HeartRateGovernor.speedKmh(units: FitShowTreadmillClient.reconciled(
                commandUnits: HeartRateGovernor.speedUnits(appCommand.speedKmh),
                measuredUnits: HeartRateGovernor.speedUnits(measured.speedKmh),
                secondsSinceCommand: secondsSinceLastCommand, ignoreZeroMeasurement: true)),
            incline: FitShowTreadmillClient.reconciled(
                commandUnits: appCommand.incline, measuredUnits: measured.incline,
                secondsSinceCommand: secondsSinceLastCommand, ignoreZeroMeasurement: false))
    }

    /// Seconds spent with the program **suspended**: the client goes on seeing
    /// frames and inferring the dial from them, while `steer` — the only other
    /// place the hand-back latch is touched — does not run at all. That gap is
    /// where finding 135 lived.
    mutating func observeWhileSuspended(seconds: Int) {
        for _ in 0..<seconds { observeFrame() }
    }

    private mutating func tick() {
        // The runner's timer is gone once the stop has fired, so nothing after it
        // may be evaluated here either.
        guard !didStop else { return }
        observeFrame()
        let heartRate = reading
        // `ProgramRunner.steer`'s first line: with no session there is nothing to
        // evaluate and nothing about heart rate touches the belt — the opt-in's
        // whole effect (finding 100).
        guard var live = session else { return }
        live = ProgramRunner.advancing(live, bySeconds: 1, heartRate: heartRate,
                                       basis: basis, command: command, belt: beltFacts,
                                       limits: limits)
        session = live
        // The 97% stop, at workout scope: above the surrender guard, above the run
        // guard, above the evaluation grid, from the tally alone.
        if ProgramRunner.isStopCeilingReached(live) {
            didStop = true
            stoppedAtSecond = second
            status = .stopping
            return
        }
        // A surrendered run is inert — but only from here down: the person's
        // clocks and the stop ceiling are above it.
        guard live.run?.isSurrendered != true else { return }
        guard ProgramRunner.isEvaluationDue(live) else { return }
        live.secondsSinceEvaluation = 0
        session = live
        guard var run = live.run else { return }
        guard let adopted = live.basis else {
            status = .noBasis
            return
        }
        let input = ProgramRunner.governorInput(live, run: run, basis: adopted,
                                                heartRate: heartRate, command: command,
                                                appCommand: appCommand,
                                                belt: beltFacts, limits: limits)
        run.isHandedBack = run.isHandedBack || HeartRateGovernor.isManualIntervention(input)
        let decision = HeartRateGovernor.decide(input)
        decisions.append(decision)
        trace.append(String(format: "%.0fs %.1fkm/h %d%% %dbpm %@", second, command.speedKmh,
                            command.incline, heartRate, "\(decision)"))
        status = ProgramRunner.status(for: decision, isHandedBack: run.isHandedBack,
                                      isLinkStale: isLinkStale)
        switch ProgramRunner.action(for: decision, isHandedBack: run.isHandedBack,
                                    isLinkStale: isLinkStale) {
        case .none:
            break
        case .handBack:
            run.isHandedBack = true
        case .write(let next):
            // `GovernorRun.commandApplied(_:)`: one call for the app's own write,
            // so the fake cannot keep half of the runner's bookkeeping.
            run.commandApplied(apply(next))
            writes.append(command)
        case .stop:
            didStop = true
            stoppedAtSecond = second
            status = .stopping
        }
        live.run = run
        session = live
    }

    /// `FitShowTreadmillClient.setTarget` plus the runner's `write(_:to:)`: fact 1
    /// is recorded, the dial detector is re-anchored — its evidence is all about
    /// the previous command — and the change is reported as fact 1 on both ends,
    /// from the previous command to the one the client took.
    private mutating func apply(_ next: HeartRateGovernor.Command) -> HeartRateGovernor.Change {
        let from = appCommand
        let raw = min(max(HeartRateGovernor.speedUnits(next.speedKmh), limits.minSpeedRaw),
                      limits.maxSpeedRaw)
        appCommand = HeartRateGovernor.Command(
            speedKmh: HeartRateGovernor.speedKmh(units: raw),
            incline: min(max(next.incline, limits.minIncline), limits.maxIncline))
        command = appCommand
        consoleSetpoint = appCommand
        // With no plant the belt is ideal: it is where it was told to be.
        if plant == nil { measured = appCommand }
        dial.commanded(speedUnits: raw, incline: appCommand.incline,
                       measuredSpeedUnits: HeartRateGovernor.speedUnits(measured.speedKmh),
                       measuredIncline: measured.incline)
        secondsSinceLastCommand = 0
        maxCommandedSpeedKmh = max(maxCommandedSpeedKmh, appCommand.speedKmh)
        return HeartRateGovernor.Change(from: from, to: appCommand)
    }

    /// The user turns the console's speed dial. It moves the console's own
    /// setpoint — never the app's record and never a target field — and the belt
    /// follows it; what the app makes of that is the whole question.
    mutating func consoleSetsSpeed(_ speedKmh: Double) {
        consoleSetpoint = HeartRateGovernor.Command(speedKmh: speedKmh, incline: command.incline)
        if plant == nil { measured = consoleSetpoint }
    }

    /// The same dial, turned while the **link is stale**: the console's setpoint
    /// moves and no frame carries it, so the app's whole picture — the measured
    /// value, the client's target and the app's own command alike — stays the
    /// memory of a belt that has since been dialled down. This is the state finding
    /// 136 is about, and it is why "a reduction against the app's own command"
    /// stops meaning "a reduction".
    mutating func consoleSetsSpeedUnseen(_ speedKmh: Double) {
        consoleSetpoint = HeartRateGovernor.Command(speedKmh: speedKmh, incline: command.incline)
    }

    /// The same for the incline dial, the axis the deleted dead band made blind.
    mutating func consoleSetsIncline(_ level: Int) {
        consoleSetpoint = HeartRateGovernor.Command(speedKmh: consoleSetpoint.speedKmh,
                                                   incline: level)
        if plant == nil { measured = consoleSetpoint }
    }
}
