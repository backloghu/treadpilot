// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import SwiftData
import XCTest
@testable import TreadPilot

/// `TCXExporter` — the file the user uploads to Strava by hand (#206), and the
/// document #170 will POST. The format is the contract here: Strava reads the
/// trackpoints, so a comma for a decimal point, a time in the phone's own zone,
/// or a stray `Position` element each mean a workout that imports wrong or not
/// at all.
final class TCXExporterTests: XCTestCase {

    private let tcxNamespace = "http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2"
    private let extensionNamespace = "http://www.garmin.com/xmlschemas/ActivityExtension/v2"

    override func setUp() {
        super.setUp()
        removeExportedFiles()
    }

    override func tearDown() {
        removeExportedFiles()
        super.tearDown()
    }

    // MARK: - The document a reader sees

    func testTheDocumentParsesWithTheTcxNamespacesAndCarriesNoPosition() throws {
        let session = try makeSession(seconds: (1...5).map { Second(heartRate: 130 + $0) })
        let xml = TCXExporter.document(for: session)
        let parsed = parse(xml)

        // The skeleton, in schema order.
        XCTAssertEqual(parsed.elements.prefix(6).map(\.name),
                       ["TrainingCenterDatabase", "Activities", "Activity",
                        "Id", "Lap", "TotalTimeSeconds"])
        XCTAssertEqual(parsed.attributes["Activity"]?.first?["Sport"], "Running")
        XCTAssertEqual(parsed.texts["Intensity"], ["Active"])
        XCTAssertEqual(parsed.texts["TriggerMethod"], ["Manual"])
        XCTAssertEqual(parsed.elements.filter { $0.name == "Trackpoint" }.count, 5)

        // Everything but the speed extension belongs to the TCX namespace...
        for element in parsed.elements where !["TPX", "Speed"].contains(element.name) {
            XCTAssertEqual(element.namespace, tcxNamespace, element.name)
        }
        // ...and the speed to the ActivityExtension one, which is where a reader
        // looks for a per-sample speed: TCX v2 has no Trackpoint element for it.
        for name in ["TPX", "Speed"] {
            XCTAssertEqual(parsed.elements.first { $0.name == name }?.namespace,
                           extensionNamespace, name)
        }

        // No Position anywhere. That absence is the whole reason this is a TCX
        // and not a GPX: it is what makes Strava render an indoor activity with
        // no map instead of rejecting a treadmill run for having no coordinates.
        XCTAssertFalse(parsed.elements.contains { $0.name == "Position" })
        XCTAssertFalse(xml.contains("Position"))
        XCTAssertFalse(xml.contains("LatitudeDegrees"))
    }

    func testTimesAreUtcAndFollowTheSamplesOwnWallClockAcrossAPause() throws {
        // Three seconds of running, a minute paused, two more seconds. The
        // moving offsets of the last two are 4 and 5; their wall clocks are 64
        // and 65, and the wall clock is what a reader must be told.
        let session = try makeSession(seconds: [
            Second(wallClock: .secondsPastStart(1)),
            Second(wallClock: .secondsPastStart(2)),
            Second(wallClock: .secondsPastStart(3)),
            Second(wallClock: .secondsPastStart(64)),
            Second(wallClock: .secondsPastStart(65)),
        ], pausedSeconds: 60)
        let parsed = parse(TCXExporter.document(for: session))

        XCTAssertEqual(parsed.texts["Id"], ["2026-08-22T06:30:00Z"])
        XCTAssertEqual(parsed.attributes["Lap"]?.first?["StartTime"], "2026-08-22T06:30:00Z")
        XCTAssertEqual(parsed.texts["Time"], [
            "2026-08-22T06:30:01Z", "2026-08-22T06:30:02Z", "2026-08-22T06:30:03Z",
            "2026-08-22T06:31:04Z", "2026-08-22T06:31:05Z",
        ])
    }

    func testASecondMigratedWithoutATimestampLandsAtItsMovingOffset() throws {
        // A row recorded before `WorkoutSampleRecord.timestamp` existed still
        // carries the `.distantPast` sentinel; the Health export reads the
        // moving offset for those, and this one has to agree with it or the two
        // exports of one workout would describe different clocks.
        let session = try makeSession(seconds: (1...3).map { _ in
            Second(wallClock: .migratedSentinel)
        })
        let parsed = parse(TCXExporter.document(for: session))
        XCTAssertEqual(parsed.texts["Time"], [
            "2026-08-22T06:30:01Z", "2026-08-22T06:30:02Z", "2026-08-22T06:30:03Z",
        ])
    }

