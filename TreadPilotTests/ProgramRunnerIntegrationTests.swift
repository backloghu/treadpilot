// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import XCTest
@testable import TreadPilot

/// A **real `ProgramRunner`**, started and ticked over a scripted trace.
///
/// This suite exists because of finding 103, which is the same class of gap that
/// let phase 1's regression through: no test constructed a runner or called its
/// tick, so the runner-level suite exercised a hand-rolled copy of the steering
/// logic that lived in a test file and re-implemented its exact statement order.
/// Every safety property that lives in that statement order and nowhere else —
/// the 97% stop asked above the surrender guard and off the evaluation grid, the
/// hand-back latched from the evidence before the ladder is consulted, the
/// boundary clamp read before the band-scoped tallies are cleared, the refusal to
/// write onto a belt the app has decided to stop — was untested against shipped
/// code.
///
/// `ProgramRunnerGovernorTests.WiringLoop` stays as the fast closed-loop rig; it
/// is simply no longer the only thing that tests the runner.
@MainActor
final class ProgramRunnerIntegrationTests: XCTestCase {

    typealias Governor = HeartRateGovernor
    typealias Command = HeartRateGovernor.Command

    // Resting 60 / max 180: the force-down ceiling is 166, the stop ceiling 175.
    private let basis = HeartRateBasis(restingBpm: 60, maxBpm: 180)

    // MARK: - Fixtures

    private func speedTarget(low: Int = 144, high: Int = 155,
                             min: Double = 4.0, max: Double = 12.0,
                             start: Double = 6.0, fallback: Double = 4.5) -> HeartRateTarget {
        HeartRateTarget(lowBpm: low, highBpm: high, actuator: .speed,
                        startSpeedKmh: start, startIncline: 0,
                        minSpeedKmh: min, maxSpeedKmh: max,
                        minIncline: 0, maxIncline: 0, fallbackSpeedKmh: fallback)
    }

    private func heartRateSegment(_ target: HeartRateTarget? = nil,
                                  seconds: Int = 600) -> WorkoutSegment {
        WorkoutSegment(name: "Zone 3", goal: .time(seconds: seconds),
                       target: .heartRate(target ?? speedTarget()))
    }

    private func fixedSegment(_ speedKmh: Double, seconds: Int = 180) -> WorkoutSegment {
        WorkoutSegment(name: "Fast", duration: TimeInterval(seconds),
                       targetSpeedKmh: speedKmh, targetIncline: 0)
    }

    /// The frozen basis, through the type the runner actually reads it from.
    private func frozenRecorder() -> SessionRecorder {
        let recorder = SessionRecorder()
        let basis = basis
        recorder.heartRateBasisProvider = { basis }
        recorder.freezeHeartRateBasis()
        return recorder
    }

    /// Builds a runner with the opt-in set, hands it to `body`, and puts both the
    /// runner and the stored setting back afterwards. The opt-in lives in
    /// `UserDefaults.standard` — the runner's setter writes it — so a test that
    /// left it on would change what the next one sees.
    private func withRunner(heartRateControl enabled: Bool,
                            _ body: (ProgramRunner, SessionRecorder) throws -> Void) rethrows {
        let key = ProgramRunner.heartRateControlDefaultsKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let runner = ProgramRunner()
        let recorder = frozenRecorder()
        runner.heartRateControlEnabled = enabled
        defer { runner.stop() }
        try body(runner, recorder)
    }

    /// One second of the world, in production's order: a frame arrives from the
    /// belt, then the runner ticks on it. The delta is injected rather than
    /// measured, which is the seam `tick(bySeconds:)` exists for.
    private func drive(_ runner: ProgramRunner, _ belt: StubTreadmill, seconds: Int,
                       afterTick: (Int) -> Void = { _ in }) {
        for second in 0..<seconds {
            belt.frame(afterSeconds: 1)
            runner.tick(bySeconds: 1)
            afterTick(second + 1)
        }
    }

    // MARK: - The 97% stop, on a real runner, inside a 15 s segment

