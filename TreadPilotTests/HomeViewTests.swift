// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import XCTest
@testable import TreadPilot

/// The two explicit warnings a 45-minute run on a real T40 asked for, and the
/// only reason they share one file: they are the two halves of one finding. The
/// Watch feed dropped once mid-run with nothing but a vanishing zone chip to say
/// so (`DashboardViewTests` below), and a program full of heart-rate segments
/// started with heart-rate control switched off and no warning before the belt
/// moved (`HomeViewTests` here).
///
/// Both suites test the pure conditions the two views branch on, in the style
/// `HistoryViewTests`/`ProgramEditorViewTests` established: no `View` is built
/// and no `@Environment` is read, because a view constructed outside a hierarchy
/// resolves its environment to defaults with nothing behind them.
final class HomeViewTests: XCTestCase {

    private func heartRateTarget() -> HeartRateTarget {
        HeartRateTarget(lowBpm: 144, highBpm: 155, actuator: .speed,
                        startSpeedKmh: 6.0, startIncline: 1,
                        minSpeedKmh: 4.0, maxSpeedKmh: 10.0,
                        minIncline: 0, maxIncline: 4,
                        fallbackSpeedKmh: 4.5)
    }

    private func fixedSegment() -> WorkoutSegment {
        WorkoutSegment(name: "Warm-up", duration: 300, targetSpeedKmh: 5.0, targetIncline: 0)
    }

    private func heartRateSegment() -> WorkoutSegment {
        WorkoutSegment(name: "Zone 3", goal: .time(seconds: 600),
                       target: .heartRate(heartRateTarget()))
    }

    private func warning(for program: WorkoutProgram, controlEnabled: Bool) -> String? {
        HomeView.heartRateControlOffWarning(for: program,
                                            isHeartRateControlEnabled: controlEnabled)
    }

    // MARK: - The one case that needs the warning

    func testAHeartRateProgramStartedWithControlOffIsWarnedAbout() {
        let program = WorkoutProgram(name: "HIIT", segments: [heartRateSegment()])
        let sentence = warning(for: program, controlEnabled: false)
        XCTAssertNotNil(sentence, "the belt is about to run governed segments fixed, and the "
                        + "dialog is the last moment before the countdown owns it")
        XCTAssertEqual(sentence, String(localized: "Heart-rate control is off in the profile, so this program's heart-rate segments will run fixed, at their start speeds."))
    }

    func testOneHeartRateSegmentAmongFixedOnesIsEnoughToWarn() {
        // The tester's own program shape: a warm-up, a governed block, a
        // cool-down. The governed block is the part that will not be governed.
        let program = WorkoutProgram(name: "Zone run",
                                     segments: [fixedSegment(), heartRateSegment(), fixedSegment()])
        XCTAssertNotNil(warning(for: program, controlEnabled: false))
    }

    // MARK: - The cases that must stay silent

    func testAHeartRateProgramWithControlOnIsNotWarnedAbout() {
        let program = WorkoutProgram(name: "HIIT", segments: [heartRateSegment()])
        XCTAssertNil(warning(for: program, controlEnabled: true),
                     "the opt-in is on, so the governed segments will actually be governed")
    }

    func testAProgramWithNoHeartRateSegmentIsNeverWarnedAbout() {
        let program = WorkoutProgram(name: "Steady",
                                     segments: [fixedSegment(), fixedSegment()])
        XCTAssertNil(warning(for: program, controlEnabled: false),
                     "nothing in this program asked for a band, so the opt-in changes nothing "
                     + "about how it runs")
        XCTAssertNil(warning(for: program, controlEnabled: true))
    }

    func testAnEmptyProgramIsNotWarnedAbout() {
        XCTAssertNil(warning(for: WorkoutProgram(name: "Empty", segments: []),
                             controlEnabled: false))
    }

    func testARecoveryGoalOnAFixedTargetIsNotWarnedAbout() {
        // The two axes are independent, and only the *target* axis asks the loop
        // to steer. A recovery segment's goal reads heart rate to decide when the
        // segment is over, and with no feed it is the plain timed segment its
        // mandatory cap already promises — so it is not what this one sentence is
        // about, and it must not drag the warning onto a program that has no
        // governed segment in it at all.
        let recovery = WorkoutSegment(name: "Recovery",
                                      goal: .untilHeartRateBelow(bpm: 120, maxSeconds: 300),
                                      target: .fixed(speedKmh: 4.5, incline: 0))
        let program = WorkoutProgram(name: "Intervals", segments: [fixedSegment(), recovery])
        XCTAssertNil(warning(for: program, controlEnabled: false))
    }
}