    func testTheLapReportsMovingTimeNotTheElapsedSpan() throws {
        // 120 moving seconds either side of a five-minute pause: 420 seconds
        // elapsed. TCX's TotalTimeSeconds is the timer, and the track holds one
        // point per *moving* second — so 120 is the figure the track can
        // corroborate, and the elapsed span stays readable from the timestamps.
        let session = try makeSession(seconds: (1...120).map {
            Second(wallClock: .secondsPastStart($0 <= 60 ? $0 : $0 + 300))
        }, pausedSeconds: 300)
        let parsed = parse(TCXExporter.document(for: session))

        XCTAssertEqual(session.totalSeconds, 420)
        XCTAssertEqual(parsed.texts["TotalTimeSeconds"], ["120.0"])
        XCTAssertEqual(parsed.elements.filter { $0.name == "Trackpoint" }.count, 120)
        XCTAssertEqual(parsed.texts["Time"]?.first, "2026-08-22T06:30:01Z")
        XCTAssertEqual(parsed.texts["Time"]?.last, "2026-08-22T06:37:00Z")
    }

    // MARK: - The series

    func testDistanceIsCumulativeInMetresAndEndsAtTheSessionsOwnTotal() throws {
        let session = try makeSession(seconds: Array(repeating: Second(speedKmh: 12), count: 60))
        let parsed = parse(TCXExporter.document(for: session))

        // The lap's own summary is the first DistanceMeters; the track's sixty
        // follow it.
        let distances = (parsed.texts["DistanceMeters"] ?? []).compactMap { Double($0) }
        XCTAssertEqual(distances.count, 61)
        XCTAssertEqual(distances.first!, session.distanceKm * 1000, accuracy: 0.01)

        let track = Array(distances.dropFirst())
        XCTAssertEqual(zip(track, track.dropFirst()).filter { $0 >= $1 }.count, 0,
                       "cumulative distance must ascend")
        XCTAssertEqual(track.last!, session.distanceKm * 1000, accuracy: 0.01)
        // 12 km/h for a minute is 200 m, and the summary agrees with the track.
        XCTAssertEqual(track.last!, 200, accuracy: 0.01)
    }

    func testHeartRateIsAbsentWhenNothingWasMeasuredAndPresentWhenItWas() throws {
        // A handlebar-free workout with no Watch: not one bpm anywhere, rather
        // than zeros the schema has no room for (`Value` starts at 1).
        let silent = try makeSession(seconds: Array(repeating: Second(), count: 3))
        let silentXml = TCXExporter.document(for: silent)
        XCTAssertFalse(silentXml.contains("HeartRateBpm"))
        _ = parse(silentXml)

        // The first second had no reading, the next two did.
        let measured = try makeSession(seconds: [
            Second(heartRate: 0), Second(heartRate: 141), Second(heartRate: 152),
        ])
        let xml = TCXExporter.document(for: measured)
        let parsed = parse(xml)
        XCTAssertEqual(occurrences(of: "<HeartRateBpm>", in: xml), 2)
        // The lap's average and maximum, then the two seconds that measured one.
        XCTAssertEqual(parsed.texts["Value"], ["147", "152", "141", "152"])
    }

    func testSpeedIsConvertedFromKilometresPerHourToMetresPerSecond() throws {
        let session = try makeSession(seconds: [
            Second(speedKmh: 9.0), Second(speedKmh: 14.4), Second(speedKmh: 0),
        ])
        let parsed = parse(TCXExporter.document(for: session))
        XCTAssertEqual(parsed.texts["Speed"], ["2.500", "4.000", "0.000"])
    }

    func testTheAppsOwnCalorieFigureWinsOverTheTreadmillsRawEstimate() throws {
        // The Health export's precedence, and for the same reason: the belt's
        // number knows nothing about the user's body.
        let session = try makeSession(seconds: [Second()])
        session.padKcal = 210
        session.computedKcal = 342.6
        XCTAssertEqual(parse(TCXExporter.document(for: session)).texts["Calories"], ["343"])

        // With no calculation of its own, the belt's estimate stands.
        session.computedKcal = 0
        XCTAssertEqual(parse(TCXExporter.document(for: session)).texts["Calories"], ["210"])
    }