    func testTheStopCeilingStopsARealRunnerInsideAFifteenSecondSegment() throws {
        // Finding 64's scenario driven through the shipped class: the editor's
        // shortest segment is 15 s, the stop needs 15 s of breach *and* an
        // evaluation to act on it, and evaluations sit on a 10 s grid. What makes
        // it fire is that the stop is asked at workout scope, every tick, above
        // both the run guard and the evaluation grid — and that `tick` steers
        // before it checks the segment's goal, so a stop becoming due on the tick
        // a segment ends stops the belt instead of writing the next segment.
        withRunner(heartRateControl: true) { runner, recorder in
            let belt = StubTreadmill(speedKmh: 6.0)
            let heart = StubGovernorHeartRate(bpm: 176) // above the 175 stop ceiling
            runner.bindHeartRateControl(source: heart, basis: recorder)
            let program = WorkoutProgram(name: "HIIT", segments:
                (0..<8).map { _ in heartRateSegment(seconds: 15) })
            runner.start(program, on: belt)

            var stoppedAtSecond: Int?
            drive(runner, belt, seconds: 60) { second in
                if belt.stopRequests > 0, stoppedAtSecond == nil { stoppedAtSecond = second }
            }
            XCTAssertEqual(stoppedAtSecond, 15,
                           "the stop belongs on the tick the 15 s hold window closes")
            XCTAssertEqual(runner.runnerState, .finished)
            XCTAssertEqual(runner.governorStatus, .stopping)
            // Finding 116: the dashboard's program panel is only drawn while
            // `runnerState` is `.running`/`.suspended`, which just became false in
            // the very same tick — so this is the one fact about why the belt
            // stopped that has to be readable once that has already happened.
            XCTAssertEqual(runner.governorStopReason, .heartRateCeiling)
            // Once, and never again: the client's insistence owns the re-issuing,
            // and a program ending is not a reason to ask a second time.
            XCTAssertEqual(belt.stopRequests, 1)
            // And nothing was commanded after it. The 92% ceiling had walked the
            // belt down before the stop; what must not appear here is a segment
            // boundary's entry write.
            XCTAssertLessThanOrEqual(belt.commandedSpeedKmh, 6.0)
            XCTAssertFalse(belt.targetWrites.contains { $0.speedKmh > 6.0 })

            // The reason survives whatever happens to the workout next — a
            // dismissed summary sheet, an ordinary navigation home — because
            // nothing but a *new* workout beginning may say it is stale.
            drive(runner, belt, seconds: 5)
            XCTAssertEqual(runner.governorStopReason, .heartRateCeiling)
        }
    }

    func testANewWorkoutDropsThePreviousOnesStopReason() throws {
        // The other half of finding 116: the reason belongs to the workout that
        // set it, not to the runner forever, or a heart-rate stop from a HIIT
        // session an hour ago would still be labelled on tonight's plain jog.
        // A second, fresh belt stands in for a reconnect: the first one's own
        // stop is still outstanding on it, and that refusal (spec section 4, "A
        // stop the app asked for outlives the program that asked") is a
        // different rule from the one this test is about.
        withRunner(heartRateControl: true) { runner, recorder in
            let belt = StubTreadmill(speedKmh: 6.0)
            let heart = StubGovernorHeartRate(bpm: 176)
            runner.bindHeartRateControl(source: heart, basis: recorder)
            let hiit = WorkoutProgram(name: "HIIT", segments:
                (0..<8).map { _ in heartRateSegment(seconds: 15) })
            runner.start(hiit, on: belt)
            drive(runner, belt, seconds: 20)
            XCTAssertEqual(runner.governorStopReason, .heartRateCeiling)

            let freshBelt = StubTreadmill(speedKmh: 6.0)
            let jog = WorkoutProgram(name: "Jog", segments: [fixedSegment(6.0)])
            runner.start(jog, on: freshBelt)
            XCTAssertNil(runner.governorStopReason,
                        "a fresh workout starting is not evidence about the last one's stop")
        }
    }

    func testAManualWorkoutAfterACeilingStopDoesNotInheritTheReason() throws {
        // The gap `start(_:on:)` above does not cover: `beginWorkout()` clears
        // `governorStopReason` on the two program paths, `start(_:on:)` and
        // `arm(_:on:)`, but a manual workout goes through neither — only
        // `SessionRecorder.begin()` runs, and its call to
        // `forgetGovernorStopReason()` is the only thing standing between a
        // program that just stopped itself on the ceiling and the next,
        // unrelated recording. Modelled here through `SessionRecorder`'s own
        // pure `latchedStopFacts`, exactly as `SessionRecorder.tick` uses it
        // every second, so the two recordings' stop reasons are asserted the
        // same way production computes them.
        withRunner(heartRateControl: true) { runner, recorder in
            let belt = StubTreadmill(speedKmh: 6.0)
            let heart = StubGovernorHeartRate(bpm: 176) // above the 175 stop ceiling
            runner.bindHeartRateControl(source: heart, basis: recorder)
            let hiit = WorkoutProgram(name: "HIIT", segments:
                (0..<8).map { _ in heartRateSegment(seconds: 15) })
            runner.start(hiit, on: belt)
            drive(runner, belt, seconds: 20)
            XCTAssertEqual(runner.governorStopReason, .heartRateCeiling,
                           "the fixture needs a real ceiling stop before the boundary can matter")

            // Session 1 latches its own reason while it is the active recording.
            var session1 = (reason: WorkoutStopReason.none, beltDidNotStop: false)
            session1 = SessionRecorder.latchedStopFacts(
                current: session1, governorStopReason: runner.governorStopReason,
                clientStopNotObeyed: belt.stopNotObeyed)
            XCTAssertEqual(session1.reason, .heartRateCeiling)

            // The recording closes and the user starts a plain manual workout —
            // no program, so neither `start(_:on:)` nor `arm(_:on:)` runs. Only
            // the boundary `SessionRecorder.begin()` calls stands between the
            // stale flag and the new recording.
            runner.forgetGovernorStopReason()

            var session2 = (reason: WorkoutStopReason.none, beltDidNotStop: false)
            session2 = SessionRecorder.latchedStopFacts(
                current: session2, governorStopReason: runner.governorStopReason,
                clientStopNotObeyed: false)

            XCTAssertEqual(session2.reason, .none,
                           "a manual workout must not inherit the previous one's ceiling stop")
            XCTAssertEqual(session1.reason, .heartRateCeiling,
                           "closing session 1 must not have lost its own label along the way")
        }
    }

