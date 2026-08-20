import XCTest
@testable import TreadPilot

/// A keretek elvárt bájtsorai a kutatás három egybehangzó forrásából származnak:
/// FitShow gyártói doksi v1.1, qdomyos-zwift fitshowtreadmill.cpp, tyge68/fitshow-treadmill.
final class FitShowProtocolTests: XCTestCase {

    private func hex(_ string: String) -> Data {
        Data(string.split(separator: " ").map { UInt8($0, radix: 16)! })
    }

    // MARK: - Kódolás

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
        XCTAssertEqual(FitShowFrame.encode(FitShowCommands.pause), hex("02 53 06 55 03"))
    }

    func testSetTarget8kmh2Percent() {
        let payload = FitShowCommands.setTarget(speedKmh: 8.0, inclinePercent: 2,
                                                limits: TreadmillLimits())
        // Az FCS itt pont 0x03 — ezért tilos a 0x03 bájtra keretezni.
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
        let limits = TreadmillLimits() // T40 alapértelmezés: max 16,0 km/h, dőlés 0–12
        let tooFast = FitShowCommands.setTarget(speedKmh: 99, inclinePercent: 50, limits: limits)
        XCTAssertEqual(tooFast[2], 160)
        XCTAssertEqual(tooFast[3], 12)
        let tooSlow = FitShowCommands.setTarget(speedKmh: 0, inclinePercent: -5, limits: limits)
        XCTAssertEqual(tooSlow[2], 8)
        XCTAssertEqual(tooSlow[3], 0)
    }

    // MARK: - Dekódolás

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
        // Példakeret a kutatásból: 8,0 km/h, 2%, 60 mp, 2,0 km, 50 kcal, 10 000 lépés, 120 bpm.
        let payload = try XCTUnwrap(FitShowFrame.decode(
            hex("02 51 03 50 02 3C 00 14 00 32 00 10 27 78 00 55 03")))
        guard case .runData(let data) = FitShowParser.parse(payload) else {
            return XCTFail("runData eseményt vártunk")
        }
        XCTAssertEqual(data.status, .running)
        XCTAssertEqual(data.speedKmh, 8.0, accuracy: 0.001)
        XCTAssertEqual(data.inclinePercent, 2)
        XCTAssertEqual(data.elapsedSeconds, 60)
        XCTAssertEqual(data.distanceKm, 2.0, accuracy: 0.001)
        XCTAssertEqual(data.kcal, 50)
        XCTAssertEqual(data.steps, 10000)
        XCTAssertEqual(data.heartRate, 120)
    }

    func testParseCountdown() throws {
        // Visszaszámlálás: státusz 0x02, a következő bájt a hátralévő másodperc.
        let payload = try XCTUnwrap(FitShowFrame.decode(hex("02 51 02 05 56 03")))
        XCTAssertEqual(FitShowParser.parse(payload), .countdown(seconds: 5))
    }

    func testParseNegativeIncline() throws {
        // Dőlés int8-ként értelmezendő: 0xFF = -1%.
        var frame: [UInt8] = [0x51, 0x03, 0x50, 0xFF, 0x3C, 0x00, 0x14, 0x00,
                              0x32, 0x00, 0x10, 0x27, 0x78, 0x00]
        let payload = try XCTUnwrap(FitShowFrame.decode(FitShowFrame.encode(frame)))
        guard case .runData(let data) = FitShowParser.parse(payload) else {
            return XCTFail("runData eseményt vártunk")
        }
        XCTAssertEqual(data.inclinePercent, -1)

        frame[3] = 0x0C
        let positive = try XCTUnwrap(FitShowFrame.decode(FitShowFrame.encode(frame)))
        guard case .runData(let positiveData) = FitShowParser.parse(positive) else {
            return XCTFail("runData eseményt vártunk")
        }
        XCTAssertEqual(positiveData.inclinePercent, 12)
    }

    func testDecodeFrameWhoseChecksumIs0x03() {
        // Az FCS itt maga is 0x03 — a dekódernek ezt is hibátlanul kell bontania,
        // bizonyítva, hogy nem a 0x03 bájtot keresi keretzáróként.
        XCTAssertEqual(FitShowFrame.decode(hex("02 53 02 50 02 03 03")),
                       [0x53, 0x02, 0x50, 0x02])
    }

    func testParseSignedInclineLimits() throws {
        // Dőléslimit-válasz: max +12%, min -3% (0xFD int8-ként), pause támogatott (bit1).
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
        // A saját 02 51 51 03 pollunk visszhangja nem jelentheti azt, hogy a
        // szalag áll — különben egy visszhangzó konzol hamisan állóra váltana.
        let payload = try XCTUnwrap(FitShowFrame.decode(hex("02 51 51 03")))
        XCTAssertNotEqual(FitShowParser.parse(payload), .idle)
    }

    func testParseSpeedLimits() throws {
        // SYS_INFO sebesség-válasz: max 160 (16,0 km/h), min 8 (0,8 km/h).
        let payload = try XCTUnwrap(FitShowFrame.decode(
            FitShowFrame.encode([0x50, 0x02, 160, 8, 0])))
        XCTAssertEqual(FitShowParser.parse(payload), .speedLimits(maxRaw: 160, minRaw: 8))
    }

    func testParseInclineUnsupportedOnShortReply() throws {
        let payload = try XCTUnwrap(FitShowFrame.decode(FitShowFrame.encode([0x50, 0x03])))
        XCTAssertEqual(FitShowParser.parse(payload), .inclineUnsupported)
    }

    // MARK: - AnyRun-variáns (a T40 valódi padon megfigyelt viselkedése, task #171)

    func testAnyRunTimeIsMinuteSecondPair() throws {
        // Idő 2:15 AnyRun-konzolon: payload[4]=2 (perc), payload[5]=15 (mp).
        let frame: [UInt8] = [0x51, 0x03, 0x50, 0x02, 0x02, 0x0F, 0x00, 0x02,
                              0x00, 0x06, 0x00, 0x64, 0x4E, 0x00]
        let payload = try XCTUnwrap(FitShowFrame.decode(FitShowFrame.encode(frame)))
        guard case .runData(let data) = FitShowParser.parse(payload, variant: .anyRun) else {
            return XCTFail("runData eseményt vártunk")
        }
        XCTAssertEqual(data.elapsedSeconds, 135)
        XCTAssertEqual(data.distanceKm, 0.2, accuracy: 0.001)
        XCTAssertEqual(data.kcal, 6)
        XCTAssertEqual(data.steps, 100)
        XCTAssertEqual(data.heartRate, 78)
    }

    func testUserReportedKcalByteSwap() throws {
        // A valódi padon látott hiba: 6 kcal big-endianben (00 06) érkezik —
        // standard (little-endian) értelmezéssel 1536 lett belőle.
        let frame: [UInt8] = [0x51, 0x03, 0x1E, 0x00, 0x00, 0x0A, 0x00, 0x00,
                              0x00, 0x06, 0x00, 0x00, 0x00, 0x00]
        let payload = try XCTUnwrap(FitShowFrame.decode(FitShowFrame.encode(frame)))
        guard case .runData(let wrong) = FitShowParser.parse(payload, variant: .standard),
              case .runData(let right) = FitShowParser.parse(payload, variant: .anyRun) else {
            return XCTFail("runData eseményt vártunk")
        }
        XCTAssertEqual(wrong.kcal, 1536)
        XCTAssertEqual(right.kcal, 6)
        XCTAssertEqual(right.elapsedSeconds, 10)
    }

    func testVariantDetectorRecognizesStandard() {
        // Standardnál a 4. bájt (u16le alsó bájt) lép másodpercenként.
        var detector = FitShowVariantDetector()
        detector.observeRunningFrame([0x51, 0x03, 0x1E, 0x00, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        detector.observeRunningFrame([0x51, 0x03, 0x1E, 0x00, 11, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(detector.detected, .standard)
    }

    func testVariantDetectorRecognizesAnyRun() {
        // AnyRunnál az 5. bájt (másodperc) lép, a 4. (perc) áll.
        var detector = FitShowVariantDetector()
        detector.observeRunningFrame([0x51, 0x03, 0x1E, 0x00, 0, 9, 0, 0, 0, 0, 0, 0, 0, 0])
        detector.observeRunningFrame([0x51, 0x03, 0x1E, 0x00, 0, 10, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(detector.detected, .anyRun)
    }

    func testVariantDetectorSkipsMinuteWrap() {
        // Perchatárnál mindkét bájt változik — abból nem szabad dönteni.
        var detector = FitShowVariantDetector()
        detector.observeRunningFrame([0x51, 0x03, 0x1E, 0x00, 0, 59, 0, 0, 0, 0, 0, 0, 0, 0])
        detector.observeRunningFrame([0x51, 0x03, 0x1E, 0x00, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertNil(detector.detected)
        detector.observeRunningFrame([0x51, 0x03, 0x1E, 0x00, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(detector.detected, .anyRun)
    }

    func testParseExtendedLimits() throws {
        // SYS_INFO 0x05 válasz: max 160 (16,0 km/h), min 8, dőlés 0–12.
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
