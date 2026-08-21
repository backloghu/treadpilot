// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import XCTest
@testable import TreadPilot

@MainActor
final class SessionRecorderTests: XCTestCase {

    // MARK: - Which source a recorded second is credited to

    func testAWatchReadingWinsAndIsCreditedToTheWatch() {
        let resolved = SessionRecorder.resolveHeartRate(watchBpm: 141, handlebarBpm: 148)
        XCTAssertEqual(resolved.bpm, 141)
        XCTAssertTrue(resolved.fromWatch)
    }

    func testAHandlebarReadingIsRecordedButNeverCreditedToTheWatch() {
        // The Watch app failed to launch, the user holds the grips: the second
        // has a heart rate to record and no Watch coverage to claim.
        let resolved = SessionRecorder.resolveHeartRate(watchBpm: 0, handlebarBpm: 148)
        XCTAssertEqual(resolved.bpm, 148)
        XCTAssertFalse(resolved.fromWatch)
    }

    func testASecondWithNoReadingAtAllIsCreditedToNothing() {
        // Both sources say 0 — the handlebar one also once its frame has expired.
        let resolved = SessionRecorder.resolveHeartRate(watchBpm: 0, handlebarBpm: 0)
        XCTAssertEqual(resolved.bpm, 0)
        XCTAssertFalse(resolved.fromWatch)
    }

    // MARK: - Finding 115: which band a sample gets

    func testAGovernedSecondRecordsTheArbitratedBand() {
        // The runner's published band, never the segment's stored request — the
        // arbitration may have clamped it away from what was asked for.
        let band = SessionRecorder.targetBand(for: 144...155)
        XCTAssertEqual(band.low, 144)
        XCTAssertEqual(band.high, 155)
    }

    func testAnUngovernedSecondRecordsZeroNotTheLastKnownBand() {
        // Nothing was holding a band this second — a fixed segment inside a
        // heart-rate program, or the opt-in off entirely — and 0/0 is the same
        // "nothing here" the lightweight migration gives an old row.
        let band = SessionRecorder.targetBand(for: nil)
        XCTAssertEqual(band.low, 0)
        XCTAssertEqual(band.high, 0)
    }

    // MARK: - Findings 138/139/142: the durable stop facts

    private let untouched = (reason: WorkoutStopReason.none, beltDidNotStop: false)

    func testAnOrdinaryTickChangesNeitherFact() {
        let next = SessionRecorder.latchedStopFacts(current: untouched,
                                                     governorStopReason: nil,
                                                     clientStopNotObeyed: false)
        XCTAssertEqual(next.reason, .none)
        XCTAssertFalse(next.beltDidNotStop)
    }

    func testTheHeartRateCeilingIsLatchedOntoTheSession() {
        let next = SessionRecorder.latchedStopFacts(current: untouched,
                                                     governorStopReason: .heartRateCeiling,
                                                     clientStopNotObeyed: false)
        XCTAssertEqual(next.reason, .heartRateCeiling)
    }

    func testAFailureToStopIsLatchedOntoTheSession() {
        let next = SessionRecorder.latchedStopFacts(current: untouched,
                                                     governorStopReason: nil,
                                                     clientStopNotObeyed: true)
        XCTAssertTrue(next.beltDidNotStop)
    }

    func testBothFactsLatchIndependently() {
        let next = SessionRecorder.latchedStopFacts(current: untouched,
                                                     governorStopReason: .heartRateCeiling,
                                                     clientStopNotObeyed: true)
        XCTAssertEqual(next.reason, .heartRateCeiling)
        XCTAssertTrue(next.beltDidNotStop)
    }

    func testFinding142ALaterTickWithNoGovernorReasonDoesNotErasePreviousBadNews() {
        // Finding 142's own mirror image: within *one* recording the reason must
        // not flicker off again just because a later tick sees no governor
        // reason — `ProgramRunner.governorStopReason` keeps standing on its own,
        // but this guards the session's copy even if that ever changed.
        let already = (reason: WorkoutStopReason.heartRateCeiling, beltDidNotStop: true)
        let next = SessionRecorder.latchedStopFacts(current: already,
                                                     governorStopReason: nil,
                                                     clientStopNotObeyed: false)
        XCTAssertEqual(next.reason, .heartRateCeiling)
        XCTAssertTrue(next.beltDidNotStop, "a stop this workout failed to obey stays a fact about this workout")
    }

    func testFinding142ANewSessionStartsWithNeitherFact() {
        // The other half of finding 142: a fresh `WorkoutSessionRecord` for
        // every `begin()` starts with neither fact set.
        let freshSession = WorkoutSessionRecord(startedAt: Date(), deviceName: "Test", programName: nil)
        XCTAssertEqual(freshSession.stopReason, .none)
        XCTAssertFalse(freshSession.beltDidNotStop)
    }