/// `DashboardView.isWatchSignalLost(isRecording:watchHasDelivered:freshWatchBpm:)`
/// — when the heart-rate cell says the Watch feed it *had* is gone. The three
/// states that matter are had-and-lost, never-had, and back again.
final class DashboardViewTests: XCTestCase {

    func testAFeedThatHadBeenDeliveringAndWentAbsentIsShownAsLost() {
        XCTAssertTrue(DashboardView.isWatchSignalLost(isRecording: true,
                                                      watchHasDelivered: true,
                                                      freshWatchBpm: 0))
    }

    func testAFeedThatNeverDeliveredThisWorkoutIsNotShownAsLost() {
        // No Watch, or a Watch app that failed to launch: the user must not get
        // a warning that can never clear. `watchProvidedHeartRate` is false for
        // the whole recording, exactly as the coverage figure reads 0%.
        XCTAssertFalse(DashboardView.isWatchSignalLost(isRecording: true,
                                                       watchHasDelivered: false,
                                                       freshWatchBpm: 0))
    }

    func testAFeedThatCameBackClearsTheWarning() {
        XCTAssertFalse(DashboardView.isWatchSignalLost(isRecording: true,
                                                       watchHasDelivered: true,
                                                       freshWatchBpm: 148))
    }

    func testNothingIsSaidWhileNoWorkoutIsBeingRecorded() {
        // Between workouts there is no feed to have lost, and no session record
        // to have credited one to either.
        XCTAssertFalse(DashboardView.isWatchSignalLost(isRecording: false,
                                                       watchHasDelivered: true,
                                                       freshWatchBpm: 0))
        XCTAssertFalse(DashboardView.isWatchSignalLost(isRecording: false,
                                                       watchHasDelivered: false,
                                                       freshWatchBpm: 0))
    }

    func testALiveHandlebarReadingDoesNotSuppressTheWarning() {
        // The merged reading the cell prints is a real 148 bpm from the grips,
        // and the Watch feed is still gone. Coverage counts the Watch and the
        // governor may only consume the Watch (spec section 4), so the warning
        // is driven by the Watch's own freshness and never by the merge.
        let merged = SessionRecorder.resolveHeartRate(watchBpm: 0, handlebarBpm: 148)
        XCTAssertEqual(merged.bpm, 148)
        XCTAssertFalse(merged.fromWatch, "the cell keeps its plain `Heart rate` title, never the ⌚ one")
        XCTAssertTrue(DashboardView.isWatchSignalLost(isRecording: true,
                                                      watchHasDelivered: true,
                                                      freshWatchBpm: 0))
    }

    func testAHandlebarOnlyWorkoutStaysSilentFromStartToFinish() {
        // The same handlebar reading in the other history: this user never had a
        // Watch feed at all, so the cell says nothing all workout.
        let merged = SessionRecorder.resolveHeartRate(watchBpm: 0, handlebarBpm: 148)
        XCTAssertEqual(merged.bpm, 148)
        XCTAssertFalse(DashboardView.isWatchSignalLost(isRecording: true,
                                                       watchHasDelivered: false,
                                                       freshWatchBpm: 0))
    }

    func testTheRecorderCreditsTheFirstWatchSecondTheWarningLaterDependsOn() {
        // The evidence chain, end to end: `SessionRecorder.record` sets
        // `watchProvidedHeartRate` on the first second the Watch supplies, a
        // fresh record per workout starts with it false, and this rule reads
        // exactly that flag — which is what keeps "never had" and "had and
        // lost" apart at all.
        let session = WorkoutSessionRecord(startedAt: Date(), deviceName: "T40", programName: nil)
        XCTAssertFalse(session.watchProvidedHeartRate, "a workout starts having been given nothing")
        XCTAssertFalse(DashboardView.isWatchSignalLost(isRecording: true,
                                                       watchHasDelivered: session.watchProvidedHeartRate,
                                                       freshWatchBpm: 0))

        let credited = SessionRecorder.resolveHeartRate(watchBpm: 141, handlebarBpm: 0)
        XCTAssertTrue(credited.fromWatch)
        session.watchProvidedHeartRate = credited.fromWatch

        XCTAssertTrue(DashboardView.isWatchSignalLost(isRecording: true,
                                                      watchHasDelivered: session.watchProvidedHeartRate,
                                                      freshWatchBpm: 0),
                      "once this workout has had a Watch second, its absence is news")
    }
}