    // MARK: - Distance synthesis (#206: the Strava pace sawtooth)

    func testAConstantSpeedStaircaseSynthesizesASmoothlyAscendingTrack() throws {
        // The real FitShow reports distance in 0.1 km steps
        // (`FitShowProtocol.swift`: `raw / 10`), so a constant 6 km/h run
        // (1.667 m/s) reports the same cumulative distance for 60 seconds at
        // a time before jumping straight to the next tenth. Copying that
        // into Strava's DistanceMeters is the sawtooth this fix removes.
        let speedKmh = 6.0
        let seconds = (1...180).map { second -> Second in
            let trueKm = Double(second) * speedKmh / 3600
            let quantizedKm = (trueKm * 10).rounded(.down) / 10
            return Second(speedKmh: speedKmh, distanceKmOverride: quantizedKm)
        }
        let session = try makeSession(seconds: seconds)
        // The pad's own recorded total, on the same 0.1 km grid as every
        // sample fed into it above.
        session.distanceKm = 0.3

        let parsed = parse(TCXExporter.document(for: session))
        let distances = (parsed.texts["DistanceMeters"] ?? []).compactMap { Double($0) }
        let track = Array(distances.dropFirst())
        XCTAssertEqual(track.count, 180)

        // The staircase input plateaus for tens of seconds at a time; the
        // synthesized output must not — every second moved, so every second
        // advances.
        let deltas = zip(track, track.dropFirst()).map { $1 - $0 }
        XCTAssertTrue(deltas.allSatisfy { $0 > 0 }, "expected every step to advance: \(deltas)")

        // Constant speed integrates to a straight line, so post-rescale the
        // deltas should all but agree with each other.
        let averageDelta = deltas.reduce(0, +) / Double(deltas.count)
        for delta in deltas {
            XCTAssertEqual(delta, averageDelta, accuracy: 0.05, "expected an even step: \(deltas)")
        }

        XCTAssertEqual(track.last!, session.distanceKm * 1000, accuracy: 0.01)
    }

    func testATwoPhaseSpeedChangeKeepsItsRatioAfterRescaling() throws {
        // 4 km/h then double to 8 km/h: the rescale is one constant
        // multiplier over the whole series, so the ratio between the two
        // phases' own per-second distance must survive it untouched.
        let slow = Array(repeating: Second(speedKmh: 4.0), count: 60)
        let fast = Array(repeating: Second(speedKmh: 8.0), count: 60)
        let session = try makeSession(seconds: slow + fast)

        let parsed = parse(TCXExporter.document(for: session))
        let distances = (parsed.texts["DistanceMeters"] ?? []).compactMap { Double($0) }
        let track = Array(distances.dropFirst())
        XCTAssertEqual(track.count, 120)

        let deltas = zip(track, track.dropFirst()).map { $1 - $0 }
        // Comfortably inside each phase, clear of the one transitional step.
        let phase1 = deltas[5..<55]
        let phase2 = deltas[65..<115]
        let phase1Average = phase1.reduce(0, +) / Double(phase1.count)
        let phase2Average = phase2.reduce(0, +) / Double(phase2.count)

        XCTAssertEqual(phase2Average / phase1Average, 2.0, accuracy: 0.05)
    }

    func testAllZeroSpeedFallsBackToTheRecordedStaircase() throws {
        // No usable speed to integrate — a recording gap, or a belt that
        // reported distance but not speed — so there is nothing to
        // synthesize from, and the pad's own per-sample series goes out
        // exactly as it did before this fix.
        let recordedKm: [Double] = [0.1, 0.1, 0.1, 0.2, 0.2, 0.3]
        let seconds = recordedKm.map { Second(speedKmh: 0, distanceKmOverride: $0) }
        let session = try makeSession(seconds: seconds)
        session.distanceKm = recordedKm.last!

        let parsed = parse(TCXExporter.document(for: session))
        let distances = (parsed.texts["DistanceMeters"] ?? []).compactMap { Double($0) }
        let track = Array(distances.dropFirst())

        XCTAssertEqual(track.count, recordedKm.count)
        for (actual, expectedKm) in zip(track, recordedKm) {
            XCTAssertEqual(actual, expectedKm * 1000, accuracy: 0.01)
        }
    }