    // MARK: - Finding 100: the ceilings belong to the opt-in

    func testWithTheOptInOffARealRunnerNeverActsOnHeartRate() throws {
        // The same belt, the same person, a heart rate above every ceiling any
        // basis could produce — and heart-rate control switched off. Nothing about
        // heart rate may touch the belt: no stop, no force-down, no boundary
        // clamp, and no band on the dashboard (spec section 4, "The ceilings
        // belong to the opt-in").
        withRunner(heartRateControl: false) { runner, recorder in
            let belt = StubTreadmill(speedKmh: 6.0)
            let heart = StubGovernorHeartRate(bpm: 200)
            runner.bindHeartRateControl(source: heart, basis: recorder)
            runner.start(WorkoutProgram(name: "Zone 3", segments: [heartRateSegment()]),
                         on: belt)
            drive(runner, belt, seconds: 300)

            XCTAssertEqual(belt.stopRequests, 0, "the belt was stopped on a heart rate")
            XCTAssertEqual(belt.targetWrites.count, 1,
                           "only the segment's own entry command may be written")
            XCTAssertEqual(belt.commandedSpeedKmh, 6.0, accuracy: 0.0001)
            XCTAssertEqual(runner.governorStatus, .controlOff)
            XCTAssertNil(runner.governedBandBpm,
                         "a band nothing is holding must not be drawn")
            XCTAssertEqual(runner.runnerState,
                           .running(segmentIndex: 0,
                                    remaining: TimeInterval(600 - 300)))
        }
    }

    func testWithTheOptInOnTheSameTraceDoesStopTheBelt() throws {
        // Non-vacuity for the test above: everything else about that scenario is
        // identical, and the opt-in is the only thing that changes.
        withRunner(heartRateControl: true) { runner, recorder in
            let belt = StubTreadmill(speedKmh: 6.0)
            let heart = StubGovernorHeartRate(bpm: 200)
            runner.bindHeartRateControl(source: heart, basis: recorder)
            runner.start(WorkoutProgram(name: "Zone 3", segments: [heartRateSegment()]),
                         on: belt)
            drive(runner, belt, seconds: 300)

            XCTAssertEqual(belt.stopRequests, 1)
            XCTAssertEqual(runner.runnerState, .finished)
        }
    }

    func testAProgramWithNoHeartRateSegmentArmsNothingEvenWithTheOptInOn() throws {
        // The ruling's other half: the two ceilings also armed "on programs
        // containing no heart-rate segment". There is no governor driving such a
        // workout, so there is nothing for a ceiling to protect anybody from.
        withRunner(heartRateControl: true) { runner, recorder in
            let belt = StubTreadmill(speedKmh: 6.0)
            let heart = StubGovernorHeartRate(bpm: 200)
            runner.bindHeartRateControl(source: heart, basis: recorder)
            runner.start(WorkoutProgram(name: "Intervals",
                                        segments: [fixedSegment(6.0, seconds: 600)]),
                         on: belt)
            drive(runner, belt, seconds: 300)

            XCTAssertEqual(belt.stopRequests, 0)
            XCTAssertEqual(belt.targetWrites.count, 1)
            XCTAssertNil(runner.governorStatus,
                         "a fixed program has nothing to say about heart rate")
        }
    }