    // MARK: - The begin() boundary: SessionRecorder.begin() clears the runner's reason

    func testTheBeginBoundaryClearsAStaleHeartRateCeilingReason() {
        // What actually scopes a stop reason to the workout that set it is not
        // the fresh `WorkoutSessionRecord` above by itself — `latchStopFacts`
        // runs on every tick and would keep re-reading `ProgramRunner`'s own
        // field regardless of how fresh the session's record started out. The
        // scoping comes from `SessionRecorder.begin()` calling
        // `runner.forgetGovernorStopReason()` once its new session exists. This
        // drives a real runner to a real 97% ceiling stop, then documents that
        // boundary directly: after the call `begin()` makes, the reason reads
        // nil even though it was `.heartRateCeiling` the tick before.
        let key = ProgramRunner.heartRateControlDefaultsKey
        let previousSetting = UserDefaults.standard.object(forKey: key)
        defer {
            if let previousSetting {
                UserDefaults.standard.set(previousSetting, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let runner = ProgramRunner()
        runner.heartRateControlEnabled = true
        defer { runner.stop() }

        let recorder = SessionRecorder()
        let basis = HeartRateBasis(restingBpm: 60, maxBpm: 180) // stop ceiling: 175 bpm
        recorder.heartRateBasisProvider = { basis }
        recorder.freezeHeartRateBasis()

        let heart = StubBoundaryHeartRate(bpm: 176) // above the 175 stop ceiling
        runner.bindHeartRateControl(source: heart, basis: recorder)

        let target = HeartRateTarget(lowBpm: 144, highBpm: 155, actuator: .speed,
                                     startSpeedKmh: 6.0, startIncline: 0,
                                     minSpeedKmh: 4.0, maxSpeedKmh: 12.0,
                                     minIncline: 0, maxIncline: 0, fallbackSpeedKmh: 4.5)
        let segment = WorkoutSegment(name: "Zone 3", goal: .time(seconds: 600),
                                     target: .heartRate(target))
        let belt = MinimalGovernedTreadmill(speedKmh: 6.0)
        runner.start(WorkoutProgram(name: "HIIT", segments: [segment]), on: belt)

        for _ in 0..<20 { runner.tick(bySeconds: 1) }
        XCTAssertEqual(runner.governorStopReason, .heartRateCeiling,
                       "the fixture needs a real ceiling stop to document the boundary against")

        // The boundary `SessionRecorder.begin()` calls at the end of its own body.
        runner.forgetGovernorStopReason()

        XCTAssertNil(runner.governorStopReason,
                     "a workout beginning — program or manual — must not leave a stale " +
                     "ceiling reason standing for the next one to inherit")
    }
}

// MARK: - Test doubles for the begin() boundary test

/// The heart rate the governor may act on, held fixed for the fixture above.
@MainActor
private final class StubBoundaryHeartRate: GovernorHeartRateSource {
    let bpm: Int
    init(bpm: Int) { self.bpm = bpm }
    func governorHeartRateBpm() -> Int { bpm }
}

/// The smallest `TreadmillControlling` conformer that can drive a real
/// `ProgramRunner` into a genuine 97% ceiling stop: no console-dial or ramp
/// modelling, since this fixture is not about the hand-back — only about the
/// stop reason the ceiling leaves behind.
@MainActor
private final class MinimalGovernedTreadmill: TreadmillControlling {
    var state = TreadmillState()
    var limits = TreadmillLimits()
    var staleData = false
    private(set) var commandedSpeedKmh: Double
    private(set) var commandedIncline = 0
    var targetSpeedKmh: Double
    var targetIncline = 0
    private(set) var isStopOutstanding = false
    private(set) var stopNotObeyed = false
    private(set) var stopRequests = 0

    init(speedKmh: Double) {
        commandedSpeedKmh = speedKmh
        targetSpeedKmh = speedKmh
        state.status = .running
        state.speedKmh = speedKmh
    }

    var beltFacts: HeartRateGovernor.BeltFacts {
        HeartRateGovernor.BeltFacts(
            measured: HeartRateGovernor.Command(speedKmh: state.speedKmh,
                                                incline: state.inclinePercent))
    }

    func setTarget(speedKmh: Double, incline: Int) {
        commandedSpeedKmh = speedKmh
        commandedIncline = incline
        targetSpeedKmh = speedKmh
        targetIncline = incline
        state.speedKmh = speedKmh
        state.inclinePercent = incline
    }

    func startBelt(speedKmh: Double, incline: Int) {
        setTarget(speedKmh: speedKmh, incline: incline)
        state.status = .running
    }

    func requestStop() {
        stopRequests += 1
        isStopOutstanding = true
    }

    func segmentBegan() {}
}