    func testTheLastTrackpointDistanceMatchesTheLapDistanceExactly() throws {
        // Strava — and a rider comparing the two numbers by eye — should see
        // one consistent total, not a rescaled approximation that reads a
        // few millimetres off the lap summary.
        let session = try makeSession(seconds: Array(repeating: Second(speedKmh: 5.0), count: 45))
        // A value the rescale's own division would not land on by chance, to
        // prove the match is deliberate rather than coincidental.
        session.distanceKm = 0.061847

        let parsed = parse(TCXExporter.document(for: session))
        let allDistances = parsed.texts["DistanceMeters"] ?? []
        XCTAssertEqual(allDistances.count, 46)
        XCTAssertEqual(allDistances.last, allDistances.first,
                       "the last trackpoint must render identical to the Lap total")
    }

    // MARK: - Locale and escaping

    func testDecimalsUseAPointWhateverTheDeviceLocaleIs() throws {
        let session = try makeSession(seconds: Array(repeating: Second(speedKmh: 9.0), count: 10))
        let xml = TCXExporter.document(for: session)

        // These three are the values a Hungarian device would ruin.
        XCTAssertTrue(xml.contains("<TotalTimeSeconds>10.0</TotalTimeSeconds>"), xml)
        XCTAssertTrue(xml.contains("<DistanceMeters>25.00</DistanceMeters>"), xml)
        XCTAssertTrue(xml.contains("<ns3:Speed>2.500</ns3:Speed>"), xml)
        // Nothing else in the document uses one either, so a comma anywhere is
        // a localized number that escaped.
        XCTAssertFalse(xml.contains(","))

        // Proof that those values discriminate: on a hu_HU device the localized
        // forms carry a comma, so a `NumberFormatter` here would have failed.
        let hungarian = NumberFormatter()
        hungarian.locale = Locale(identifier: "hu_HU")
        hungarian.numberStyle = .decimal
        hungarian.minimumFractionDigits = 1
        hungarian.maximumFractionDigits = 1
        XCTAssertEqual(hungarian.string(from: NSNumber(value: 2.5)), "2,5")
        XCTAssertEqual(hungarian.string(from: NSNumber(value: 10.0)), "10,0")
    }

    func testAnAmpersandInTheDeviceNameIsEscapedRatherThanBreakingTheDocument() throws {
        // The device name arrives over BLE and the program name is typed by the
        // user: neither is trustworthy XML.
        let session = try makeSession(seconds: [Second()],
                                      deviceName: "FitShow & <Belt> \"1\"",
                                      programName: "5 & 10 <km>")
        let xml = TCXExporter.document(for: session)
        XCTAssertTrue(xml.contains("<Name>FitShow &amp; &lt;Belt&gt; &quot;1&quot;</Name>"), xml)
        XCTAssertTrue(xml.contains("<Notes>5 &amp; 10 &lt;km&gt;</Notes>"), xml)

        // And it survives the round trip: a reader gets the name back intact.
        let parsed = parse(xml)
        XCTAssertEqual(parsed.texts["Name"], ["FitShow & <Belt> \"1\""])
        XCTAssertEqual(parsed.texts["Notes"], ["5 & 10 <km>"])
    }

    // MARK: - Edge cases

    func testAWorkoutWithNoRecordedSecondsStillProducesASummaryOnlyDocument() throws {
        let session = try makeSession(seconds: [])
        let xml = TCXExporter.document(for: session)
        let parsed = parse(xml)

        // No empty `<Track/>` claiming a track that recorded nothing.
        XCTAssertFalse(xml.contains("Track"))
        XCTAssertEqual(parsed.texts["TotalTimeSeconds"], ["0.0"])
        XCTAssertEqual(parsed.texts["DistanceMeters"], ["0.00"])
        XCTAssertEqual(parsed.texts["Calories"], ["0"])
        XCTAssertEqual(parsed.texts["Intensity"], ["Active"])
    }