    func testSwitchingTheOptInOffMidRunTakesTheStopWithIt() throws {
        // The same instruction — "do not steer my belt" — given during the workout
        // instead of before it. The brakes may not depend on the timing of a
        // settings tap.
        withRunner(heartRateControl: true) { runner, recorder in
            let belt = StubTreadmill(speedKmh: 6.0)
            let heart = StubGovernorHeartRate(bpm: 176)
            runner.bindHeartRateControl(source: heart, basis: recorder)
            runner.start(WorkoutProgram(name: "Zone 3", segments: [heartRateSegment()]),
                         on: belt)
            drive(runner, belt, seconds: 10) // ten seconds of a live breach
            XCTAssertEqual(belt.stopRequests, 0, "15 s is the hold window")
            runner.heartRateControlEnabled = false
            XCTAssertEqual(runner.governorStatus, .controlOff)
            // Well short of the segment's own 600 s: the only thing that could
            // stop this belt is the ceiling, not the program running out.
            drive(runner, belt, seconds: 300)

            XCTAssertEqual(belt.stopRequests, 0,
                           "the stop fired after heart-rate control was switched off")
            XCTAssertEqual(runner.runnerState.segmentIndex, 0)
            // The run survives, inert, so a later resume still restates the loop's
            // own last command rather than the segment's programmed start.
            XCTAssertEqual(runner.governorStatus, .controlOff)
        }
    }

    // MARK: - Finding 65: the hand-back is latched from the evidence

    func testAHandBackSurvivesACeilingStepDownInTheSameEvaluation() throws {
        // The force-down rung outranks the manual-control rung *and* rewrites the
        // record of the app's last command, so an intervention made while the 92%
        // tally stands used to be consumed and forgotten — after which the loop
        // re-accelerated past the speed the user had set by hand. The latch is
        // taken from `isManualIntervention(input)` before `decide` is consulted,
        // and this is that statement order under test.
        withRunner(heartRateControl: true) { runner, recorder in
            let belt = StubTreadmill(speedKmh: 6.0)
            let heart = StubGovernorHeartRate(bpm: 150) // inside the 144–155 band
            runner.bindHeartRateControl(source: heart, basis: recorder)
            runner.start(WorkoutProgram(name: "Zone 3", segments: [heartRateSegment()]),
                         on: belt)
            drive(runner, belt, seconds: 120) // both settle windows expire
            XCTAssertEqual(belt.targetWrites.count, 1, "inside the band there is nothing to do")

            // The dial goes up and the ceiling fills inside the same ten seconds,
            // so the evidence and the reduction land in one evaluation.
            belt.consoleSets(speedKmh: 7.0)
            heart.bpm = 170 // at 92% of the frozen maximum
            drive(runner, belt, seconds: 10)
            XCTAssertEqual(runner.governorStatus, .ceiling,
                           "the ceiling still outranks the hand-back, and still writes")
            // One step below the *app's* own 6.0, not below the user's 7.0: a
            // reduction may never come out above what the app itself last asked.
            XCTAssertEqual(belt.commandedSpeedKmh, 5.8, accuracy: 0.0001)
            XCTAssertEqual(belt.targetWrites.count, 2)

            // The rest of the segment is the user's, whatever the band says. Five
            // minutes, which keeps the whole trace inside the segment's own 600 s:
            // the program running out would call `requestStop` and clear the
            // status this test is about.
            heart.bpm = 100 // far below the band
            drive(runner, belt, seconds: 300)
            XCTAssertEqual(belt.stopRequests, 0)
            XCTAssertEqual(belt.targetWrites.count, 2,
                           "the ceiling consumed the evidence of the intervention")
            XCTAssertEqual(runner.governorStatus, .handedBack)
            XCTAssertNil(runner.governedBandBpm,
                         "a handed-back segment is holding nobody's band")
            XCTAssertEqual(belt.commandedSpeedKmh, 5.8, accuracy: 0.0001)
        }
    }

    // MARK: - Finding 101: a boundary may not raise the load over a hand-back

    func testASegmentBoundaryWillNotRaiseTheLoadWhileACeilingStands() throws {
        // The reproduction, on the shipped class. Segment 1 is governed with an
        // entry write of 10.0, so the app's own command is 10.0; the user dials
        // the console to 6.0 and the hand-back latches, after which *nothing*
        // lowers the app's command — that is the whole point of fact 1 — so it
        // stays at 10.0 while the belt runs 6.0. The heart rate then crosses the
        // 166 force-down ceiling on the segment's last second: the tally stands,
        // the rule has not fired, and the boundary into a 12.0 km/h segment used
        // to write the app's own 10.0. Four km/h added to a belt whose user is
        // above the line the dashboard was reporting.
        withRunner(heartRateControl: true) { runner, recorder in
            let belt = StubTreadmill(speedKmh: 10.0)
            let heart = StubGovernorHeartRate(bpm: 150)
            runner.bindHeartRateControl(source: heart, basis: recorder)
            runner.start(WorkoutProgram(name: "Mixed", segments: [
                heartRateSegment(speedTarget(start: 10.0), seconds: 40),
                fixedSegment(12.0),
            ]), on: belt)
            drive(runner, belt, seconds: 6)
            belt.consoleSets(speedKmh: 6.0)
            drive(runner, belt, seconds: 33)
            XCTAssertEqual(belt.commandedSpeedKmh, 10.0, accuracy: 0.0001,
                           "the reproduction needs fact 1 left at 10.0 by the hand-back")
            XCTAssertEqual(runner.governorStatus, .handedBack)

            heart.bpm = 169 // one second above the force-down ceiling, then the boundary
            drive(runner, belt, seconds: 1)

            XCTAssertEqual(runner.runnerState.segmentIndex, 1, "the boundary was crossed")
            XCTAssertEqual(belt.commandedSpeedKmh, 6.0, accuracy: 0.0001,
                           "the boundary wrote the app's own command over the belt's 6.0")
            XCTAssertEqual(runner.governorStatus, .ceiling,
                           "a belt that did not speed up at a boundary has to say why")
            XCTAssertEqual(belt.stopRequests, 0, "169 bpm is below the 175 stop ceiling")
        }
    }

