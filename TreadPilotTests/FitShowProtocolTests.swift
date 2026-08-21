// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import XCTest
@testable import TreadPilot

/// The frames' expected byte sequences come from the three concurring sources of
/// the research: FitShow vendor documentation v1.1, qdomyos-zwift
/// fitshowtreadmill.cpp, and tyge68/fitshow-treadmill.
final class FitShowProtocolTests: XCTestCase {

    private func hex(_ string: String) -> Data {
        Data(string.split(separator: " ").map { UInt8($0, radix: 16)! })
    }

    // MARK: - Encoding

    func testStatusPollFrame() {
        XCTAssertEqual(FitShowFrame.encode(FitShowCommands.statusPoll), hex("02 51 51 03"))
    }

    func testStartFrame() {
        XCTAssertEqual(FitShowFrame.encode(FitShowCommands.start),
                       hex("02 53 01 00 00 00 00 00 00 00 00 52 03"))
    }

    func testStopFrame() {
        XCTAssertEqual(FitShowFrame.encode(FitShowCommands.stop), hex("02 53 03 50 03"))
    }

    func testPauseFrame() {
        // Vendor CONTROL_PAUSE (0x0A) — QZ's 0x06 got stuck on the T40 (#181).
        XCTAssertEqual(FitShowFrame.encode(FitShowCommands.pause), hex("02 53 0A 59 03"))
    }

    func testSetTarget8kmh2Percent() {
        let payload = FitShowCommands.setTarget(speedKmh: 8.0, inclinePercent: 2,
                                                limits: TreadmillLimits())
        // The FCS here happens to be 0x03 — which is why framing on the 0x03 byte is forbidden.
        XCTAssertEqual(FitShowFrame.encode(payload), hex("02 53 02 50 02 03 03"))
    }

    func testSetTarget12_5kmh0Percent() {
        let payload = FitShowCommands.setTarget(speedKmh: 12.5, inclinePercent: 0,
                                                limits: TreadmillLimits())
        XCTAssertEqual(FitShowFrame.encode(payload), hex("02 53 02 7D 00 2C 03"))
    }

    func testUserInitFrame() {
        let payload = FitShowCommands.userInit(userId: 0, weightKg: 75)
        XCTAssertEqual(FitShowFrame.encode(payload), hex("02 53 00 00 00 6E 1E 4B 68 03"))
    }

    func testInfoQueries() {
        XCTAssertEqual(FitShowFrame.encode(FitShowCommands.infoSpeed), hex("02 50 02 52 03"))
        XCTAssertEqual(FitShowFrame.encode(FitShowCommands.infoIncline), hex("02 50 03 53 03"))
        XCTAssertEqual(FitShowFrame.encode(FitShowCommands.sportData), hex("02 52 00 52 03"))
    }

    func testSetTargetClampsToLimits() {
        let limits = TreadmillLimits() // T40 defaults: max 16.0 km/h, incline 0–12
        let tooFast = FitShowCommands.setTarget(speedKmh: 99, inclinePercent: 50, limits: limits)
        XCTAssertEqual(tooFast[2], 160)
        XCTAssertEqual(tooFast[3], 12)
        let tooSlow = FitShowCommands.setTarget(speedKmh: 0, inclinePercent: -5, limits: limits)
        XCTAssertEqual(tooSlow[2], 8)
        XCTAssertEqual(tooSlow[3], 0)
    }

    // MARK: - Decoding

    func testDecodeRejectsBadChecksum() {
        XCTAssertNil(FitShowFrame.decode(hex("02 51 50 03")))
        XCTAssertNil(FitShowFrame.decode(hex("02 51")))
        XCTAssertNil(FitShowFrame.decode(hex("01 51 51 03")))
    }

    func testDecodeIdleFrame() {
        let payload = FitShowFrame.decode(hex("02 51 00 51 03"))
        XCTAssertNotNil(payload)
        XCTAssertEqual(FitShowParser.parse(payload!), .idle)
    }

    func testParseRunDataFrame() throws {
        // Example frame: 8.0 km/h, 2%, 60 s, 2.0 km, 50 kcal, 150 steps, 120 bpm.
        let payload = try XCTUnwrap(FitShowFrame.decode(
            hex("02 51 03 50 02 3C 00 14 00 32 00 96 00 78 00 F4 03")))
        guard case .runData(let data) = FitShowParser.parse(payload) else {
            return XCTFail("expected a runData event")
        }
        XCTAssertEqual(data.status, .running)
        XCTAssertEqual(data.speedKmh, 8.0, accuracy: 0.001)
        XCTAssertEqual(data.inclinePercent, 2)
        XCTAssertEqual(data.elapsedSeconds, 60)
        XCTAssertEqual(data.distanceKm, 2.0, accuracy: 0.001)
        XCTAssertEqual(data.kcal, 50)
        XCTAssertEqual(data.steps, 150)
        XCTAssertEqual(data.heartRate, 120)
    }

    // MARK: - Step-count plausibility choice (task #180)

    func testStepsByteSwapHealing() {
        // The bug seen on the T40: 54 steps sent as LE, read as BE gives 13824.
        XCTAssertEqual(FitShowParser.plausibleSteps(primary: 13824, secondary: 54,
                                                    elapsedSeconds: 30), 54)
        // It works in the reverse direction too.
        XCTAssertEqual(FitShowParser.plausibleSteps(primary: 54, secondary: 13824,
                                                    elapsedSeconds: 30), 54)
        // If neither reading is plausible, 0.
        XCTAssertEqual(FitShowParser.plausibleSteps(primary: 60000, secondary: 30000,
                                                    elapsedSeconds: 10), 0)
        // For a long workout even a large value is plausible.
        XCTAssertEqual(FitShowParser.plausibleSteps(primary: 9000, secondary: 5000,
                                                    elapsedSeconds: 3600), 9000)
    }

    func testAnyRunStepsSentLittleEndianAreHealed() throws {
        // The AnyRun variant, but the step count arrives as LE (54 = 36 00):
        // the BE reading (13824) is implausible at 30 s → we pick the LE one.
        let frame: [UInt8] = [0x51, 0x03, 0x1E, 0x00, 0x00, 0x1E, 0x00, 0x00,
                              0x00, 0x02, 0x36, 0x00, 0x00, 0x00]
        let payload = try XCTUnwrap(FitShowFrame.decode(FitShowFrame.encode(frame)))
        guard case .runData(let data) = FitShowParser.parse(payload, variant: .anyRun) else {
            return XCTFail("expected a runData event")
        }
        XCTAssertEqual(data.elapsedSeconds, 30)
        XCTAssertEqual(data.steps, 54)
    }

    // MARK: - Handlebar heart-rate plausibility

    func testAGarbledHeartRateByteArrivesAsNoReading() throws {
        // The run-data frame of testParseRunDataFrame with 250 bpm in the
        // heart-rate byte: nobody's heart did that, so it must reach the app as
        // 0 ("no reading"), never as a heart rate the calorie estimate, the
        // samples, the Health export or the zone chip can believe.
        let payload = try XCTUnwrap(FitShowFrame.decode(
            FitShowFrame.encode([0x51, 0x03, 0x50, 0x02, 0x3C, 0x00, 0x14, 0x00,
                                 0x32, 0x00, 0x96, 0x00, 250, 0x00])))
        guard case .runData(let data) = FitShowParser.parse(payload) else {
            return XCTFail("expected a runData event")
        }
        XCTAssertEqual(data.heartRate, 0)
        // The rest of the frame is untouched: one bad byte is not a bad frame.
        XCTAssertEqual(data.speedKmh, 8.0, accuracy: 0.001)
        XCTAssertEqual(data.steps, 150)
    }

    func testHandlebarHeartRateBandEdges() {
        // 0 is the sensor's own value for "grips not held" and stays 0.
        XCTAssertEqual(FitShowParser.plausibleHeartRate(0), 0)
        XCTAssertEqual(FitShowParser.plausibleHeartRate(29), 0)
        XCTAssertEqual(FitShowParser.plausibleHeartRate(30), 30)
        XCTAssertEqual(FitShowParser.plausibleHeartRate(148), 148)
        XCTAssertEqual(FitShowParser.plausibleHeartRate(230), 230)
        XCTAssertEqual(FitShowParser.plausibleHeartRate(231), 0)
        // The byte's own ceiling — the value a stuck line produces.
        XCTAssertEqual(FitShowParser.plausibleHeartRate(255), 0)
    }

    // MARK: - Handlebar reading freshness

    func testAFreshReadingKeepsItsHeartRate() {
        XCTAssertEqual(FitShowTreadmillClient.freshHeartRate(148, readingAge: 0), 148)
        XCTAssertEqual(FitShowTreadmillClient.freshHeartRate(
            148, readingAge: FitShowTreadmillClient.freshnessHorizonSeconds), 148)
    }

    func testAStaleReadingExpiresToNoReading() {
        // The reproduction: the belt keeps running and the link goes quiet for a
        // minute. The dashboard said "Z3 · 148 bpm" off a minute-old byte and
        // the recorder booked those seconds as covered.
        XCTAssertEqual(FitShowTreadmillClient.freshHeartRate(148, readingAge: 60), 0)
        // One poll interval past the horizon is already too old.
        XCTAssertEqual(FitShowTreadmillClient.freshHeartRate(
            148, readingAge: FitShowTreadmillClient.freshnessHorizonSeconds + 0.2), 0)
    }

    func testFramesThatCarryNoHeartRateCannotKeepTheReadingAlive() {
        // Holding the speed "+" button makes every 0.2 s tick write a command, so
        // the console answers with bare echoes that parse as .statusOnly. Those
        // frames are fresh and carry no heart rate: the reading ages off its own
        // arrival, which is 12 s ago here, so it must expire anyway.
        XCTAssertEqual(FitShowTreadmillClient.freshHeartRate(148, readingAge: 12), 0)
    }

    func testParseCountdown() throws {
        // Countdown: status 0x02, the next byte is the remaining seconds.
        let payload = try XCTUnwrap(FitShowFrame.decode(hex("02 51 02 05 56 03")))
        XCTAssertEqual(FitShowParser.parse(payload), .countdown(seconds: 5))
    }

    func testParseNegativeIncline() throws {
        // Incline is to be read as int8: 0xFF = -1%.
        var frame: [UInt8] = [0x51, 0x03, 0x50, 0xFF, 0x3C, 0x00, 0x14, 0x00,
                              0x32, 0x00, 0x10, 0x27, 0x78, 0x00]
        let payload = try XCTUnwrap(FitShowFrame.decode(FitShowFrame.encode(frame)))
        guard case .runData(let data) = FitShowParser.parse(payload) else {
            return XCTFail("expected a runData event")
        }
        XCTAssertEqual(data.inclinePercent, -1)

        frame[3] = 0x0C
        let positive = try XCTUnwrap(FitShowFrame.decode(FitShowFrame.encode(frame)))
        guard case .runData(let positiveData) = FitShowParser.parse(positive) else {
            return XCTFail("expected a runData event")
        }
        XCTAssertEqual(positiveData.inclinePercent, 12)
    }

