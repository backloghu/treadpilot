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
}