    func testABoundaryWritesItsProgrammedEntryWhenNoCeilingStands() throws {
        // The control case, so the test above pins a clamp and not a speed limit.
        withRunner(heartRateControl: true) { runner, recorder in
            let belt = StubTreadmill(speedKmh: 10.0)
            let heart = StubGovernorHeartRate(bpm: 150)
            runner.bindHeartRateControl(source: heart, basis: recorder)
            runner.start(WorkoutProgram(name: "Mixed", segments: [
                heartRateSegment(speedTarget(start: 10.0), seconds: 40),
                fixedSegment(12.0),
            ]), on: belt)
            drive(runner, belt, seconds: 6)
            belt.consoleSets(speedKmh: 6.0)
            drive(runner, belt, seconds: 34)

            XCTAssertEqual(runner.runnerState.segmentIndex, 1)
            XCTAssertEqual(belt.commandedSpeedKmh, 12.0, accuracy: 0.0001)
        }
    }

    // MARK: - Finding 135: what a resume decides from

    func testASpeedSetByHandDuringASuspensionSurvivesTheResumeOnTheRealRunner() throws {
        // The reproduction on the shipped class. The hand-back latch is mutated in
        // exactly one place — `steer`, on the evaluation grid — and `steer` does not
        // run while the program is suspended, so `resumeCommand` used to read a latch
        // that still said nobody had touched anything and wrote the loop's remembered
        // 8.0 straight back over the 6.0 the user had just dialled in.
        withRunner(heartRateControl: true) { runner, recorder in
            let belt = StubTreadmill(speedKmh: 8.0)
            let heart = StubGovernorHeartRate(bpm: 150) // inside the 144–155 band
            runner.bindHeartRateControl(source: heart, basis: recorder)
            runner.start(WorkoutProgram(name: "Zone 3",
                                        segments: [heartRateSegment(speedTarget(start: 8.0))]),
                         on: belt)
            drive(runner, belt, seconds: 60)
            let writesBeforeThePause = belt.targetWrites.count

            // The user pauses at the console. The frame says `paused` with the belt
            // still reporting the speed it was running at, so the runner suspends
            // with nothing about the belt having changed yet.
            belt.state.status = .paused
            drive(runner, belt, seconds: 2)
            guard case .suspended = runner.runnerState else {
                return XCTFail("expected a suspended program, got \(runner.runnerState)")
            }
            XCTAssertEqual(belt.targetWrites.count, writesBeforeThePause,
                           "a suspended program writes nothing")

            // Now the dial goes down and the belt is started again from the console.
            // Nothing has evaluated in between; the client has been watching frames
            // the whole time.
            belt.consoleSets(speedKmh: 6.0)
            belt.state.status = .running
            drive(runner, belt, seconds: 3)
            guard case .running = runner.runnerState else {
                return XCTFail("expected the program to resume, got \(runner.runnerState)")
            }
            XCTAssertEqual(belt.targetWrites.count, writesBeforeThePause,
                           "the resume wrote the loop's memory over the user's dial")
            XCTAssertEqual(belt.commandedSpeedKmh, 8.0, accuracy: 0.0001,
                           "and fact 1 is untouched, because nothing was commanded")
            XCTAssertEqual(runner.governorStatus, .handedBack)
            XCTAssertNil(runner.governedBandBpm,
                         "a handed-back segment is holding nobody's band")

            // And it stays the user's for the rest of the segment, whatever the band
            // would argue for.
            heart.bpm = 100
            drive(runner, belt, seconds: 300)
            XCTAssertEqual(belt.targetWrites.count, writesBeforeThePause)
            XCTAssertEqual(runner.governorStatus, .handedBack)
        }
    }

    // MARK: - Finding 114 / 117: a segment boundary retires the console-dial verdict