    func testDecodeFrameWhoseChecksumIs0x03() {
        // Here the FCS is itself 0x03 — the decoder has to unpack this flawlessly too,
        // proving it does not look for the 0x03 byte as a frame terminator.
        XCTAssertEqual(FitShowFrame.decode(hex("02 53 02 50 02 03 03")),
                       [0x53, 0x02, 0x50, 0x02])
    }

    func testParseSignedInclineLimits() throws {
        // Incline-limit reply: max +12%, min -3% (0xFD as int8), pause supported (bit1).
        let payload = try XCTUnwrap(FitShowFrame.decode(
            FitShowFrame.encode([0x50, 0x03, 0x0C, 0xFD, 0x02])))
        XCTAssertEqual(FitShowParser.parse(payload),
                       .inclineLimits(max: 12, min: -3, pauseSupported: true))
    }

    func testParsePausedStatus() throws {
        let payload = try XCTUnwrap(FitShowFrame.decode(FitShowFrame.encode([0x51, 0x0A])))
        XCTAssertEqual(FitShowParser.parse(payload), .statusOnly(.paused))
    }

    func testBareStatusEchoIsNotIdle() throws {
        // The echo of our own 02 51 51 03 poll cannot mean the belt is stopped —
        // otherwise an echoing console would falsely switch to stopped.
        let payload = try XCTUnwrap(FitShowFrame.decode(hex("02 51 51 03")))
        XCTAssertNotEqual(FitShowParser.parse(payload), .idle)
    }

    func testParseSpeedLimits() throws {
        // SYS_INFO speed reply: max 160 (16.0 km/h), min 8 (0.8 km/h).
        let payload = try XCTUnwrap(FitShowFrame.decode(
            FitShowFrame.encode([0x50, 0x02, 160, 8, 0])))
        XCTAssertEqual(FitShowParser.parse(payload), .speedLimits(maxRaw: 160, minRaw: 8))
    }

    func testParseInclineUnsupportedOnShortReply() throws {
        let payload = try XCTUnwrap(FitShowFrame.decode(FitShowFrame.encode([0x50, 0x03])))
        XCTAssertEqual(FitShowParser.parse(payload), .inclineUnsupported)
    }

    // MARK: - The AnyRun variant (behaviour observed on a real T40, task #171)

    func testAnyRunTimeIsMinuteSecondPair() throws {
        // Time 2:15 on an AnyRun console: payload[4]=2 (minutes), payload[5]=15 (seconds).
        let frame: [UInt8] = [0x51, 0x03, 0x50, 0x02, 0x02, 0x0F, 0x00, 0x02,
                              0x00, 0x06, 0x00, 0x64, 0x4E, 0x00]
        let payload = try XCTUnwrap(FitShowFrame.decode(FitShowFrame.encode(frame)))
        guard case .runData(let data) = FitShowParser.parse(payload, variant: .anyRun) else {
            return XCTFail("expected a runData event")
        }
        XCTAssertEqual(data.elapsedSeconds, 135)
        XCTAssertEqual(data.distanceKm, 0.2, accuracy: 0.001)
        XCTAssertEqual(data.kcal, 6)
        XCTAssertEqual(data.steps, 100)
        XCTAssertEqual(data.heartRate, 78)
    }

    func testUserReportedKcalByteSwap() throws {
        // The bug seen on the real treadmill: 6 kcal arrives big-endian (00 06) —
        // with the standard (little-endian) reading it became 1536.
        let frame: [UInt8] = [0x51, 0x03, 0x1E, 0x00, 0x00, 0x0A, 0x00, 0x00,
                              0x00, 0x06, 0x00, 0x00, 0x00, 0x00]
        let payload = try XCTUnwrap(FitShowFrame.decode(FitShowFrame.encode(frame)))
        guard case .runData(let wrong) = FitShowParser.parse(payload, variant: .standard),
              case .runData(let right) = FitShowParser.parse(payload, variant: .anyRun) else {
            return XCTFail("expected a runData event")
        }
        XCTAssertEqual(wrong.kcal, 1536)
        XCTAssertEqual(right.kcal, 6)
        XCTAssertEqual(right.elapsedSeconds, 10)
    }