    func testAWorkoutWithNoRecordedEndFallsBackToItsOwnBookkeeping() throws {
        let session = try makeSession(seconds: (1...3).map { _ in Second() }, endRecorded: false)
        XCTAssertNil(session.endedAt)
        let parsed = parse(TCXExporter.document(for: session))
        // Every recorded second still travels: the fallback end reaches as far
        // as the record's own seconds do.
        XCTAssertEqual(parsed.texts["Time"]?.count, 3)
        XCTAssertEqual(parsed.texts["Time"]?.last, "2026-08-22T06:30:03Z")
    }

    func testAManualWorkoutOnANamelessBeltCarriesNeitherNotesNorCreator() throws {
        let session = try makeSession(seconds: [Second()], deviceName: "   ", programName: "  ")
        let xml = TCXExporter.document(for: session)
        XCTAssertFalse(xml.contains("<Notes>"))
        XCTAssertFalse(xml.contains("<Creator"))
        _ = parse(xml)
    }

    // MARK: - The file

    func testTheWrittenFileIsNamedAfterTheWorkoutsStartAndLandsInTheTemporaryDirectory() throws {
        let session = try makeSession(seconds: (1...3).map { _ in Second(heartRate: 140) })
        let url = try TCXExporter.writeFile(for: session)

        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL,
                       FileManager.default.temporaryDirectory.standardizedFileURL)
        XCTAssertNotNil(url.lastPathComponent.range(
            of: #"^TreadPilot_\d{4}-\d{2}-\d{2}_\d{4}\.tcx$"#, options: .regularExpression),
                        url.lastPathComponent)
        XCTAssertEqual(url.lastPathComponent, expectedFileName(for: session.startedAt))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8),
                       TCXExporter.document(for: session))

        // Re-exporting the same workout replaces its file instead of leaving a
        // second copy behind.
        let again = try TCXExporter.writeFile(for: session)
        XCTAssertEqual(again, url)
        XCTAssertEqual(exportedFileNames(), [url.lastPathComponent])

        // A different start is a different file: the name is derived, not fixed.
        let later = try makeSession(startedAt: Self.utc(2026, 8, 22, 7, 45), seconds: [Second()])
        XCTAssertNotEqual(try TCXExporter.writeFile(for: later).lastPathComponent,
                          url.lastPathComponent)
    }

    func testWritingADemoWorkoutThrowsInsteadOfProducingAFile() throws {
        // A simulated workout never happened; it may not leave the app as a file
        // the user could upload as a real run. Same rule as the Health export.
        let session = try makeSession(seconds: (1...3).map { _ in Second() })
        session.isDemo = true

        XCTAssertThrowsError(try TCXExporter.writeFile(for: session)) { error in
            guard let error = error as? TCXExportError, case .demoSession = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(exportedFileNames(), [])
        // The document itself is not the gate — only the file is — so a demo
        // workout can still be previewed in the app.
        XCTAssertFalse(TCXExporter.document(for: session).isEmpty)
    }

    // MARK: - Fixtures

    /// One recorded second, the way `SessionRecorder` leaves it.
    private struct Second {
        var speedKmh: Double = 9.0
        var heartRate: Int = 0
        var wallClock: WallClock = .movingOffset
        /// Overrides the smooth cumulative distance `makeSession` would
        /// otherwise compute for this second. The staircase fixtures use
        /// this to reproduce the FitShow's own 0.1 km-quantized odometer
        /// instead of the continuous integral every other fixture gets.
        var distanceKmOverride: Double? = nil
    }

    /// Where a sample's wall clock sits. `.movingOffset` is the pause-free case
    /// where the two agree; `.migratedSentinel` is the `.distantPast` a row
    /// written before the field existed still carries.
    private enum WallClock {
        case movingOffset
        case secondsPastStart(Int)
        case migratedSentinel
    }

    private static func utc(_ year: Int, _ month: Int, _ day: Int,
                            _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: components)!
    }

    /// A fixed instant, so every expected timestamp in this file is literal.
    private static let start = TCXExporterTests.utc(2026, 8, 22, 6, 30)

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: WorkoutSessionRecord.self, WorkoutSampleRecord.self,
            configurations: configuration)
        return ModelContext(container)
    }

    /// A recorded workout: one sample per moving second, distance accumulated
    /// the way the recorder accumulates it, and the summary fields derived from
    /// the same seconds so the document's lap and track cannot disagree by
    /// accident.
    private func makeSession(startedAt: Date = TCXExporterTests.start,
                             seconds: [Second],
                             deviceName: String = "FitShow Belt",
                             programName: String? = nil,
                             pausedSeconds: Int = 0,
                             endRecorded: Bool = true) throws -> WorkoutSessionRecord {
        let context = try makeContext()
        let session = WorkoutSessionRecord(startedAt: startedAt, deviceName: deviceName,
                                          programName: programName)
        context.insert(session)
        session.movingSeconds = seconds.count
        session.pausedSeconds = pausedSeconds

        var cumulativeKm = 0.0
        var lastRecordedDistanceKm = 0.0
        for (index, second) in seconds.enumerated() {
            cumulativeKm += second.speedKmh / 3600
            // A staircase fixture overrides this per second; every other
            // fixture keeps the smooth running integral.
            let recordedDistanceKm = second.distanceKmOverride ?? cumulativeKm
            let sample = WorkoutSampleRecord(offsetSeconds: index + 1,
                                             speedKmh: second.speedKmh,
                                             inclinePercent: 0,
                                             heartRate: second.heartRate,
                                             distanceKm: recordedDistanceKm)
            switch second.wallClock {
            case .movingOffset:
                sample.timestamp = startedAt.addingTimeInterval(TimeInterval(index + 1))
            case .secondsPastStart(let offset):
                sample.timestamp = startedAt.addingTimeInterval(TimeInterval(offset))
            case .migratedSentinel:
                sample.timestamp = .distantPast
            }
            context.insert(sample)
            sample.session = session
            lastRecordedDistanceKm = recordedDistanceKm
        }

        session.distanceKm = lastRecordedDistanceKm
        let speeds = seconds.map(\.speedKmh)
        session.avgSpeedKmh = speeds.isEmpty ? 0 : speeds.reduce(0, +) / Double(speeds.count)
        session.maxSpeedKmh = speeds.max() ?? 0
        let rates = seconds.map(\.heartRate).filter { $0 > 0 }
        session.avgHeartRate = rates.isEmpty
            ? 0
            : Int((Double(rates.reduce(0, +)) / Double(rates.count)).rounded())
        session.maxHeartRate = rates.max() ?? 0
        if endRecorded {
            session.endedAt = startedAt.addingTimeInterval(TimeInterval(session.totalSeconds))
        }
        try context.save()
        return session
    }

    // MARK: - Parsing

    /// Namespace-aware on purpose: the check that matters is that a reader
    /// resolves the elements, not that the text looks right.
    private func parse(_ xml: String) -> ParsedDocument {
        let parsed = ParsedDocument()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldProcessNamespaces = true
        parser.delegate = parsed
        XCTAssertTrue(parser.parse(),
                      "the document did not parse: \(parsed.failure?.localizedDescription ?? "?")")
        XCTAssertNil(parsed.failure)
        return parsed
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    // MARK: - Temporary files

    private func expectedFileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        return "TreadPilot_\(formatter.string(from: date)).tcx"
    }

    private func exportedFileNames() -> [String] {
        let temporary = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
        return names.filter { $0.hasPrefix("TreadPilot_") && $0.hasSuffix(".tcx") }.sorted()
    }

    private func removeExportedFiles() {
        let temporary = FileManager.default.temporaryDirectory
        for name in exportedFileNames() {
            try? FileManager.default.removeItem(at: temporary.appendingPathComponent(name))
        }
    }
}

/// What a reader gets out of the document: element names with the namespace they
/// resolved to, their text, and their attributes. At file scope rather than
/// nested in the test case, because an `XMLParserDelegate` is an Objective-C
/// protocol conformance.
private final class ParsedDocument: NSObject, XMLParserDelegate {
    var elements: [(name: String, namespace: String?)] = []
    var texts: [String: [String]] = [:]
    var attributes: [String: [[String: String]]] = [:]
    var failure: Error?
    private var buffer = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        elements.append((elementName, namespaceURI))
        attributes[elementName, default: []].append(attributeDict)
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { texts[elementName, default: []].append(text) }
        buffer = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        failure = parseError
    }
}