    func testASegmentBoundaryRetiresTheHandBackVerdictLatchedInThePreviousSegment() throws {
        // The same reproduction as the two tests above, one step further: by the
        // boundary, segment 1's console departure has long since latched fact
        // 3's verdict (`governorStatus == .handedBack`), and the boundary's own
        // entry write does not land on the belt's current speed — a console with
        // nobody at it only *starts* converging on the write, it does not teleport
        // there — so `ConsoleDialAxis.commanded`'s one release (an exact match)
        // cannot fire on this tick. Without `ProgramRunner.begin(_:at:)` calling
        // `client.segmentBegan()` at the boundary, fact 3 would still read "set by
        // hand" one tick into a segment nobody has touched — the exact leak
        // finding 114 named. The stub belt is otherwise ideal (no ramp), so this
        // is the one tick where the leak is observable at all: the very next frame
        // snaps onto the new entry command and self-heals by exact-match release,
        // which is why this assertion has to land immediately after the boundary
        // and not one tick later.
        withRunner(heartRateControl: true) { runner, recorder in
            let belt = StubTreadmill(speedKmh: 10.0)
            let heart = StubGovernorHeartRate(bpm: 150)
            runner.bindHeartRateControl(source: heart, basis: recorder)
            runner.start(WorkoutProgram(name: "Mixed", segments: [
                heartRateSegment(speedTarget(start: 10.0), seconds: 40),
                fixedSegment(12.0),
            ]), on: belt)
            drive(runner, belt, seconds: 6)
            belt.consoleSets(speedKmh: 6.0)
            drive(runner, belt, seconds: 33)
            XCTAssertEqual(runner.governorStatus, .handedBack,
                           "the verdict has to be standing going into the boundary")
            XCTAssertTrue(belt.beltFacts.isSpeedSetByHand)

            drive(runner, belt, seconds: 1) // crosses the boundary into segment 2

            XCTAssertEqual(runner.runnerState.segmentIndex, 1, "the boundary was crossed")
            XCTAssertFalse(belt.beltFacts.isSpeedSetByHand,
                           "the boundary must retire the previous segment's verdict, " +
                           "not carry it into a segment nobody has touched")
        }
    }

    // MARK: - Finding 94 / 102: a belt the app has decided to stop

    func testARunningProgramEndsRatherThanWritingOntoAnOutstandingStop() throws {
        // The dashboard's stop button asks the *client* to stop; it does not end
        // the program. So the runner used to keep ticking: crossing segment
        // boundaries, writing their entry commands, and publishing a governor
        // status that said it was steering. The client clamps every such write
        // downward, so the belt could not accelerate — but a program marching on
        // over a belt the app has decided to stop is wrong whatever the clamp does.
        withRunner(heartRateControl: true) { runner, recorder in
            let belt = StubTreadmill(speedKmh: 6.0)
            let heart = StubGovernorHeartRate(bpm: 150)
            runner.bindHeartRateControl(source: heart, basis: recorder)
            runner.start(WorkoutProgram(name: "Mixed", segments: [
                heartRateSegment(seconds: 20),
                fixedSegment(12.0),
            ]), on: belt)
            drive(runner, belt, seconds: 5)
            let writesBeforeTheStop = belt.targetWrites.count

            belt.requestStop() // the user presses STOP on the dashboard
            drive(runner, belt, seconds: 60)

            XCTAssertEqual(belt.targetWrites.count, writesBeforeTheStop,
                           "a target was written onto a belt the app had asked to stop")
            XCTAssertEqual(runner.runnerState, .finished)
            XCTAssertNil(runner.governorStatus,
                         "a program that has ended is not steering anything")
            // It does not ask again: the client's insistence is already running,
            // and its lifetime is the connection rather than this program's.
            XCTAssertEqual(belt.stopRequests, 1)
            XCTAssertEqual(belt.commandedSpeedKmh, 6.0, accuracy: 0.0001,
                           "the 12.0 km/h segment was entered anyway")
        }
    }

    func testAProgramCannotBeStartedOrArmedWhileTheAppsOwnStopIsOutstanding() throws {
        // Finding 102: the refusal used to read only `stopNotObeyed`, which needs
        // the belt's whole wind-down window to become true and stays false for the
        // whole of a disconnect. `isStopOutstanding` is true from the first
        // attempt onward, and this is the window a program could be started in.
        withRunner(heartRateControl: true) { runner, _ in
            let running = StubTreadmill(speedKmh: 6.0)
            running.requestStop()
            XCTAssertTrue(running.isStopOutstanding)
            XCTAssertFalse(running.stopNotObeyed, "the failure has not been established yet")
            runner.start(WorkoutProgram(name: "Zone 3", segments: [heartRateSegment()]),
                         on: running)
            XCTAssertEqual(runner.runnerState, .idle)
            XCTAssertNil(runner.program)
            XCTAssertEqual(running.targetWrites.count, 0)
        }
        withRunner(heartRateControl: true) { runner, _ in
            let standing = StubTreadmill(speedKmh: 0, isRunning: false)
            standing.requestStop()
            runner.arm(WorkoutProgram(name: "Zone 3", segments: [heartRateSegment()]),
                       on: standing)
            XCTAssertEqual(runner.runnerState, .idle)
            XCTAssertEqual(standing.startCommands.count, 0)
        }
    }