    func testVariantDetectorRecognizesStandard() {
        // With standard, the 4th byte (the low byte of a u16le) advances every second.
        var detector = FitShowVariantDetector()
        detector.observeRunningFrame([0x51, 0x03, 0x1E, 0x00, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        detector.observeRunningFrame([0x51, 0x03, 0x1E, 0x00, 11, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(detector.detected, .standard)
    }

    func testVariantDetectorRecognizesAnyRun() {
        // With AnyRun the 5th byte (seconds) advances while the 4th (minutes) stays put.
        var detector = FitShowVariantDetector()
        detector.observeRunningFrame([0x51, 0x03, 0x1E, 0x00, 0, 9, 0, 0, 0, 0, 0, 0, 0, 0])
        detector.observeRunningFrame([0x51, 0x03, 0x1E, 0x00, 0, 10, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(detector.detected, .anyRun)
    }

    func testVariantDetectorSkipsMinuteWrap() {
        // At a minute boundary both bytes change — no decision may be made from that.
        var detector = FitShowVariantDetector()
        detector.observeRunningFrame([0x51, 0x03, 0x1E, 0x00, 0, 59, 0, 0, 0, 0, 0, 0, 0, 0])
        detector.observeRunningFrame([0x51, 0x03, 0x1E, 0x00, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertNil(detector.detected)
        detector.observeRunningFrame([0x51, 0x03, 0x1E, 0x00, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(detector.detected, .anyRun)
    }

    func testParseExtendedLimits() throws {
        // SYS_INFO 0x05 reply: max 160 (16.0 km/h), min 8, incline 0–12.
        let payload = try XCTUnwrap(FitShowFrame.decode(
            FitShowFrame.encode([0x50, 0x05, 160, 8, 12, 0, 1, 5])))
        XCTAssertEqual(FitShowParser.parse(payload),
                       .extendedLimits(maxSpeedRaw: 160, minSpeedRaw: 8,
                                       maxIncline: 12, minIncline: 0))
    }

    func testInfoExtendedFrame() {
        XCTAssertEqual(FitShowFrame.encode(FitShowCommands.infoExtended), hex("02 50 05 55 03"))
    }

    func testEncodeDecodeRoundTrip() {
        let payloads: [[UInt8]] = [
            FitShowCommands.statusPoll,
            FitShowCommands.start,
            FitShowCommands.stop,
            FitShowCommands.setTarget(speedKmh: 10.5, inclinePercent: 3, limits: TreadmillLimits()),
        ]
        for payload in payloads {
            XCTAssertEqual(FitShowFrame.decode(FitShowFrame.encode(payload)), payload)
        }
    }

    // MARK: - Demo heart-rate plant (finding 72)
    //
    // The lag is a pure, `self`-free step so it is testable directly instead
    // of only through the 1 Hz demo timer — without instantiating
    // `FitShowTreadmillClient` itself, which every test in this file already
    // avoids (it owns a live `CBCentralManager`).

    func testDemoHeartRatePlantIsDeterministic() {
        let first = FitShowTreadmillClient.demoHeartRateStep(current: 90, speedKmh: 8.0)
        let second = FitShowTreadmillClient.demoHeartRateStep(current: 90, speedKmh: 8.0)
        XCTAssertEqual(first, second)
    }

    func testDemoHeartRatePlantConvergesTowardASpeedDependentSteadyState() {
        var bpm = 60.0
        for _ in 0..<600 {
            bpm = FitShowTreadmillClient.demoHeartRateStep(current: bpm, speedKmh: 8.0)
        }
        // 60 resting + 11 bpm per km/h × 8 km/h = 148: the plant's own
        // steady-state formula, reached after many time constants at τ ≈ 30 s.
        XCTAssertEqual(bpm, 148, accuracy: 0.5)
    }

    func testDemoHeartRatePlantRecoversWhenTheBeltSlows() {
        var bpm = 160.0
        for _ in 0..<600 {
            bpm = FitShowTreadmillClient.demoHeartRateStep(current: bpm, speedKmh: 0)
        }
        XCTAssertEqual(bpm, 60, accuracy: 0.5)
    }

    /// Finding 144: `state.heartRate` is expired by the reading's own age in
    /// `tick()`, and demo mode never reaches it — no write characteristic, no
    /// poll timer, the demo runs on its own 1 Hz timer instead. So a paused demo
    /// belt left the last bpm on screen for as long as the pause lasted, and
    /// phase 2's rule that the zone chip disappears once the reading goes stale
    /// was broken in the one mode used for screenshots and App Store review. Both
    /// halted states now go through one rule, which is also what the real client
    /// does: a paused console sends no run-data frames, so a handlebar reading
    /// expires within `freshnessHorizonSeconds`.
    func testAHaltedDemoBeltHasNoSpeedAndNoHeartRateToShow() {
        var running = TreadmillState()
        running.status = .running
        running.speedKmh = 8.0
        running.heartRate = 151
        running.elapsedSeconds = 300
        for status in [FitShow.Status.paused, .idle] {
            let halted = FitShowTreadmillClient.demoBeltHalted(running, status: status)
            XCTAssertEqual(halted.status, status)
            XCTAssertEqual(halted.speedKmh, 0)
            XCTAssertEqual(halted.heartRate, 0, "\(status): a stale reading is no reading")
            XCTAssertEqual(halted.elapsedSeconds, 300,
                           "\(status): the workout so far is not undone by halting")
        }
    }

    /// Finding 145: `startDemo()` used to clear the outstanding stop **and** set
    /// `stopNotObeyed = false`, so entering demo mode after a real console refused
    /// a stop erased the red banner and the stop-at-the-console instruction with
    /// it — and the demo button sits on the scan screen of every build, not only
    /// the simulator's. It now goes through `abandonStopKeepingFailure()`, the
    /// same path `disconnect()` takes, so the demo entry has no rule of its own
    /// any more and this is the rule it delegates to. (Asserted here rather than
    /// on a client instance for the reason at the top of this section.)
    func testEnteringDemoModeDropsTheRequestAndKeepsTheFailure() {
        let refused = OutstandingStop(speedAtRequestKmh: 9.0, lastSpeedKmh: 9.0)
        XCTAssertTrue(FitShowTreadmillClient.abandonRaisesFailure(refused),
                      "a belt last seen running is still a belt somebody has to walk over to")
        var windDown = OutstandingStop(speedAtRequestKmh: 9.0, lastSpeedKmh: 4.0)
        windDown.wasObservedSlowing = true
        XCTAssertFalse(FitShowTreadmillClient.abandonRaisesFailure(windDown),
                       "an ordinary program end raises nothing, on this path as on every other")
        // `startDemo()` now refuses entry outside the disconnected phases (below),
        // and that guard must not have made this delegation vacuous: finding 145's
        // own scenario ends in `.idle` — a console that refused a stop and then
        // went out of radio range times out in `failPreparation` — which is a
        // phase demo mode may still be entered from.
        XCTAssertTrue(FitShowTreadmillClient.mayEnterDemo(phase: .idle))
    }

    // MARK: - Demo mode may not be laid over a live link
    //
    // `demoMode` is an invariant of the client — nothing real written, nothing
    // real read — but the only thing that used to enforce it was `ContentView`'s
    // routing table, which shows `ScanView` (and with it the DEMO MODE button)
    // exactly in the three phases without a peripheral link. With a link up,
    // `tick()` at 200 ms and `demoTick()` at 1 Hz would both write `state`, and
    // `demoMode` short-circuits every command path, so a real belt at 10 km/h
    // would have become uncommandable — its stop button mutating a local struct
    // instead of sending a stop frame.

    func testDemoModeMayBeEnteredFromEveryPhaseTheScanScreenShows() {
        // The exact set `ContentView` routes to `ScanView`: the working entry
        // path from the DEMO MODE button is unchanged.
        for phase in [ConnectionPhase.idle, .scanning, .bluetoothOff] {
            XCTAssertTrue(FitShowTreadmillClient.mayEnterDemo(phase: phase),
                          "\(phase): no peripheral link, nothing to lay a demo over")
        }
    }

    func testDemoModeIsRefusedWhileThereIsALinkToARealTreadmill() {
        for phase in [ConnectionPhase.connecting(name: "T40"),
                      .preparing(name: "T40"),
                      .ready(name: "T40")] {
            XCTAssertFalse(FitShowTreadmillClient.mayEnterDemo(phase: phase),
                           "\(phase): a real belt must not become uncommandable")
        }
    }

    // MARK: - The one reconcile rule (findings 75, 76, 80)

    private func reconciledSpeedUnits(command: Int, measured: Int,
                                      age: TimeInterval = 30) -> Int {
        FitShowTreadmillClient.reconciled(commandUnits: command, measuredUnits: measured,
                                          secondsSinceCommand: age, ignoreZeroMeasurement: true)
    }

    func testInsideTheHoldOffTheAppsOwnCommandStands() {
        // Two quick "+" taps have to accumulate instead of each stepping from a
        // belt that has not caught up.
        XCTAssertEqual(reconciledSpeedUnits(command: 85, measured: 80, age: 0), 85)
        XCTAssertEqual(reconciledSpeedUnits(
            command: 85, measured: 80,
            age: FitShowTreadmillClient.targetHoldOffSeconds), 85)
    }

    func testPastTheHoldOffTheTargetFollowsTheBeltWithNoDeadBand() {
        // The 0.1 km/h dead band is gone: one tenth is a whole protocol quantum
        // and the only thing a single console press produces.
        XCTAssertEqual(reconciledSpeedUnits(command: 82, measured: 81), 81)
        XCTAssertEqual(reconciledSpeedUnits(command: 60, measured: 59), 59)
        // And the incline dead band with it: one level was the whole of the
        // incline axis's evidence (finding 75).
        XCTAssertEqual(FitShowTreadmillClient.reconciled(commandUnits: 5, measuredUnits: 4,
                                                         secondsSinceCommand: 30,
                                                         ignoreZeroMeasurement: false), 4)
    }

    func testAStandingBeltIsNotASpeedTargetButZeroIsALegitimateIncline() {
        // 0 km/h is a belt that has stopped; 0% is a hill nobody is on.
        XCTAssertEqual(reconciledSpeedUnits(command: 80, measured: 0), 80)
        XCTAssertEqual(FitShowTreadmillClient.reconciled(commandUnits: 5, measuredUnits: 0,
                                                         secondsSinceCommand: 30,
                                                         ignoreZeroMeasurement: false), 0)
    }

    /// Every speed the protocol can carry, in tenths: 0.8 km/h to 20.0 km/h, the
    /// range the review enumerated. `TreadmillLimits` narrows it per device; the
    /// rules below are the same at every one of them.
    private let settableSpeedUnits = 8...200

    func testTheReconcileRuleIsExactAtEverySpeedTheDeviceOffers() {
        // Finding 76 enumerated: one 0.1 km/h quantum is 0.09999999999999964 as a
        // `Double`, so the old `abs(target - measured) >= 0.1` test was false for
        // 114 of the 193 settable speeds — 8.2 → 8.1 and 6.0 → 5.9 among them. In
        // protocol units there is no such thing as a comparison that nearly works.
        var blindInFloatingPoint = 0
        for units in settableSpeedUnits.dropFirst() {
            let downOne = units - 1
            XCTAssertEqual(reconciledSpeedUnits(command: units, measured: downOne), downOne,
                           "one press down from \(units) tenths")
            if abs(Double(units) / 10 - Double(downOne) / 10) < 0.1 { blindInFloatingPoint += 1 }
        }
        XCTAssertEqual(settableSpeedUnits.count, 193)
        XCTAssertEqual(blindInFloatingPoint, 114,
                       "the float comparison this rule no longer makes was blind here")
    }

    // MARK: - Fact 3: the console dial (findings 74, 75, 76, 77)

    /// One axis, driven the way the client drives it: a command, then a second of
    /// measurements per element of `measured`.
    private func dialAxis(_ axis: ConsoleDialAxis, command: Int, measuredAtCommand: Int,
                          then measured: [Int], deltaSeconds: Double = 1) -> ConsoleDialAxis {
        var axis = axis
        axis.commanded(units: command, measured: measuredAtCommand)
        for value in measured { axis.observe(measured: value, deltaSeconds: deltaSeconds) }
        return axis
    }

    func testADecisiveConsolePressIsSeenAtEverySpeedTheDeviceOffers() {
        // The acceptance criterion, enumerated over the whole device range and in
        // both directions: the belt has reached the app's command and then leaves
        // it decisively. **Inverted from what this test used to assert** — it
        // pinned one and two tenths as a person, and the spec now reserves the
        // hand-back for at least half a km/h. One tenth is also what a footfall
        // loading the belt, a stalling motor and a console reporting actual rather
        // than setpoint speed produce, and a false hand-back disables governing
        // *and* the feed-loss protection for the rest of a segment.
        let settled = Int(ConsoleDialAxis.settledSeconds) + 1
        let decisive = ConsoleDialAxis.forSpeed.decisiveUnits
        for units in settableSpeedUnits {
            for pressed in [units - decisive, units + decisive]
            where settableSpeedUnits.contains(pressed) {
                let axis = dialAxis(.forSpeed, command: units, measuredAtCommand: units,
                                    then: Array(repeating: pressed, count: settled))
                XCTAssertTrue(axis.isSetByHand,
                              "\(units) tenths pressed to \(pressed) is a person")
            }
            // And nothing inside the confusions is classified at all, however long
            // it stands: one and two tenths are a console's own bias, a footfall,
            // or a motor a shade off its setpoint.
            for pressed in [units - 2, units - 1, units + 1, units + 2]
            where settableSpeedUnits.contains(pressed) {
                let axis = dialAxis(.forSpeed, command: units, measuredAtCommand: units,
                                    then: Array(repeating: pressed, count: 60))
                XCTAssertFalse(axis.isSetByHand,
                               "\(units) to \(pressed) is inside a quantum or two: not classified")
            }
        }
    }

    func testADecisiveInclinePressIsSeenOnTheInclineAxisAtEveryLevel() {
        // The same inversion on the incline axis: two levels, not one.
        let limits = TreadmillLimits()
        let decisive = ConsoleDialAxis.forIncline.decisiveUnits
        for level in limits.minIncline...limits.maxIncline {
            for pressed in [level - decisive, level + decisive] where
                pressed >= limits.minIncline && pressed <= limits.maxIncline {
                // The incline motor takes seconds a level, so the press is seen
                // once the level it settled at has stopped changing.
                let axis = dialAxis(.forIncline, command: level, measuredAtCommand: level,
                                    then: Array(repeating: pressed, count: 4))
                XCTAssertTrue(axis.isSetByHand, "level \(level) pressed to \(pressed)")
            }
            for pressed in [level - 1, level + 1] where
                pressed >= limits.minIncline && pressed <= limits.maxIncline {
                let axis = dialAxis(.forIncline, command: level, measuredAtCommand: level,
                                    then: Array(repeating: pressed, count: 60))
                XCTAssertFalse(axis.isSetByHand, "one level is not a takeover: \(level)")
            }
        }
    }

    func testABeltStillTravellingTowardsTheCommandIsNotAPerson() {
        // The ramp the deleted corridor existed for, told apart by physics rather
        // than by a window: a belt heading for the command keeps moving, and it is
        // inside its own travel allowance.
        let axis = dialAxis(.forSpeed, command: 40, measuredAtCommand: 120,
                            then: [115, 110, 105, 100, 95, 90, 85, 80])
        XCTAssertFalse(axis.isSetByHand)
        XCTAssertTrue(axis.isTravelling, "it is inside its own travel allowance")
    }

    func testAnInclineMotorStillTravellingIsNotAPersonEitherAtItsOwnRate() {
        // Five seconds a level: the level it is passing through stands still for
        // several observations, which is exactly what a settled value looks like.
        // The travel allowance is what keeps it from reading as a hand.
        var measured: [Int] = []
        for level in [0, 1, 2, 3] { measured += Array(repeating: level, count: 5) }
        let axis = dialAxis(.forIncline, command: 8, measuredAtCommand: 0, then: measured)
        XCTAssertFalse(axis.isSetByHand, "a motor at 0.2 levels a second is not a hand")
        XCTAssertTrue(axis.isTravelling)
    }

    func testAConsoleChangeMadeDuringAnEntryRampIsSeen() {
        // Finding 77: a manual intervention is exactly what prevents the belt from
        // arriving, so the corridor stayed open for the whole segment and the loop
        // adopted the person's value as the starting point for an *increase*. Here
        // the app commands 4.0 from 12.0 and the user stops the belt's descent at
        // 6.0 — it never arrives, and past the allowance a value it has settled
        // decisively away from the command, against the direction asked for, is a
        // person's.
        let ramping = [115, 110, 105, 100, 95, 90, 85, 80, 75, 70, 65, 60]
        let axis = dialAxis(.forSpeed, command: 40, measuredAtCommand: 120,
                            then: ramping + Array(repeating: 60, count: 12))
        XCTAssertTrue(axis.isSetByHand)
        XCTAssertFalse(axis.isTravelling)
    }

    func testAConsoleWithAConstantOneTenthBiasNeverHandsControlBack() {
        // **Finding 127, and the inversion that resolves it.** A console that
        // re-rounds its own setpoint reports 7.9 for 8.0 for ever. The old rule
        // separated that bias from a press by how long it stood — which does not
        // separate them at all, because a press stands for ever too — so every
        // one-quantum governor step produced a guaranteed false hand-back a few
        // seconds later. Under the decisive threshold neither reading is
        // classified, whether the console ever reaches the command or not.
        let neverArrived = dialAxis(.forSpeed, command: 80, measuredAtCommand: 60,
                                    then: Array(repeating: 79, count: 60))
        XCTAssertFalse(neverArrived.isSetByHand,
                       "one tenth off a command it never reached is a console's own bias")
        XCTAssertFalse(neverArrived.isTravelling,
                       "and it is long past the time the journey takes")
        let arrivedThenBiased = dialAxis(.forSpeed, command: 80, measuredAtCommand: 80,
                                         then: Array(repeating: 79, count: 60))
        XCTAssertFalse(arrivedThenBiased.isSetByHand,
                       "a tenth that is still there a minute later is still a tenth")
        // The governor's own step is what used to trip it: one quantum up, and the
        // biased console lands one quantum short of the new command for ever.
        var stepped = dialAxis(.forSpeed, command: 80, measuredAtCommand: 80,
                               then: Array(repeating: 79, count: 20))
        stepped.commanded(units: 82, measured: 79)
        for _ in 0..<60 { stepped.observe(measured: 81, deltaSeconds: 1) }
        XCTAssertFalse(stepped.isSetByHand, "a governor step onto a biased console is not a hand")
        // And that console's own dial is still seen when it is turned decisively.
        var pressed = stepped
        pressed.observe(measured: 75, deltaSeconds: 1)
        pressed.observe(measured: 75, deltaSeconds: 1)
        pressed.observe(measured: 75, deltaSeconds: 1)
        XCTAssertTrue(pressed.isSetByHand, "half a km/h off the value it reached is a dial")
    }

    func testADialTurnedBackToTheCommandStaysHandedBackForTheSegment() {
        // **Inverted, and finding 126 is why.** The verdict used to be released by
        // observing the belt at the app's command — including when the loop's own
        // step happened to land on the value the user had just dialled to, which
        // erased a small console press and let the loop adopt the person's number
        // as its own baseline. The spec's rule is the rest of the segment, so the
        // release is gone: only a boundary or an explicit start retires a verdict.
        var axis = dialAxis(.forSpeed, command: 80, measuredAtCommand: 80,
                            then: [74, 74, 74])
        XCTAssertTrue(axis.isSetByHand)
        axis.observe(measured: 80, deltaSeconds: 1)
        XCTAssertTrue(axis.isSetByHand, "governing resumes at the next segment, not before")
        axis.segmentBegan()
        XCTAssertFalse(axis.isSetByHand)
    }

    func testARadioGapIsNoEvidenceAtAll() {
        // Nothing was measured during the gap, so a value that looks unchanged
        // across it has not been observed to stand still. Otherwise a stale link
        // would manufacture a hand-back out of silence.
        var axis = ConsoleDialAxis.forSpeed
        axis.commanded(units: 80, measured: 80)
        axis.observe(measured: 74, deltaSeconds: 60)
        axis.observe(measured: 74, deltaSeconds: 60)
        XCTAssertFalse(axis.isSetByHand)
        // And the evidence resumes the moment frames do.
        axis.observe(measured: 74, deltaSeconds: 1)
        axis.observe(measured: 74, deltaSeconds: 1)
        XCTAssertTrue(axis.isSetByHand)
    }

    func testTheAppsOwnWriteDoesNotDropTheEvidenceOfAPerson() {
        // **Inverted from "the app's own write drops the evidence" (finding 126).**
        // A control-loop write is one step from the reference, and the reference is
        // the belt — so a write that "matches" the belt is the loop adopting the
        // person's own number, which is the thing the hand-back exists to stop. The
        // one release a write ever made is gone.
        var detector = ConsoleDialDetector()
        detector.commanded(speedUnits: 80, incline: 4, measuredSpeedUnits: 80, measuredIncline: 4)
        for _ in 0..<3 {
            detector.observe(measuredSpeedUnits: 74, measuredIncline: 6, deltaSeconds: 1)
        }
        XCTAssertTrue(detector.isSetByHand)
        XCTAssertTrue(detector.speed.isSetByHand)
        XCTAssertTrue(detector.incline.isSetByHand)
        detector.commanded(speedUnits: 74, incline: 6, measuredSpeedUnits: 74, measuredIncline: 6)
        XCTAssertTrue(detector.isSetByHand, "the loop naming the person's value is not a release")
        detector.segmentBegan()
        XCTAssertFalse(detector.isSetByHand)
    }

    func testTheTwoAxesAreInferredIndependently()
    {
        var detector = ConsoleDialDetector()
        detector.commanded(speedUnits: 80, incline: 2, measuredSpeedUnits: 80, measuredIncline: 2)
        for _ in 0..<4 {
            detector.observe(measuredSpeedUnits: 80, measuredIncline: 4, deltaSeconds: 1)
        }
        XCTAssertFalse(detector.speed.isSetByHand, "nobody touched the speed dial")
        XCTAssertTrue(detector.incline.isSetByHand)
    }

    func testTheVerdictIsLatchedTheInstantTheDepartureIsDecisive() {
        // **Finding 134.** The belt is holding the command it was given; the person
        // turns the dial two km/h down, which the belt covers in about four seconds
        // at half a km/h a second. The verdict is reached on the frame the departure
        // becomes decisive — half a km/h in — and not four seconds later at the far
        // end of the journey, plus two more of settling. Those six seconds sat
        // inside a ten-second evaluation grid, so an evaluation landed mid-travel,
        // saw no person, and wrote a step from the mid-travel measurement.
        var axis = ConsoleDialAxis.forSpeed
        axis.commanded(units: 80, measured: 80)
        for tenths in [79, 78, 77, 76] {
            axis.observe(measured: tenths, deltaSeconds: 1)
            XCTAssertFalse(axis.isSetByHand, "\(tenths) is inside a confusion, not a dial")
        }
        axis.observe(measured: 75, deltaSeconds: 1)
        XCTAssertTrue(axis.isSetByHand, "half a km/h down is a person, on the frame it shows")
        // The belt is still travelling toward the person's 6.0 at this point, which
        // is the whole of the finding: the app now knows before it gets there.
        axis.observe(measured: 70, deltaSeconds: 1)
        XCTAssertTrue(axis.isSetByHand)
    }

    func testACommandTheBeltIsStillTravellingTowardStillWaitsForAPlateau() {
        // The other half of finding 134's fix, and the reason it is not simply "latch
        // on any decisive frame". A machine slower than the rate the app models is
        // decisively short of a command it is genuinely still travelling toward, and
        // a value in motion is the journey rather than a hand: classifying it early
        // would silently disable governing for a whole segment on an honest belt.
        // So that case keeps its plateau, and the residue stays where the type's own
        // note puts it — a machine that moved and then *stopped* short reads as a
        // person.
        var axis = ConsoleDialAxis.forSpeed
        axis.commanded(units: 160, measured: 80) // 8.0 → 16.0, a 19 s allowance
        var measured = 80
        for _ in 0..<30 {
            measured += 2 // 0.2 km/h a second: less than half the modelled rate
            axis.observe(measured: measured, deltaSeconds: 1)
            XCTAssertFalse(axis.isSetByHand, "a belt still climbing is not a hand: \(measured)")
        }
        XCTAssertFalse(axis.isTravelling, "and it is long past its own travel allowance")
        // And once it stops climbing, short of the command, it is the documented
        // residue again.
        for _ in 0..<3 { axis.observe(measured: measured, deltaSeconds: 1) }
        XCTAssertTrue(axis.isSetByHand, "a plateau decisively short of the command")
    }

    // MARK: - The evidence is a change, not a discrepancy (findings 91, 128)

    func testACommandTheBeltNeverObeysIsNotAPerson() {
        // The write the queue abandoned after three attempts: the app asked for
        // 9.0, nothing arrived, and the belt goes on holding 8.0. There is a
        // discrepancy and there is no change, and only a change is evidence.
        let axis = dialAxis(.forSpeed, command: 80, measuredAtCommand: 80,
                            then: Array(repeating: 80, count: 10))
        var dropped = axis
        dropped.commanded(units: 90, measured: 80)
        for _ in 0..<60 { dropped.observe(measured: 80, deltaSeconds: 1) }
        XCTAssertFalse(dropped.isSetByHand,
                       "a command nothing obeyed is not somebody's hand on a dial")
    }

    func testATenthOfNoiseCannotTurnAnAbandonedWriteIntoAPerson() {
        // **Finding 128.** The movement clause used to accept any change at all, so
        // one tenth of measurement noise on a belt that never set off supplied the
        // evidence and the large standing discrepancy did the rest. The clause is
        // measured with the same decisive threshold now, so noise supplies nothing.
        var dropped = dialAxis(.forSpeed, command: 80, measuredAtCommand: 80,
                               then: Array(repeating: 80, count: 10))
        dropped.commanded(units: 120, measured: 80)
        for _ in 0..<40 { dropped.observe(measured: 81, deltaSeconds: 1) }
        XCTAssertFalse(dropped.isSetByHand, "a tenth of noise is not a journey")
        for _ in 0..<40 { dropped.observe(measured: 80, deltaSeconds: 1) }
        XCTAssertFalse(dropped.isSetByHand)
    }

    func testAnActuatorThatStopsShortOfACommandItWasGivenReadsAsAPerson() {
        // The residue of a criterion built on measurements, stated as a test rather
        // than left to be discovered. The belt sets off, reaches what it can do, and
        // holds there: it moved decisively, it has had the time the distance takes,
        // and it is settled decisively short of the command. That is the same
        // measurement as a person holding the belt below an outstanding command, and
        // nothing built on measurements can separate the two — so it errs toward the
        // person, whose cost is a segment that runs fixed with every brake still
        // live.
        //
        // It is also barely reachable in production: `record(command:incline:origin:)`
        // clamps every write to the device's own limits, so a command above what the
        // machine will do needs limits the device never reported.
        var axis = ConsoleDialAxis.forSpeed
        axis.commanded(units: 200, measured: 80)
        var measured = 80
        for _ in 0..<16 {
            measured = min(160, measured + 5)
            axis.observe(measured: measured, deltaSeconds: 1)
        }
        for _ in 0..<120 { axis.observe(measured: 160, deltaSeconds: 1) }
        XCTAssertTrue(axis.isSetByHand,
                      "16 km/h under a command of 20 is a plateau decisively short of it")
        // What is *not* a person is the same discrepancy with no movement behind it.
        var neverSetOff = ConsoleDialAxis.forSpeed
        neverSetOff.commanded(units: 200, measured: 160)
        for _ in 0..<120 { neverSetOff.observe(measured: 160, deltaSeconds: 1) }
        XCTAssertFalse(neverSetOff.isSetByHand, "the belt did not move at all")
    }

    func testAnInclineMotorThatStopsShortOfTheLevelReadsAsAPersonToo() {
        // The same residue on the other axis, and the same reason: a motor at the
        // top of its own travel and a hand holding the console at that level are
        // one measurement. The travel allowance is what keeps the *journey* silent —
        // see the test above it — and this is what happens after it runs out.
        var axis = ConsoleDialAxis.forIncline
        axis.commanded(units: 15, measured: 2)
        for level in 3...12 {
            for _ in 0..<5 { axis.observe(measured: level, deltaSeconds: 1) }
        }
        for _ in 0..<200 { axis.observe(measured: 12, deltaSeconds: 1) }
        XCTAssertTrue(axis.isSetByHand, "the motor stopped short of a level it was given")
    }

    func testABeltThatHoldsShortOfAnIncreaseIsNotAPerson() {
        // Two tenths short of an increase it was asked for, held for ever. Under the
        // old discrepancy rule this was a person for the rest of the segment.
        let arrived = dialAxis(.forSpeed, command: 60, measuredAtCommand: 60, then: [60, 60, 60])
        var short = arrived
        short.commanded(units: 64, measured: 60)
        for _ in 0..<120 { short.observe(measured: 62, deltaSeconds: 1) }
        XCTAssertFalse(short.isSetByHand)
    }

    func testAPlateauDecisivelyAwayFromTheCommandIsAPersonInEitherDirection() {
        // Finding 110's central blocker: the criterion is direction-agnostic about
        // *which way the belt sits*, and asks only that the belt sit against the
        // direction the app itself asked for. A user holding the belt below an
        // outstanding command is a person exactly as one holding it above is.
        let above = dialAxis(.forSpeed, command: 40, measuredAtCommand: 120,
                             then: Array(repeating: 60, count: 40))
        XCTAssertTrue(above.isSetByHand, "6.0 km/h while 4.0 was asked for")
        let below = dialAxis(.forSpeed, command: 120, measuredAtCommand: 40,
                             then: Array(repeating: 60, count: 40))
        XCTAssertTrue(below.isSetByHand, "6.0 km/h while 12.0 was asked for is a person too")
    }

    func testABeltThatWentFurtherTheWayTheAppAskedIsNotAPerson() {
        // The other half of clause 2, which the symmetric reading had to give up:
        // an overshoot in the app's own direction is the machine, not a hand. A
        // console asked to come down from 12.0 to 8.0 that settles at 7.0 has done
        // what it was told, and more.
        let overshot = dialAxis(.forSpeed, command: 80, measuredAtCommand: 120,
                                then: Array(repeating: 70, count: 40))
        XCTAssertFalse(overshot.isSetByHand, "it went the way the app asked, only further")
    }

    func testADialDownDuringAnEntryRampIsSeen() {
        // The finding's own reproduction: a recovery segment leaves the belt
        // decelerating toward 4.0 and the user dials the console to 6.0 to keep
        // jogging. The belt never arrives, and the plateau is *below* the command.
        let ramping = [115, 110, 105, 100, 95, 90, 85, 80, 75, 70, 65, 60]
        let axis = dialAxis(.forSpeed, command: 40, measuredAtCommand: 120,
                            then: ramping + Array(repeating: 60, count: 12))
        XCTAssertTrue(axis.isSetByHand)
        XCTAssertFalse(axis.isTravelling, "past its own travel allowance")
        // And the journey itself stays silent: the belt is still moving toward the
        // command, which no hand on a dial does.
        let stillRamping = dialAxis(.forSpeed, command: 40, measuredAtCommand: 120,
                                    then: ramping)
        XCTAssertFalse(stillRamping.isSetByHand)
    }

    // MARK: - A write does not erase evidence it has not reported (findings 92, 125)

    func testAGovernorWriteInsideTheSettleWindowCannotForgetADialChange() {
        // The user presses down half a km/h; one second later — inside the
        // two-second plateau window, and nine seconds before the next evaluation —
        // the governor writes its own step. That write is one step from the
        // *reference*, which is now the person's own value, so the new command lands
        // right next to the belt and nothing about it is decisive any more. The
        // evidence has to survive it — which it does twice over now: the verdict
        // itself is latched on the frame the departure becomes decisive, and a
        // departure that is still being judged survives the write as well.
        var axis = ConsoleDialAxis.forSpeed
        axis.commanded(units: 80, measured: 80)
        axis.observe(measured: 74, deltaSeconds: 1)
        // **Inverted from "not settled yet" (finding 134).** On a command the belt
        // had reached, the verdict is the departure and there is nothing left to
        // wait for: half a km/h against the direction the app asked for is a person
        // on the first frame that shows it. The two seconds this used to wait were
        // two seconds in which an evaluation could land mid-travel and turn the belt
        // around before it ever reached the value the person had dialled.
        XCTAssertTrue(axis.isSetByHand, "a decisive departure is latched at once")
        axis.commanded(units: 76, measured: 74)
        axis.observe(measured: 74, deltaSeconds: 1)
        axis.observe(measured: 74, deltaSeconds: 1)
        XCTAssertTrue(axis.isSetByHand, "the write erased evidence it had not reported")

        // **Finding 126's own reproduction**, which is the same second with the
        // write landing *exactly* on the value the user dialled to — the likeliest
        // outcome of all, because the loop steps from the belt. That exact match
        // used to be a release: the maturing departure was dropped, the press was
        // erased, and the loop adopted the person's number as its own baseline.
        var landedOnIt = ConsoleDialAxis.forSpeed
        landedOnIt.commanded(units: 80, measured: 80)
        landedOnIt.observe(measured: 74, deltaSeconds: 1)
        landedOnIt.commanded(units: 74, measured: 74)
        landedOnIt.observe(measured: 74, deltaSeconds: 1)
        landedOnIt.observe(measured: 74, deltaSeconds: 1)
        XCTAssertTrue(landedOnIt.isSetByHand,
                      "the loop naming the person's own value consumed the evidence")
    }

    func testARestatedCommandDoesNotRestartTheJourneyItIsNotMaking() {
        // **Finding 125.** The travel bookkeeping was reset by every write,
        // including one that restated the command already standing — so a rung
        // writing on the ten-second evaluation grid, with a travel allowance longer
        // than ten seconds, kept `isTravelling` true for ever and starved the only
        // clause that could catch a person on that axis. The type's own invariant
        // already said the bookkeeping resets when the command *changes*.
        var axis = ConsoleDialAxis.forIncline
        // A twelve-level command is a 63 s journey; the rung restates it on the
        // ten-second evaluation grid while the user holds the console at 6.
        axis.commanded(units: 12, measured: 0)
        for second in 1...100 {
            if second % 10 == 0 { axis.commanded(units: 12, measured: 6) }
            axis.observe(measured: 6, deltaSeconds: 1)
        }
        XCTAssertFalse(axis.isTravelling, "a restated command is not a new journey")
        XCTAssertTrue(axis.isSetByHand,
                      "and the person holding the console six levels short is seen")
    }

    func testTwoConsolePressesInARowDoNotClearEachOther() {
        // The second plateau's predecessor is the first plateau rather than the
        // command, so a verdict recomputed from scratch would come out false and
        // the loop would resume steering after the *second* press.
        let axis = dialAxis(.forSpeed, command: 80, measuredAtCommand: 80,
                            then: [70, 70, 70, 60, 60, 60, 60])
        XCTAssertTrue(axis.isSetByHand)
    }

    // MARK: - The app's own buttons are a person too (finding 90)

    func testAnInAppChangeHandsControlBackJustLikeAConsoleDialDoes() {
        // The dashboard's ± tiles are enabled during a governed segment, and they
        // used to enter through the same call as the loop's own writes — which
        // cleared the very evidence a console press latches. One tile press is a
        // person whatever its size: the write itself is the evidence, so no
        // threshold applies to it.
        var axis = ConsoleDialAxis.forSpeed
        axis.setByHand(units: 79, measured: 80)
        XCTAssertTrue(axis.isSetByHand, "the write itself is the evidence")
        // And the belt then obeying *them* is not evidence that nobody touched it.
        for _ in 0..<60 { axis.observe(measured: 79, deltaSeconds: 1) }
        XCTAssertTrue(axis.isSetByHand)
    }

    func testAnInAppChangeLatchesOnlyTheAxisThePersonMoved() {
        // Both axes, and each on its own: the ± tiles move one at a time, exactly
        // as a console press on one dial says nothing about the other.
        var onIncline = ConsoleDialDetector()
        onIncline.commanded(speedUnits: 80, incline: 2, measuredSpeedUnits: 80, measuredIncline: 2)
        onIncline.setByHand(.incline, speedUnits: 80, incline: 3,
                            measuredSpeedUnits: 80, measuredIncline: 2)
        XCTAssertTrue(onIncline.incline.isSetByHand)
        XCTAssertFalse(onIncline.speed.isSetByHand, "nobody touched the speed tile")
        XCTAssertTrue(onIncline.isSetByHand)

        var onSpeed = ConsoleDialDetector()
        onSpeed.commanded(speedUnits: 80, incline: 2, measuredSpeedUnits: 80, measuredIncline: 2)
        onSpeed.setByHand(.speed, speedUnits: 81, incline: 2,
                          measuredSpeedUnits: 80, measuredIncline: 2)
        XCTAssertTrue(onSpeed.speed.isSetByHand)
        XCTAssertFalse(onSpeed.incline.isSetByHand, "nobody touched the incline tile")
        XCTAssertTrue(onSpeed.isSetByHand)
    }

    // MARK: - A stop outlives a link outage (finding 93)

    func testAnOutageRunsTheFailureClockAndNotTheInsistencesOwn() {
        // The link drops after the ceiling fires. Nothing can be observed slowing
        // while frames are absent, so the failure clock takes the gap — and the
        // insistence's own clocks take none of it, or the first tick on the new
        // link would abandon the stop instead of re-issuing it.
        let stop = OutstandingStop(secondsSinceRequest: 4, secondsSinceAttempt: 1,
                                   speedAtRequestKmh: 10.0, lastSpeedKmh: 8.0)
        let next = FitShowTreadmillClient.outaged(stop, bySeconds: 60)
        XCTAssertEqual(next.secondsSinceRequest, 4, "the app was not asking during the outage")
        XCTAssertEqual(next.secondsNotSlowing, 60, accuracy: 0.0001)
        XCTAssertTrue(next.isFailure)
        XCTAssertEqual(next.secondsSinceAttempt, FitShowTreadmillClient.stopReissueSeconds,
                       "and the first tick on the new link asks again")
        XCTAssertEqual(FitShowTreadmillClient.insisting(next, bySeconds: 0.2,
                                                        isObservedStopped: false,
                                                        measuredSpeedKmh: 8.0).1,
                       .insist)
    }

    func testAReconnectedBeltObservedIdleRetiresTheStopThatSurvivedTheOutage() {
        let outaged = FitShowTreadmillClient.outaged(
            OutstandingStop(speedAtRequestKmh: 10.0, lastSpeedKmh: 10.0), bySeconds: 60)
        XCTAssertEqual(FitShowTreadmillClient.insisting(outaged, bySeconds: 0.2,
                                                        isObservedStopped: true,
                                                        measuredSpeedKmh: 0).1,
                       .obeyed)
    }

    func testANonsenseOutageChangesNothing() {
        let stop = OutstandingStop(speedAtRequestKmh: 10.0)
        for seconds in [0.0, -1.0, Double.nan, .infinity] {
            XCTAssertEqual(FitShowTreadmillClient.outaged(stop, bySeconds: seconds), stop,
                           "\(seconds)")
        }
    }

    func testOnlyTheSegmentBoundaryReturnsControlToTheLoop() {
        // **Inverted.** The belt being observed at the app's own command used to be
        // a release, and finding 126 is what that cost: the loop's own step lands
        // on the value the user has just dialled to — it steps from the belt, so of
        // course it does — and the release then erased the press and made the
        // person's number the loop's baseline. Governing resumes at the next
        // segment and nowhere else.
        var axis = ConsoleDialAxis.forSpeed
        axis.setByHand(units: 79, measured: 80)
        for _ in 0..<10 { axis.observe(measured: 79, deltaSeconds: 1) }
        XCTAssertTrue(axis.isSetByHand)
        axis.commanded(units: 100, measured: 79)
        for _ in 0..<10 { axis.observe(measured: 79, deltaSeconds: 1) }
        XCTAssertTrue(axis.isSetByHand, "the belt has not obeyed the loop yet")
        axis.observe(measured: 100, deltaSeconds: 1)
        XCTAssertTrue(axis.isSetByHand, "and obeying it is not a hand coming off a dial")
        axis.segmentBegan()
        XCTAssertFalse(axis.isSetByHand)
    }

    func testANewSegmentClearsTheVerdictAndKeepsTheTravelBookkeeping() {
        // Finding 114: the spec's "Governing resumes at the next segment", and now
        // the *only* thing that retires a verdict mid-workout. The travel
        // bookkeeping stays, because it is about the belt.
        var axis = ConsoleDialAxis.forSpeed
        axis.commanded(units: 80, measured: 80)
        for _ in 0..<3 { axis.observe(measured: 60, deltaSeconds: 1) }
        XCTAssertTrue(axis.isSetByHand)
        // The boundary: the runner's entry write, and the client's own notice that
        // a new segment has begun.
        axis.commanded(units: 100, measured: 60)
        axis.segmentBegan()
        XCTAssertFalse(axis.isSetByHand, "the verdict belonged to the segment that ended")
        XCTAssertTrue(axis.isTravelling, "and the belt is still on its way to the new command")
        // Nothing is re-inferred from the belt merely sitting where it was: the
        // plateau has not moved since this command, so there is no change to read.
        for _ in 0..<60 { axis.observe(measured: 60, deltaSeconds: 1) }
        XCTAssertFalse(axis.isSetByHand)
        // An in-app press is a person again, from the boundary on.
        axis.setByHand(units: 58, measured: 60)
        XCTAssertTrue(axis.isSetByHand)
    }

    func testANewSegmentDoesNotForgetAHandStillOnTheDial() {
        // The other half: a person who keeps turning the dial after the boundary is
        // a person in the new segment too, on the new segment's own evidence.
        var axis = ConsoleDialAxis.forSpeed
        axis.commanded(units: 80, measured: 80)
        axis.segmentBegan()
        for _ in 0..<4 { axis.observe(measured: 60, deltaSeconds: 1) }
        XCTAssertTrue(axis.isSetByHand)
    }

    func testAnExplicitStartWipesTheSlate() {
        // A start carries its own confirmation, so nothing about the belt that was
        // not running is remembered — a console verdict included, which is the one
        // other thing that retires one now that the release is gone.
        var axis = ConsoleDialAxis.forSpeed
        axis.setByHand(units: 79, measured: 80)
        XCTAssertTrue(axis.isSetByHand)
        axis.started(units: 60, measured: 0)
        XCTAssertFalse(axis.isSetByHand)
        XCTAssertTrue(axis.isTravelling, "and the new journey is its own")
        var fromTheConsole = ConsoleDialAxis.forSpeed
        fromTheConsole.commanded(units: 80, measured: 80)
        for _ in 0..<3 { fromTheConsole.observe(measured: 60, deltaSeconds: 1) }
        XCTAssertTrue(fromTheConsole.isSetByHand)
        fromTheConsole.started(units: 60, measured: 0)
        XCTAssertFalse(fromTheConsole.isSetByHand)
    }

    // MARK: - The stale write bound (finding 79)

    func testAFreshLinkBoundsNothing() {
        let bound = FitShowTreadmillClient.bounded(speedKmh: 7.8, incline: 4, isLinkStale: false,
                                                   measuredSpeedKmh: 5.0, measuredIncline: 1)
        XCTAssertEqual(bound.speedKmh, 7.8)
        XCTAssertEqual(bound.incline, 4)
    }

    func testAStaleLinkBoundsEveryWriteByTheLastMeasuredValue() {
        // The reproduction: the app's last write is 8.0, the user presses the
        // console down and settles at 5.0, no frame carries it, and the 92%
        // ceiling "reduces" to 7.8 — a 2.8 km/h acceleration of the belt the
        // person is standing on.
        let bound = FitShowTreadmillClient.bounded(speedKmh: 7.8, incline: 4, isLinkStale: true,
                                                   measuredSpeedKmh: 5.0, measuredIncline: 1)
        XCTAssertEqual(bound.speedKmh, 5.0)
        XCTAssertEqual(bound.incline, 1)
        // A write that is already below the last measurement is untouched: the
        // bound is a ceiling, not a setpoint.
        let lower = FitShowTreadmillClient.bounded(speedKmh: 4.0, incline: 0, isLinkStale: true,
                                                   measuredSpeedKmh: 5.0, measuredIncline: 1)
        XCTAssertEqual(lower.speedKmh, 4.0)
        XCTAssertEqual(lower.incline, 0)
    }

    // MARK: - The stop the client insists on (finding 78)

    /// `speedKmh` defaults to nil — nothing observed, which is not a belt observed
    /// obeying, so the failure clock runs. A test about the wind-down says so.
    private func insist(_ stop: OutstandingStop, seconds: Double = 1,
                        stopped: Bool = false,
                        speedKmh: Double? = nil) -> (OutstandingStop, StopInsistence) {
        FitShowTreadmillClient.insisting(stop, bySeconds: seconds, isObservedStopped: stopped,
                                         measuredSpeedKmh: speedKmh)
    }

    func testAStopIsReissuedUntilTheBeltIsObservedStopped() {
        var stop = OutstandingStop()
        // Two seconds of not stopping, then the second ask.
        for _ in 0..<2 {
            let (next, step) = insist(stop)
            stop = next
            XCTAssertNotEqual(step, .obeyed)
        }
        XCTAssertEqual(stop.attempts, 2)
        // And it keeps going: the queue's own three attempts are 600 ms, and the
        // radio gap that eats them is the one this exists for.
        for _ in 0..<8 { stop = insist(stop).0 }
        XCTAssertGreaterThanOrEqual(stop.attempts, 5)
    }

    func testAPausedConsoleIsNotAConfirmedStop() {
        // A console winding the belt down reports `paused`, and so does one the
        // user can resume from: reading either as obeyed is how a stop got lost.
        for status in [FitShow.Status.paused, .stopping, .running, .countdown] {
            XCTAssertFalse(FitShowTreadmillClient.isObservedStopped(status: status, frameAge: 0),
                           "\(status) is not stopped")
        }
        for status in [FitShow.Status.idle, .end] {
            XCTAssertTrue(FitShowTreadmillClient.isObservedStopped(status: status, frameAge: 0))
        }
    }

    func testARememberedIdleIsNotAnObservation() {
        // A state wiped by a disconnect reads as `idle`. A stop must not be
        // confirmed by a frame that never arrived.
        XCTAssertFalse(FitShowTreadmillClient.isObservedStopped(
            status: .idle,
            frameAge: FitShowTreadmillClient.freshnessHorizonSeconds + 0.2))
        XCTAssertTrue(FitShowTreadmillClient.isObservedStopped(
            status: .idle, frameAge: FitShowTreadmillClient.freshnessHorizonSeconds))
    }

    func testAnObservedStopEndsTheInsistenceAtOnce() {
        let (next, step) = insist(OutstandingStop(), stopped: true)
        XCTAssertEqual(step, .obeyed)
        XCTAssertEqual(next, OutstandingStop(), "nothing was counted against an obeyed stop")
    }

    func testTheFailureBecomesVisibleAfterFiveSecondsOnAStandingBelt() {
        // A belt that was standing when the stop went out has no wind-down to be
        // given time for, so the window is the bare five seconds.
        var stop = OutstandingStop()
        for _ in 0..<4 { stop = insist(stop).0 }
        XCTAssertLessThan(stop.secondsNotSlowing, FitShowTreadmillClient.stopFailureSeconds)
        XCTAssertFalse(stop.isFailure)
        stop = insist(stop).0
        XCTAssertGreaterThanOrEqual(stop.secondsNotSlowing,
                                    FitShowTreadmillClient.stopFailureSeconds)
        XCTAssertTrue(stop.isFailure)
    }

    // MARK: - "The belt did not stop" must mean it (finding 95)

    func testTheFailureWindowIsSizedAgainstARealWindDownFromTheRequestSpeed() {
        // A belt sheds about 0.5 km/h a second whatever it is told, so 10 km/h is
        // twenty seconds of legitimate deceleration — and the app requests a stop
        // at the end of every ordinary program.
        XCTAssertEqual(FitShowTreadmillClient.stopFailureSeconds(fromSpeedKmh: 10), 25,
                       accuracy: 0.0001)
        XCTAssertEqual(FitShowTreadmillClient.stopFailureSeconds(fromSpeedKmh: 0),
                       FitShowTreadmillClient.stopFailureSeconds, accuracy: 0.0001)
        // And the insistence is never given up on before the belt has had that
        // window, plus a few more attempts.
        XCTAssertGreaterThan(FitShowTreadmillClient.stopGiveUpSeconds(fromSpeedKmh: 10),
                             FitShowTreadmillClient.stopFailureSeconds(fromSpeedKmh: 10))
    }

    func testANormalWindDownFromTenKmhNeverRaisesTheFailure() {
        // The reproduction: every ordinary program end. The belt reports itself
        // stopping for about twenty seconds, the failure clock was five, and a red
        // safety banner after every workout is a banner nobody reads.
        var stop = OutstandingStop(speedAtRequestKmh: 10.0, lastSpeedKmh: 10.0)
        var speed = 10.0
        while speed > 0 {
            speed = max(0, ((speed - 0.5) * 10).rounded() / 10)
            stop = insist(stop, speedKmh: speed).0
            XCTAssertFalse(stop.isFailure,
                           "a belt slowing from 10 km/h is a belt obeying (at \(speed) km/h)")
        }
        XCTAssertEqual(stop.secondsNotSlowing, 0, accuracy: 0.0001,
                       "the failure clock does not run while the belt is slowing")
        // And an observed idle retires the stop entirely.
        XCTAssertEqual(insist(stop, stopped: true, speedKmh: 0).1, .obeyed)
    }

    func testABeltThatStopsSlowingAndHoldsDoesRaiseTheFailure() {
        // The other half: it is not the elapsed time that is evidence, it is the
        // belt no longer coming down. Half a wind-down, then it holds at 5 km/h.
        var stop = OutstandingStop(speedAtRequestKmh: 10.0, lastSpeedKmh: 10.0)
        var speed = 10.0
        for _ in 0..<10 {
            speed -= 0.5
            stop = insist(stop, speedKmh: speed).0
        }
        XCTAssertFalse(stop.isFailure)
        for _ in 0..<25 { stop = insist(stop, speedKmh: 5.0).0 }
        XCTAssertTrue(stop.isFailure, "a belt holding at 5 km/h is not stopping")
    }

    func testAStopGivenUpOnWhileTheBeltWasObeyingIsNotAFailure() {
        // Finding 113. The give-up branch declared "the belt did not stop"
        // unconditionally, ignoring its own obeying judgement — and because giving
        // up also drops the request, the `.obeyed` branch that is the only way to
        // lower the flag could never fire again. That is a permanent false alarm on
        // a belt that stopped perfectly well, and the runner refuses every later
        // program start while it stands.
        //
        // The scenario is ordinary: the belt winds down from 10 km/h and then holds
        // at zero while the console goes on reporting `paused` rather than idle, so
        // the stop is never *confirmed* and the insistence eventually gives up.
        var stop = OutstandingStop(speedAtRequestKmh: 10.0, lastSpeedKmh: 10.0)
        var speed = 10.0
        var step = StopInsistence.wait
        for _ in 0..<Int(FitShowTreadmillClient.stopGiveUpSeconds(fromSpeedKmh: 10.0)) + 1 {
            speed = max(0, speed - FitShowTreadmillClient.beltDecelerationKmhPerSecond)
            (stop, step) = insist(stop, speedKmh: speed)
        }
        XCTAssertEqual(step, .abandoned, "past the give-up window it stops asking")
        XCTAssertEqual(stop.secondsNotSlowing, 0, accuracy: 0.0001)
        XCTAssertFalse(stop.isFailure, "nothing about this belt failed to obey")
        // And the belt that really did refuse still raises it on the same branch.
        var refused = OutstandingStop(speedAtRequestKmh: 10.0, lastSpeedKmh: 10.0)
        for _ in 0..<Int(FitShowTreadmillClient.stopGiveUpSeconds(fromSpeedKmh: 10.0)) + 1 {
            refused = insist(refused, speedKmh: 10.0).0
        }
        XCTAssertTrue(refused.isFailure)
    }

    func testLosingTheLinkJudgesFromTheStopsOwnRememberedEvidence() {
        // Finding 129: a disconnect wipes the client's live `state` to zero before
        // `abandonStopKeepingFailure` ever runs — `didDisconnectPeripheral` does it
        // immediately, and `failPreparation` (a failed *re*connect) reads it only
        // after that wipe. `abandonRaisesFailure` used to take that live speed as a
        // parameter, so a 97% ceiling stop whose reconnect then failed read the
        // wiped zero as "the belt stopped" and raised nothing — the exact scenario
        // the insistence exists for. It now takes only the stop itself, and a stop
        // nobody has watched even once is judged from the speed it was requested
        // at, which is `lastSpeedKmh`'s own initial value.
        typealias Client = FitShowTreadmillClient
        let neverObserved = OutstandingStop(speedAtRequestKmh: 8.0, lastSpeedKmh: 8.0)
        XCTAssertTrue(Client.abandonRaisesFailure(neverObserved),
                      "the link died before anything could be observed slowing")

        // And a belt that had already tripped the failure window is a failure
        // whatever the last reading said, because that evidence is already in.
        var refused = OutstandingStop(speedAtRequestKmh: 10.0, lastSpeedKmh: 10.0)
        for _ in 0..<30 { refused = insist(refused, speedKmh: 10.0).0 }
        XCTAssertTrue(Client.abandonRaisesFailure(refused))
    }

    func testALinkLostMidWindDownIsNotAFailure() {
        // Finding 130, the mirror image of 129. The app requests a stop at the end
        // of every ordinary program, and a belt shedding about half a km/h a second
        // is nonzero for the better part of twenty seconds — so judging the abandon
        // path by "last speed nonzero" cried wolf on every normal ending. The same
        // obeying test the insistence already runs applies here: a belt observed
        // slowing is a belt obeying, whatever speed it was last seen at.
        typealias Client = FitShowTreadmillClient
        var stop = OutstandingStop(speedAtRequestKmh: 10.0, lastSpeedKmh: 10.0)
        var speed = 10.0
        for _ in 0..<5 {
            speed = max(0, speed - FitShowTreadmillClient.beltDecelerationKmhPerSecond)
            (stop, _) = insist(stop, speedKmh: speed)
        }
        XCTAssertGreaterThan(stop.lastSpeedKmh, 0, "the belt has not fully stopped yet")
        XCTAssertFalse(stop.isFailure, "well within the wind-down window")
        XCTAssertFalse(Client.abandonRaisesFailure(stop),
                       "observed slowing on every tick — losing the link now is not a refusal")

        // A belt that held instead of slowing is a different story, even before the
        // failure window itself has run out: the link is gone, so nothing will ever
        // observe this belt actually stop.
        var stuck = OutstandingStop(speedAtRequestKmh: 10.0, lastSpeedKmh: 10.0)
        (stuck, _) = insist(stuck, speedKmh: 10.0)
        XCTAssertFalse(stuck.isFailure, "the window has not elapsed yet")
        XCTAssertTrue(Client.abandonRaisesFailure(stuck),
                      "held flat instead of slowing, and now nothing ever will see it stop")
    }

    func testTheStopFailureCanBeRetiredOnceTheRequestIsGone() {
        // The other half of finding 113: a way back. With the request cleared the
        // insistence never runs again, so the flag needs its own retirement — on
        // evidence, and on the same evidence the insistence itself retires on.
        typealias Client = FitShowTreadmillClient
        XCTAssertTrue(Client.retiresStopFailure(isFailureStanding: true,
                                                isRequestOutstanding: false,
                                                isObservedStopped: true))
        XCTAssertFalse(Client.retiresStopFailure(isFailureStanding: true,
                                                 isRequestOutstanding: false,
                                                 isObservedStopped: false),
                       "a belt nobody has seen stop is still a belt somebody has to walk to")
        XCTAssertFalse(Client.retiresStopFailure(isFailureStanding: true,
                                                 isRequestOutstanding: true,
                                                 isObservedStopped: true),
                       "while the request stands the insistence owns the flag")
        XCTAssertFalse(Client.retiresStopFailure(isFailureStanding: false,
                                                 isRequestOutstanding: false,
                                                 isObservedStopped: true))
        // The evidence is an observation and never a remembered state: idle or
        // ended, from a frame that actually arrived.
        XCTAssertTrue(Client.isObservedStopped(status: .idle, frameAge: 0))
        XCTAssertFalse(Client.isObservedStopped(status: .idle, frameAge: 600),
                       "a remembered idle is not an observation")
        XCTAssertFalse(Client.isObservedStopped(status: .paused, frameAge: 0))
    }

    func testAStaleFrameIsNotABeltObservedObeying() {
        // A remembered zero and "nothing observed" are very different things: a
        // state wiped by a disconnect reads as a standing belt, and reading that as
        // obedience would hide the failure the outage caused.
        var stop = OutstandingStop(speedAtRequestKmh: 10.0, lastSpeedKmh: 10.0)
        for _ in 0..<30 { stop = insist(stop, speedKmh: nil).0 }
        XCTAssertTrue(stop.isFailure)
    }

    // MARK: - `wasObservedSlowing` is a monotonic latch (finding 140)

    func testARepeatedReadingDoesNotUnlatchObservedSlowing() {
        // The poll runs five times a second while the console reports a new
        // speed far less often, so most ticks re-observe the very reading
        // already on file. A strict "did it just decrease" comparison read
        // that as "not obeying" on nearly every one of those ticks — and a
        // disconnect landing on one of them raised a false belt-did-not-stop
        // that blocked every later program start.
        var stop = OutstandingStop(speedAtRequestKmh: 10.0, lastSpeedKmh: 10.0)
        // The one tick a new frame actually arrived on: a genuine decrease.
        stop = insist(stop, speedKmh: 9.5).0
        XCTAssertFalse(FitShowTreadmillClient.abandonRaisesFailure(stop),
                       "just observed decreasing")
        // Several polls before the console's next frame: the same reading,
        // over and over, is not new evidence of anything.
        for _ in 0..<10 { stop = insist(stop, speedKmh: 9.5).0 }
        XCTAssertFalse(FitShowTreadmillClient.abandonRaisesFailure(stop),
                       "a repeated reading is not a belt that stopped slowing — " +
                       "losing the link now must not raise a false alarm")
    }

    func testAGenuineIncreaseDoesUnlatchObservedSlowing() {
        // The latch still has to move the other way on real evidence: a belt
        // that speeds back up has not kept obeying, whatever it did before.
        var stop = OutstandingStop(speedAtRequestKmh: 10.0, lastSpeedKmh: 10.0)
        stop = insist(stop, speedKmh: 9.0).0
        XCTAssertFalse(FitShowTreadmillClient.abandonRaisesFailure(stop))
        stop = insist(stop, speedKmh: 9.5).0
        XCTAssertTrue(FitShowTreadmillClient.abandonRaisesFailure(stop),
                      "the belt sped back up — losing the link now is not evidence it kept slowing")
    }

    // MARK: - The stop aid is not a command anybody chose (finding 96)

    func testTheStopAidTakesOneKmhOffTheLowerOfTheTwoFacts() {
        let limits = TreadmillLimits()
        let aid = FitShowTreadmillClient.stopAidTarget(commandedSpeedKmh: 10.0,
                                                       commandedIncline: 4,
                                                       observedSpeedKmh: 7.0, measuredIncline: 2,
                                                       limits: limits)
        XCTAssertEqual(aid.speedKmh, 6.0, accuracy: 0.0001)
        XCTAssertEqual(aid.incline, 2, "the incline is restated at the lower of the two, never raised")
    }

    func testTheStopAidNeverGoesBelowTheMachinesMinimum() {
        let limits = TreadmillLimits()
        let aid = FitShowTreadmillClient.stopAidTarget(commandedSpeedKmh: 1.2,
                                                       commandedIncline: 0,
                                                       observedSpeedKmh: 1.0, measuredIncline: 0,
                                                       limits: limits)
        XCTAssertEqual(aid.speedKmh, limits.minSpeedKmh, accuracy: 0.0001)
    }

    /// The inversion of `testTheStopAidIgnoresAMeasuredZeroRatherThanBoundingToIt`,
    /// which pinned the unsafe behaviour (finding 143). Falling back to the app's
    /// own command whenever no measurement was in hand was the one place in the
    /// client where an observation failed to lower fact 1 — and because this
    /// function *originates* a target rather than bounding somebody else's
    /// request, the fallback turned "fails to reduce" into "commands an
    /// increase": a disconnect wipes `state` to zero while keeping the stop, so
    /// the aid asked for 9.0 at a belt coasting through 4. The old
    /// justification — that a measured 0 is not a target the machine can be set
    /// to — was already covered by the machine-minimum floor below, which is
    /// where bounding to a zero lands.
    func testTheStopAidBoundsToAMeasuredZeroAndLandsOnTheMachineMinimum() {
        let limits = TreadmillLimits()
        let aid = FitShowTreadmillClient.stopAidTarget(commandedSpeedKmh: 8.0,
                                                       commandedIncline: 3,
                                                       observedSpeedKmh: 0, measuredIncline: 3,
                                                       limits: limits)
        XCTAssertEqual(aid.speedKmh, limits.minSpeedKmh, accuracy: 0.0001,
                       "a measured 0 is bounded to, not ignored")
    }

    func testTheStopAidCanNeverAskForMoreThanTheLowerOfTheTwoFactsAtAnySpeed() {
        // The whole of the rule, swept over the range the device offers: the only
        // thing that may ever raise the result above `min(fact 1, fact 2)` is the
        // machine's own minimum, which is what keeps it a settable value.
        let limits = TreadmillLimits()
        for commandedRaw in stride(from: 0, through: limits.maxSpeedRaw, by: 4) {
            for observedRaw in stride(from: 0, through: limits.maxSpeedRaw, by: 4) {
                let commanded = Double(commandedRaw) / 10
                let observed = Double(observedRaw) / 10
                let aid = FitShowTreadmillClient.stopAidTarget(
                    commandedSpeedKmh: commanded, commandedIncline: 6,
                    observedSpeedKmh: observed, measuredIncline: 3, limits: limits)
                XCTAssertLessThanOrEqual(
                    aid.speedKmh,
                    max(limits.minSpeedKmh, min(commanded, observed)) + 0.0001,
                    "commanded \(commanded), observed \(observed)")
                XCTAssertEqual(aid.incline, 3, "commanded \(commanded), observed \(observed)")
            }
        }
    }

    func testAStaleFrameLeavesTheStopAidTheLastSpeedThatActuallyArrived() {
        // The insist path's own choice of observation. A fresh frame is the belt
        // itself; without one the stop's remembered `lastSpeedKmh` stands — the
        // same evidence `abandonRaisesFailure` is judged from, and never fact 1.
        let stop = OutstandingStop(speedAtRequestKmh: 10.0, lastSpeedKmh: 4.0)
        XCTAssertEqual(FitShowTreadmillClient.stopAidObservedSpeedKmh(
            stop, frameAge: 0.2, measuredSpeedKmh: 3.6), 3.6, accuracy: 0.0001)
        XCTAssertEqual(FitShowTreadmillClient.stopAidObservedSpeedKmh(
            stop, frameAge: 30, measuredSpeedKmh: 0), 4.0, accuracy: 0.0001,
                       "a state wiped by a disconnect is not an observation")
    }

    func testAReconnectedInsistenceBrakesFromTheBeltAndNeverFromTheAppsMemory() {
        // Finding 143 end to end: `didDisconnectPeripheral` wipes `state` to zero
        // and keeps the stop, the auto-reconnect goes straight to
        // `central.connect(peripheral)` so `forgetTargets()` never runs, and
        // `lastFrameAt` is left stale for as long as the three limit queries sit
        // ahead of the first status poll. The first insistence after that gap used
        // to compute from the surviving `commandedSpeedKmh` of 10.0 and write 9.0
        // at a belt coasting through 4 — a brake accelerating the belt, restated
        // every two seconds.
        let stop = OutstandingStop(speedAtRequestKmh: 10.0, lastSpeedKmh: 4.0)
        let limits = TreadmillLimits()
        let observed = FitShowTreadmillClient.stopAidObservedSpeedKmh(
            stop, frameAge: 12, measuredSpeedKmh: 0)
        let aid = FitShowTreadmillClient.stopAidTarget(commandedSpeedKmh: 10.0,
                                                       commandedIncline: 4,
                                                       observedSpeedKmh: observed,
                                                       measuredIncline: 0, limits: limits)
        XCTAssertLessThanOrEqual(aid.speedKmh, 4.0,
                                 "never more than the last thing anybody saw")
        XCTAssertEqual(aid.speedKmh, 3.0, accuracy: 0.0001, "one step down from it")
    }

    // MARK: - Nothing may write an increase while a stop is outstanding (finding 94)

    func testWithNoStopOutstandingNothingIsBounded() {
        let bound = FitShowTreadmillClient.boundedByStop(
            speedKmh: 12.0, incline: 6, isStopOutstanding: false,
            appSpeedKmh: 8.0, appIncline: 2, measuredSpeedKmh: 7.0, measuredIncline: 2)
        XCTAssertEqual(bound.speedKmh, 12.0)
        XCTAssertEqual(bound.incline, 6)
    }

    func testAnOutstandingStopRefusesEveryIncreaseAndLetsReductionsThrough() {
        // The dashboard's stop button asks the client to stop; it does not end the
        // program. A running program keeps writing segment targets, the heart rate
        // falls as the belt winds down, and a below-band reading is an
        // acceleration of the belt the user just pressed STOP on.
        let up = FitShowTreadmillClient.boundedByStop(
            speedKmh: 12.0, incline: 6, isStopOutstanding: true,
            appSpeedKmh: 8.0, appIncline: 2, measuredSpeedKmh: 7.0, measuredIncline: 2)
        XCTAssertEqual(up.speedKmh, 7.0, "never above what is already happening")
        XCTAssertEqual(up.incline, 2)
        let down = FitShowTreadmillClient.boundedByStop(
            speedKmh: 3.0, incline: 0, isStopOutstanding: true,
            appSpeedKmh: 8.0, appIncline: 2, measuredSpeedKmh: 7.0, measuredIncline: 2)
        XCTAssertEqual(down.speedKmh, 3.0, "a reduction is exactly what a stop wants")
        XCTAssertEqual(down.incline, 0)
    }

    func testAStoppedBeltDoesNotBoundEveryWriteToZero() {
        // A measured 0 is a belt that has stopped, not a target: the app's own
        // command is the bound then, and it is coming down anyway.
        let bound = FitShowTreadmillClient.boundedByStop(
            speedKmh: 12.0, incline: 3, isStopOutstanding: true,
            appSpeedKmh: 6.0, appIncline: 1, measuredSpeedKmh: 0, measuredIncline: 1)
        XCTAssertEqual(bound.speedKmh, 6.0)
        XCTAssertEqual(bound.incline, 1)
    }

    func testAStopNobodyAnswersIsEventuallyAbandonedRatherThanShoutedForever() {
        // An outstanding stop that never expired would also kill a start the user
        // makes at the console minutes later. The failure stays on screen; the
        // shouting stops.
        var stop = OutstandingStop()
        var steps: [StopInsistence] = []
        for _ in 0..<40 {
            let (next, step) = insist(stop)
            stop = next
            steps.append(step)
        }
        XCTAssertEqual(steps.last, .abandoned)
        XCTAssertTrue(steps.contains(.insist))
    }

    // MARK: - Giving up without observation is a failure in its own right (finding 141)

    func testAConsoleThatPlateausShortOfZeroIsAFailureBeforeItIsAbandoned() {
        // A console that honours a target *change* while ignoring the stop
        // itself is walked down by the stop aid to the machine's own minimum
        // and held there — never truly zero, never observed idle. The old
        // give-up window was sized as though the failure clock started
        // ticking from the first attempt; in fact it cannot start until the
        // belt stops actually falling, and at the top of the device's range
        // the descent alone can eat most of that budget, so the insistence
        // used to give up before the window ever completed — a silent give-up
        // on a belt that never stopped.
        let requestSpeedKmh = 16.0 // TreadmillLimits().maxSpeedKmh
        let plateauKmh = 0.8       // TreadmillLimits().minSpeedKmh
        var stop = OutstandingStop(speedAtRequestKmh: requestSpeedKmh, lastSpeedKmh: requestSpeedKmh)
        var speed = requestSpeedKmh
        var step = StopInsistence.wait
        let ticks = Int(FitShowTreadmillClient.stopGiveUpSeconds(fromSpeedKmh: requestSpeedKmh)) + 1
        for _ in 0..<ticks {
            speed = max(plateauKmh, speed - FitShowTreadmillClient.beltDecelerationKmhPerSecond)
            (stop, step) = insist(stop, speedKmh: speed)
        }
        XCTAssertEqual(step, .abandoned, "past the give-up window it stops asking")
        XCTAssertTrue(stop.isFailure,
                      "the belt was never observed stopped — giving up must not be silent")
    }

    func testAWedgedPollCannotFastForwardTheStopClock() {
        // A tick is not a second: one poll may credit at most one freshness
        // horizon, or a wedged timer would abandon the stop on its first beat.
        let (next, _) = insist(OutstandingStop(), seconds: 600)
        XCTAssertEqual(next.secondsSinceRequest,
                       FitShowTreadmillClient.freshnessHorizonSeconds)
    }

    func testANonsenseDeltaWaitsInsteadOfCounting() {
        for delta in [0.0, -1.0, Double.nan, .infinity] {
            let (next, step) = insist(OutstandingStop(), seconds: delta)
            XCTAssertEqual(step, .wait, "\(delta)")
            XCTAssertEqual(next, OutstandingStop())
        }
    }

    /// Finding 72's bound: unclamped, 60 + 11 × 16 = 236 — above
    /// `HeartRateTarget.bandRangeBpm`'s own "above any plausible maximum"
    /// ceiling — at the device's own top speed.
    func testDemoHeartRatePlantNeverExceedsThePlausibleCeilingEvenAtTopSpeed() {
        var bpm = 60.0
        for _ in 0..<3600 {
            bpm = FitShowTreadmillClient.demoHeartRateStep(
                current: bpm, speedKmh: TreadmillLimits().maxSpeedKmh)
        }
        XCTAssertLessThanOrEqual(bpm, Double(HeartRateTarget.bandRangeBpm.upperBound))
    }
}