    func testAStopArrivingDuringTheCountdownAbandonsTheArmedProgram() throws {
        // `arm`'s countdown ends in `client.startBelt`, the one call that cancels
        // an outstanding stop. A stop appearing inside those five seconds has to
        // take the program, not the other way round — and on the tick it appears,
        // not when the countdown runs out.
        withRunner(heartRateControl: true) { runner, _ in
            let belt = StubTreadmill(speedKmh: 0, isRunning: false)
            runner.arm(WorkoutProgram(name: "Zone 3", segments: [heartRateSegment()]),
                       on: belt)
            XCTAssertEqual(runner.runnerState, .armed(remaining: ProgramRunner.armCountdownSeconds))
            runner.tick(bySeconds: 1)
            XCTAssertEqual(runner.runnerState,
                           .armed(remaining: ProgramRunner.armCountdownSeconds - 1))

            belt.requestStop()
            runner.tick(bySeconds: 1)
            XCTAssertEqual(runner.runnerState, .idle)
            XCTAssertEqual(belt.startCommands.count, 0, "the belt was started anyway")
            XCTAssertEqual(belt.stopRequests, 1, "the stop must still be the client's")
        }
    }
}

// MARK: - Test doubles

private extension ProgramRunner.RunnerState {
    /// The segment a running or suspended program is on, for an assertion that
    /// does not want to spell out a remaining-seconds figure.
    var segmentIndex: Int? {
        switch self {
        case .running(let index, _), .suspended(let index, _): return index
        default: return nil
        }
    }
}

/// The heart rate the loop may act on, as the injected source supplies it.
@MainActor
private final class StubGovernorHeartRate: GovernorHeartRateSource {
    var bpm: Int
    init(bpm: Int) { self.bpm = bpm }
    func governorHeartRateBpm() -> Int { bpm }
}

/// A treadmill the runner can actually be started on, behind
/// `TreadmillControlling`.
///
/// It models the belt and the console, and it answers every question about them
/// from the **client's own pure rules** rather than re-deriving them:
/// `FitShowTreadmillClient.reconciled` produces the client's target,
/// `bounded`/`boundedByStop` apply the stale-link and outstanding-stop clamps,
/// and a real `ConsoleDialDetector` produces fact 3. That is finding 80's rule —
/// a fake that models its own rules models a client production does not have.
///
/// The belt itself is ideal: it is wherever the console's setpoint says, with no
/// ramp. Every test in this file is about what the runner decides, and the ramp
/// cases are covered by the closed-loop rig with its lagged plant.
@MainActor
private final class StubTreadmill: TreadmillControlling {

    var state = TreadmillState()
    var limits = TreadmillLimits()
    var staleData = false

    private(set) var commandedSpeedKmh: Double
    private(set) var commandedIncline: Int
    private(set) var targetSpeedKmh: Double
    private(set) var targetIncline: Int
    private(set) var isStopOutstanding = false
    private(set) var stopNotObeyed = false

    /// Every `setTarget` the runner made, as it asked for it — before the clamps.
    /// A write the client would clamp to nothing is still a write the runner
    /// should not have made.
    private(set) var targetWrites: [HeartRateGovernor.Command] = []
    private(set) var startCommands: [HeartRateGovernor.Command] = []
    private(set) var stopRequests = 0

    /// What the console is driving the belt toward. A person turning a dial moves
    /// this and nothing else does.
    private var consoleSetpoint: HeartRateGovernor.Command
    /// Fact 3, from production code.
    private var dial = ConsoleDialDetector()
    /// The client's own clock: `lastTargetCommandAt`.
    private var secondsSinceCommand: Double = 0

    init(speedKmh: Double, incline: Int = 0, isRunning: Bool = true) {
        commandedSpeedKmh = speedKmh
        commandedIncline = incline
        targetSpeedKmh = speedKmh
        targetIncline = incline
        consoleSetpoint = HeartRateGovernor.Command(speedKmh: speedKmh, incline: incline)
        state.status = isRunning ? .running : .idle
        state.speedKmh = speedKmh
        state.inclinePercent = incline
        dial.started(speedUnits: HeartRateGovernor.speedUnits(speedKmh), incline: incline,
                     measuredSpeedUnits: HeartRateGovernor.speedUnits(speedKmh),
                     measuredIncline: incline)
    }

    var beltFacts: HeartRateGovernor.BeltFacts {
        HeartRateGovernor.BeltFacts(
            measured: HeartRateGovernor.Command(speedKmh: state.speedKmh,
                                                incline: state.inclinePercent),
            isSpeedSetByHand: dial.speed.isSetByHand,
            isInclineSetByHand: dial.incline.isSetByHand)
    }

    // MARK: TreadmillControlling

    func setTarget(speedKmh: Double, incline: Int) {
        targetWrites.append(HeartRateGovernor.Command(speedKmh: speedKmh, incline: incline))
        record(speedKmh: speedKmh, incline: incline, isStart: false)
    }

    func startBelt(speedKmh: Double, incline: Int) {
        startCommands.append(HeartRateGovernor.Command(speedKmh: speedKmh, incline: incline))
        // The one user action that may cancel a stop of the app's own.
        isStopOutstanding = false
        stopNotObeyed = false
        state.status = .running
        record(speedKmh: speedKmh, incline: incline, isStart: true)
    }

    func requestStop() {
        stopRequests += 1
        isStopOutstanding = true
    }

    /// Mirrors `FitShowTreadmillClient.segmentBegan()`: retires the dial's
    /// verdict, leaves its travel bookkeeping and observation history alone.
    func segmentBegan() {
        dial.segmentBegan()
    }

    // MARK: The world

    /// A person on the console's dials. It moves the console's own setpoint and
    /// nothing else — never a target field, and never the app's record.
    func consoleSets(speedKmh: Double? = nil, incline: Int? = nil) {
        consoleSetpoint = HeartRateGovernor.Command(
            speedKmh: speedKmh ?? consoleSetpoint.speedKmh,
            incline: incline ?? consoleSetpoint.incline)
    }

    /// One frame from the belt, `deltaSeconds` after the previous one: the client's
    /// own notification path, with the belt where the console says.
    func frame(afterSeconds delta: Double) {
        state.speedKmh = consoleSetpoint.speedKmh
        state.inclinePercent = consoleSetpoint.incline
        secondsSinceCommand += delta
        dial.observe(measuredSpeedUnits: HeartRateGovernor.speedUnits(state.speedKmh),
                     measuredIncline: state.inclinePercent, deltaSeconds: delta)
        targetSpeedKmh = HeartRateGovernor.speedKmh(units: FitShowTreadmillClient.reconciled(
            commandUnits: HeartRateGovernor.speedUnits(commandedSpeedKmh),
            measuredUnits: HeartRateGovernor.speedUnits(state.speedKmh),
            secondsSinceCommand: secondsSinceCommand, ignoreZeroMeasurement: true))
        targetIncline = FitShowTreadmillClient.reconciled(
            commandUnits: commandedIncline, measuredUnits: state.inclinePercent,
            secondsSinceCommand: secondsSinceCommand, ignoreZeroMeasurement: false)
    }

    /// `FitShowTreadmillClient.record(command:incline:origin:)`, called through the
    /// client's own bounds so this double cannot accept a write production would
    /// refuse.
    private func record(speedKmh: Double, incline: Int, isStart: Bool) {
        let stale = FitShowTreadmillClient.bounded(
            speedKmh: speedKmh, incline: incline, isLinkStale: staleData,
            measuredSpeedKmh: state.speedKmh, measuredIncline: state.inclinePercent)
        let bound = FitShowTreadmillClient.boundedByStop(
            speedKmh: stale.speedKmh, incline: stale.incline,
            isStopOutstanding: !isStart && isStopOutstanding,
            appSpeedKmh: commandedSpeedKmh, appIncline: commandedIncline,
            measuredSpeedKmh: state.speedKmh, measuredIncline: state.inclinePercent)
        commandedSpeedKmh = min(max(bound.speedKmh, limits.minSpeedKmh), limits.maxSpeedKmh)
        commandedIncline = min(max(bound.incline, limits.minIncline), limits.maxIncline)
        targetSpeedKmh = commandedSpeedKmh
        targetIncline = commandedIncline
        let units = HeartRateGovernor.speedUnits(commandedSpeedKmh)
        let measuredUnits = HeartRateGovernor.speedUnits(state.speedKmh)
        if isStart {
            dial.started(speedUnits: units, incline: commandedIncline,
                         measuredSpeedUnits: measuredUnits,
                         measuredIncline: state.inclinePercent)
        } else {
            dial.commanded(speedUnits: units, incline: commandedIncline,
                           measuredSpeedUnits: measuredUnits,
                           measuredIncline: state.inclinePercent)
        }
        secondsSinceCommand = 0
        // A console with nobody standing at it accepts the app's target.
        consoleSetpoint = HeartRateGovernor.Command(speedKmh: commandedSpeedKmh,
                                                   incline: commandedIncline)
    }
}
