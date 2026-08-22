// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import XCTest
@testable import TreadPilot

/// The diagnostic log: its file format, its file management, and one governed
/// run driven through a **real `ProgramRunner`** to prove the call sites are
/// actually wired.
///
/// No live `CBCentralManager` anywhere, like every other suite here: the runner
/// is driven over `TreadmillControlling` with a stub belt that answers from the
/// client's own pure rules (finding 80), and the log is pointed at a temporary
/// directory so a test run cannot touch the device's real Application Support.
@MainActor
final class DiagnosticLogTests: XCTestCase {

    typealias Governor = HeartRateGovernor
    typealias Command = HeartRateGovernor.Command

    private var directory: URL!
    private var defaultsSuite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticLogTests-\(UUID().uuidString)", isDirectory: true)
        // The toggle is persisted, so the suite gets its own domain: a test must
        // not decide whether the next one — or the developer's own phone — is
        // logging.
        defaultsSuite = "DiagnosticLogTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: defaultsSuite)
        super.tearDown()
    }

    private func makeLog(enabled: Bool) -> DiagnosticLog {
        let log = DiagnosticLog(directory: directory, defaults: defaults)
        log.isEnabled = enabled
        return log
    }

    private func lines() throws -> [[String: Any]] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let jsonl = files.filter { $0.hasSuffix(".jsonl") }.sorted()
        XCTAssertEqual(jsonl.count, 1, "expected exactly one workout file, found \(files)")
        guard let name = jsonl.first else { return [] }
        let text = try String(contentsOf: directory.appendingPathComponent(name),
                              encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
            guard let dictionary = object as? [String: Any] else {
                throw NSError(domain: "DiagnosticLogTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey:
                                          "a line that is not a JSON object: \(line)"])
            }
            return dictionary
        }
    }

    // MARK: - The file format

    func testEveryLineIsOneValidJsonObjectWithTheHeaderFirst() throws {
        let line = DiagnosticLog.line(.governorEvaluated,
                                      fields: [.int("heartRateBpm", 148),
                                               .speed("referenceSpeedKmh", 8.2),
                                               .flag("didForceDown", false),
                                               .text("decision", "adjust"),
                                               .int("appCommandIncline", nil)],
                                      at: "2026-08-22T18:00:00.000Z",
                                      workoutSeconds: 12.34, sequence: 7)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(object["seq"] as? Int, 7)
        XCTAssertEqual(object["at"] as? String, "2026-08-22T18:00:00.000Z")
        XCTAssertEqual(object["t"] as? Double, 12.3)
        XCTAssertEqual(object["event"] as? String, "governorEvaluated")
        XCTAssertEqual(object["heartRateBpm"] as? Int, 148)
        XCTAssertEqual(object["decision"] as? String, "adjust")
        XCTAssertEqual(object["didForceDown"] as? Bool, false)
        // A fact that does not exist yet is `null` and not a missing key: a
        // reader must be able to tell "no measurement" from "this build did not
        // record it".
        XCTAssertTrue(object["appCommandIncline"] is NSNull)
        // The header comes first, so a file can be read with the eye as well as
        // with a parser.
        XCTAssertTrue(line.hasPrefix("{\"seq\":7,\"at\":"), line)
    }

    func testASpeedIsWrittenOnTheProtocolsOwnGrid() throws {
        // 8.2 km/h is the integer 82 on the wire, and printing a Double's own
        // decimal expansion (8.199999999999999) invites a reader to believe a
        // precision the protocol does not carry.
        let line = DiagnosticLog.line(.clientWrite,
                                      fields: DiagnosticLog.writeFields(
                                        origin: .governor,
                                        requested: Command(speedKmh: 82 / 10.0, incline: 3),
                                        clamped: Command(speedKmh: 8.0, incline: 3),
                                        previous: nil),
                                      at: "x", workoutSeconds: 1, sequence: 1)
        XCTAssertTrue(line.contains("\"requestedSpeedKmh\":8.2"), line)
        XCTAssertTrue(line.contains("\"clampedSpeedKmh\":8.0"), line)
        // Requested against accepted, and the flag that says they differ.
        XCTAssertTrue(line.contains("\"wasClamped\":true"), line)
        XCTAssertTrue(line.contains("\"origin\":\"governor\""), line)
    }

    func testTextIsEscapedSoAProgramNameCannotBreakALine() throws {
        let nasty = "Zone \"3\"\\ \n\ttab\u{1}"
        let line = DiagnosticLog.line(.workoutBegan, fields: [.text("program", nasty)],
                                      at: "x", workoutSeconds: 0, sequence: 1)
        XCTAssertFalse(line.dropFirst().contains("\n"), "a line must stay one line")
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(object["program"] as? String, nasty)
    }

    func testAccentedTextSurvivesVerbatim() throws {
        // The catalog is full of Hungarian and of en dashes; they are valid UTF-8
        // inside a JSON string and must not be escaped into unreadability.
        let name = "Sáv – szalag ő"
        let line = DiagnosticLog.line(.segmentStarted, fields: [.text("name", name)],
                                      at: "x", workoutSeconds: 0, sequence: 1)
        XCTAssertTrue(line.contains(name), line)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(object["name"] as? String, name)
    }

    func testAFieldMayNotShadowTheHeader() throws {
        let line = DiagnosticLog.line(.stop,
                                      fields: [.text("event", "nonsense"),
                                               .int("seq", 99),
                                               .text("phase", "requested")],
                                      at: "x", workoutSeconds: 0, sequence: 1)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(object["event"] as? String, "stop")
        XCTAssertEqual(object["seq"] as? Int, 1)
        XCTAssertEqual(object["phase"] as? String, "requested")
    }

    func testEveryDecisionAndStatusHasAName() {
        // The names are the file's vocabulary: an unnamed case would reach an
        // analyst as whichever string happened to be listed first.
        for reason in [Governor.Reason.belowBand, .aboveBand, .insideBand, .settling,
                       .hysteresis, .ceilingForceDown, .atBound, .targetUnreachable,
                       .outOfBounds, .bandNotSteerable] {
            XCTAssertFalse(DiagnosticLog.name(of: reason).isEmpty)
        }
        XCTAssertEqual(DiagnosticLog.name(of: .frozen as Governor.Decision), "frozen")
        XCTAssertEqual(DiagnosticLog.reasonName(of: .hold(reason: .settling)), "settling")
        XCTAssertNil(DiagnosticLog.reasonName(of: .frozen))
        XCTAssertEqual(DiagnosticLog.name(of: ProgramRunner.GovernorStatus.linkStale),
                       "linkStale")
        XCTAssertEqual(ProgramRunner.origin(of: .adjust(command: Command(speedKmh: 6,
                                                                        incline: 0),
                                                        reason: .ceilingForceDown)),
                       .brake)
        XCTAssertEqual(ProgramRunner.origin(of: .fallback(command: Command(speedKmh: 6,
                                                                          incline: 0))),
                       .fallback)
        XCTAssertEqual(ProgramRunner.origin(of: .adjust(command: Command(speedKmh: 6,
                                                                        incline: 0),
                                                        reason: .belowBand)),
                       .governor)
    }

    // MARK: - Rotation

    func testRotationKeepsTheNewestByName() {
        let names = (1...13).map { String(format: "workout-2026-08-2%d_100000.jsonl", $0 % 10) }
            + ["not-ours.txt", "workout-broken"]
        let doomed = DiagnosticLog.rotated(names, keeping: 10)
        XCTAssertEqual(doomed.count, 13 - 10)
        XCTAssertFalse(doomed.contains("not-ours.txt"),
                       "rotation may only delete files this log wrote")
        XCTAssertFalse(doomed.contains("workout-broken"))
        // The newest survive; the oldest go.
        let kept = Set(names.filter { $0.hasPrefix("workout-") && $0.hasSuffix(".jsonl") })
            .subtracting(doomed)
        XCTAssertTrue(kept.allSatisfy { name in doomed.allSatisfy { name > $0 } })
    }

    func testRotationKeepsNothingBelowTheLimit() {
        XCTAssertTrue(DiagnosticLog.rotated(["workout-a.jsonl"], keeping: 10).isEmpty)
    }

    func testTheDirectoryNeverHoldsMoreThanTheKeptCount() async throws {
        let log = makeLog(enabled: true)
        // One more workout than the log keeps, each with a line in it.
        for index in 0...DiagnosticLog.keptFileCount {
            log.beginWorkout([.int("index", index)])
            log.endWorkout([.text("reason", "programComplete")])
            await log.flush()
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".jsonl") }
        XCTAssertEqual(files.count, DiagnosticLog.keptFileCount)
    }

    // MARK: - Off means silent

    func testWithTheToggleOffNothingIsWrittenAtAll() async throws {
        let log = makeLog(enabled: false)
        log.beginWorkout([.text("program", "Zone 3")])
        log.record(.governorEvaluated, [.int("heartRateBpm", 150)])
        log.noteHeartRateFeed(bpm: 0, deltaSeconds: 1)
        log.noteLinkStaleness(isStale: true, secondsSinceFrame: 4)
        log.endWorkout([.text("reason", "tornDown")])
        await log.flush()

        XCTAssertFalse(log.isWorkoutOpen)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path),
                       "the log's own directory must not exist until something is logged")
    }

    func testEventsBeforeAWorkoutAreDropped() async throws {
        let log = makeLog(enabled: true)
        log.record(.clientWrite, [.speed("requestedSpeedKmh", 6)])
        await log.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path),
                       "the unit of analysis is a workout; a line with no frame has nothing to be checked against")
    }

    func testTransitionsAreLoggedOnTheEdgesOnly() async throws {
        let log = makeLog(enabled: true)
        log.beginWorkout([.text("program", "Zone 3")])
        // Fresh, fresh, gone, gone, gone, back: two lines, not six.
        log.noteHeartRateFeed(bpm: 140, deltaSeconds: 1)
        log.noteHeartRateFeed(bpm: 141, deltaSeconds: 1)
        log.noteHeartRateFeed(bpm: 0, deltaSeconds: 1)
        log.noteHeartRateFeed(bpm: 0, deltaSeconds: 1)
        log.noteHeartRateFeed(bpm: 0, deltaSeconds: 1)
        log.noteHeartRateFeed(bpm: 142, deltaSeconds: 1)
        await log.flush()

        let feed = try lines().filter { $0["event"] as? String == "watchFeed" }
        XCTAssertEqual(feed.map { $0["phase"] as? String }, ["gapStarted", "gapEnded"])
        // The gap's length is the measured seconds it lasted, not a tick count.
        XCTAssertEqual(feed.last?["gapSeconds"] as? Double, 3.0)
    }

    // MARK: - One workout, two possible narrators (finding 206)

    func testTheWorkoutIsLiveFromBeginUntilItsFirstEndLine() {
        let log = makeLog(enabled: true)
        XCTAssertFalse(log.isWorkoutLive)
        log.beginWorkout([.text("program", "Zone 3")])
        XCTAssertTrue(log.isWorkoutLive)
        log.endWorkout([.text("reason", "programComplete")])
        XCTAssertTrue(log.isWorkoutOpen,
                      "the file stays open for the post-end tail — a stop still winding down")
        XCTAssertFalse(log.isWorkoutLive,
                       "but the workout has ended: the next recording deserves its own frame")
        log.beginWorkout([.text("program", nil)])
        XCTAssertTrue(log.isWorkoutLive)
    }

    func testTheFirstEndLineWinsAndTheSecondNarratorSaysNothing() async throws {
        // The runner announces a program's end when its goal is reached;
        // `SessionRecorder` announces the recording's end when the belt actually
        // stands. Both see the same workout end, and a file with two "read me
        // first" lines has no answer to which one is true.
        let log = makeLog(enabled: true)
        log.beginWorkout([.text("program", "Zone 3")])
        log.endWorkout([.text("reason", "programComplete")])
        log.endWorkout([.text("reason", "beltStopped")])
        await log.flush()

        let ends = try lines().filter { $0["event"] as? String == "workoutEnded" }
        XCTAssertEqual(ends.count, 1)
        XCTAssertEqual(ends.first?["reason"] as? String, "programComplete",
                       "the goal was reached before the belt stood: the runner narrates")
    }

    func testAManualWorkoutsFrameNamesTheKindAndCarriesNoProgram() throws {
        let line = DiagnosticLog.line(
            .workoutBegan,
            fields: DiagnosticLog.manualWorkoutFields(
                isControlEnabled: true, isDemo: false,
                basis: HeartRateBasis(restingBpm: 60, maxBpm: 180),
                limits: TreadmillLimits()),
            at: "2026-08-22T18:00:00.000Z", workoutSeconds: 0, sequence: 1)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertTrue(object["program"] is NSNull,
                      "no program drives a manual workout, and the file says so")
        XCTAssertEqual(object["manual"] as? Bool, true)
        XCTAssertEqual(object["heartRateControlEnabled"] as? Bool, true)
        // The frame still carries what every later line is read against: the
        // frozen basis with its ceilings, and the device's limits.
        XCTAssertEqual(object["basisMaxBpm"] as? Int, 180)
        XCTAssertNotNil(object["forceDownCeilingBpm"] as? Int)
        XCTAssertNotNil(object["stopCeilingBpm"] as? Int)
        XCTAssertEqual(object["limitMaxSpeedKmh"] as? Double, 16.0)
    }

    // MARK: - A governed run, through the shipped runner

    func testAGovernedRunEmitsTheKeyEventKinds() async throws {
        let log = makeLog(enabled: true)
        try withRunner(heartRateControl: true) { runner, recorder in
            runner.diagnostics = log
            let belt = LoggingStubTreadmill(speedKmh: 6.0)
            // Below the band (144–155) on a 180/60 basis, so the band law has to
            // step the belt up and the log has to show why.
            let heart = LoggingStubHeartRate(bpm: 120)
            runner.bindHeartRateControl(source: heart, basis: recorder)
            runner.start(WorkoutProgram(name: "Zone 3", segments: [heartRateSegment()]),
                         on: belt)
            for _ in 0..<200 {
                belt.frame(afterSeconds: 1)
                runner.tick(bySeconds: 1)
            }
            XCTAssertGreaterThan(belt.targetWrites.count, 1,
                                 "the fixture needs the loop to have actually steered")
        }
        await log.flush()

        let all = try lines()
        let kinds = Set(all.compactMap { $0["event"] as? String })
        for expected in ["workoutBegan", "segmentStarted", "governorEvaluated", "clientWrite"] {
            XCTAssertTrue(kinds.contains(expected), "no \(expected) line: \(kinds.sorted())")
        }

        // The workout's frame: the opt-in, the frozen basis, the ceilings derived
        // from it and the device's limits, so every later line is checkable.
        let began = try XCTUnwrap(all.first { $0["event"] as? String == "workoutBegan" })
        XCTAssertEqual(began["program"] as? String, "Zone 3")
        XCTAssertEqual(began["heartRateControlEnabled"] as? Bool, true)
        XCTAssertEqual(began["isHeartRateDriven"] as? Bool, true)
        XCTAssertEqual(began["basisMaxBpm"] as? Int, 180)
        XCTAssertEqual(began["forceDownCeilingBpm"] as? Int, 166)
        XCTAssertEqual(began["stopCeilingBpm"] as? Int, 175)
        XCTAssertEqual(began["evaluationIntervalSeconds"] as? Double, 10.0)

        // The segment's arbitration, with the numbers: a band held as asked has
        // to be distinguishable from one the ceiling clamped.
        let segment = try XCTUnwrap(all.first { $0["event"] as? String == "segmentStarted" })
        XCTAssertEqual(segment["index"] as? Int, 0)
        XCTAssertEqual(segment["arbitration"] as? String, "steerable")
        XCTAssertEqual(segment["requestedBandLowBpm"] as? Int, 144)
        XCTAssertEqual(segment["heldBandHighBpm"] as? Int, 155)
        XCTAssertEqual(segment["actuator"] as? String, "speed")
        XCTAssertEqual(segment["bandIsReduced"] as? Bool, false)

        // Every evaluation, with the input that produced the decision — the
        // reference the ladder measures from included.
        let evaluations = all.filter { $0["event"] as? String == "governorEvaluated" }
        XCTAssertGreaterThan(evaluations.count, 5,
                             "an evaluation is logged every time, not only when something changed")
        let first = try XCTUnwrap(evaluations.first)
        XCTAssertEqual(first["heartRateBpm"] as? Int, 120)
        XCTAssertEqual(first["bandLowBpm"] as? Int, 144)
        XCTAssertEqual(first["bandErrorBpm"] as? Int, -24)
        XCTAssertNotNil(first["referenceSpeedKmh"] as? Double)
        XCTAssertNotNil(first["secondsSinceLastCommand"] as? Double)
        XCTAssertNotNil(first["decision"] as? String)
        XCTAssertNotNil(first["status"] as? String)
        XCTAssertEqual(first["isHandedBack"] as? Bool, false)

        // A step of the band law, distinguishable from the boundary's entry write
        // by its origin, and with requested against accepted on both.
        let writes = all.filter { $0["event"] as? String == "clientWrite" }
        XCTAssertEqual(writes.first?["origin"] as? String, "segmentEntry")
        let governed = try XCTUnwrap(writes.first { $0["origin"] as? String == "governor" })
        let requested = try XCTUnwrap(governed["requestedSpeedKmh"] as? Double)
        let clamped = try XCTUnwrap(governed["clampedSpeedKmh"] as? Double)
        XCTAssertEqual(requested, clamped, accuracy: 0.0001,
                       "this belt clamps nothing, so the pair must agree")
        XCTAssertGreaterThan(requested, 6.0, "the loop was below the band; it had to step up")
        XCTAssertEqual(governed["wasClamped"] as? Bool, false)

        // The workout's end, with the reason.
        let ended = all.filter { $0["event"] as? String == "workoutEnded" }
        XCTAssertEqual(ended.count, 1, "exactly one end per workout")
        XCTAssertEqual(ended.first?["reason"] as? String, "tornDown")

        // The relative clock is monotone and the sequence has no holes.
        XCTAssertEqual(all.compactMap { $0["seq"] as? Int }, Array(1...all.count))
        let seconds = all.compactMap { $0["t"] as? Double }
        XCTAssertEqual(seconds, seconds.sorted())
    }

    func testAClampedBandIsReportedAsClamped() async throws {
        let log = makeLog(enabled: true)
        try withRunner(heartRateControl: true) { runner, recorder in
            runner.diagnostics = log
            let belt = LoggingStubTreadmill(speedKmh: 6.0)
            let heart = LoggingStubHeartRate(bpm: 120)
            runner.bindHeartRateControl(source: heart, basis: recorder)
            // 160–172 against a force-down ceiling of 166: the upper edge is
            // above it, so the segment holds 160–165 and has to say so.
            let target = speedTarget(low: 160, high: 172)
            runner.start(WorkoutProgram(name: "Zone 4",
                                        segments: [heartRateSegment(target)]), on: belt)
            belt.frame(afterSeconds: 1)
            runner.tick(bySeconds: 1)
        }
        await log.flush()

        let segment = try XCTUnwrap(
            try lines().first { $0["event"] as? String == "segmentStarted" })
        XCTAssertEqual(segment["arbitration"] as? String, "clamped")
        XCTAssertEqual(segment["requestedBandHighBpm"] as? Int, 172)
        XCTAssertEqual(segment["heldBandHighBpm"] as? Int, 165)
        XCTAssertEqual(segment["bandIsReduced"] as? Bool, true)
    }

    func testTheCeilingStopIsRecordedWithItsTally() async throws {
        let log = makeLog(enabled: true)
        try withRunner(heartRateControl: true) { runner, recorder in
            runner.diagnostics = log
            let belt = LoggingStubTreadmill(speedKmh: 6.0)
            let heart = LoggingStubHeartRate(bpm: 176) // above the 175 stop ceiling
            runner.bindHeartRateControl(source: heart, basis: recorder)
            runner.start(WorkoutProgram(name: "HIIT", segments: [heartRateSegment()]),
                         on: belt)
            for _ in 0..<30 {
                belt.frame(afterSeconds: 1)
                runner.tick(bySeconds: 1)
            }
            XCTAssertEqual(belt.stopRequests, 1)
        }
        await log.flush()

        let all = try lines()
        let stops = all.filter { $0["event"] as? String == "stop" }
        XCTAssertEqual(stops.compactMap { $0["phase"] as? String },
                       ["ceilingReached", "requested"])
        XCTAssertEqual(stops.first?["heartRateBpm"] as? Int, 176)
        XCTAssertEqual(stops.first?["secondsAboveStopCeiling"] as? Double, 15.0)
        XCTAssertEqual(stops.last?["by"] as? String, "heartRateCeiling")
        let ended = try XCTUnwrap(all.first { $0["event"] as? String == "workoutEnded" })
        XCTAssertEqual(ended["reason"] as? String, "heartRateCeiling")
        XCTAssertEqual(ended["governorStopReason"] as? String, "heartRateCeiling")
    }

    // MARK: - Fixtures

    // Resting 60 / max 180: force-down at 166, stop at 175 — the same basis the
    // runner suites use, so a number is comparable across files.
    private let basis = HeartRateBasis(restingBpm: 60, maxBpm: 180)

    private func speedTarget(low: Int = 144, high: Int = 155) -> HeartRateTarget {
        HeartRateTarget(lowBpm: low, highBpm: high, actuator: .speed,
                        startSpeedKmh: 6.0, startIncline: 0,
                        minSpeedKmh: 4.0, maxSpeedKmh: 12.0,
                        minIncline: 0, maxIncline: 0, fallbackSpeedKmh: 4.5)
    }

    private func heartRateSegment(_ target: HeartRateTarget? = nil,
                                  seconds: Int = 600) -> WorkoutSegment {
        WorkoutSegment(name: "Zone 3", goal: .time(seconds: seconds),
                       target: .heartRate(target ?? speedTarget()))
    }

    /// Builds a runner with the opt-in set and puts the stored setting back
    /// afterwards: the opt-in lives in `UserDefaults.standard` because the
    /// runner's own setter writes it there.
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
        let recorder = SessionRecorder()
        let basis = basis
        recorder.heartRateBasisProvider = { basis }
        recorder.freezeHeartRateBasis()
        let runner = ProgramRunner()
        runner.heartRateControlEnabled = enabled
        defer { runner.stop() }
        try body(runner, recorder)
    }
}

/// The heart rate the loop may act on, as the injected source supplies it.
@MainActor
private final class LoggingStubHeartRate: GovernorHeartRateSource {
    var bpm: Int
    init(bpm: Int) { self.bpm = bpm }
    func governorHeartRateBpm() -> Int { bpm }
}

/// A treadmill the runner can be started on, behind `TreadmillControlling`.
///
/// It answers every question from the client's **own pure rules** —
/// `FitShowTreadmillClient.reconciled` for the target, `bounded`/`boundedByStop`
/// for the clamps, a real `ConsoleDialDetector` for fact 3 — which is finding
/// 80's rule: a fake that models its own rules models a client production does
/// not have. Same shape as `ProgramRunnerIntegrationTests`' own stub, which is
/// `private` to that file.
@MainActor
private final class LoggingStubTreadmill: TreadmillControlling {

    var state = TreadmillState()
    var limits = TreadmillLimits()
    var staleData = false

    private(set) var commandedSpeedKmh: Double
    private(set) var commandedIncline: Int
    private(set) var targetSpeedKmh: Double
    private(set) var targetIncline: Int
    private(set) var isStopOutstanding = false
    private(set) var stopNotObeyed = false
    /// The world's hand: production sets and clears this fact in the client,
    /// a test scripts the moments directly.
    var isPauseOutstanding = false

    private(set) var targetWrites: [HeartRateGovernor.Command] = []
    private(set) var stopRequests = 0

    private var consoleSetpoint: HeartRateGovernor.Command
    private var dial = ConsoleDialDetector()
    private var secondsSinceCommand: Double = 0

    init(speedKmh: Double, incline: Int = 0) {
        commandedSpeedKmh = speedKmh
        commandedIncline = incline
        targetSpeedKmh = speedKmh
        targetIncline = incline
        consoleSetpoint = HeartRateGovernor.Command(speedKmh: speedKmh, incline: incline)
        state.status = .running
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

    func setTarget(speedKmh: Double, incline: Int) {
        targetWrites.append(HeartRateGovernor.Command(speedKmh: speedKmh, incline: incline))
        record(speedKmh: speedKmh, incline: incline, isStart: false)
    }

    func startBelt(speedKmh: Double, incline: Int) {
        isStopOutstanding = false
        stopNotObeyed = false
        state.status = .running
        record(speedKmh: speedKmh, incline: incline, isStart: true)
    }

    func requestStop() {
        stopRequests += 1
        isStopOutstanding = true
    }

    func segmentBegan() { dial.segmentBegan() }

    /// One frame from the belt, with the belt where the console says.
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
        consoleSetpoint = HeartRateGovernor.Command(speedKmh: commandedSpeedKmh,
                                                   incline: commandedIncline)
    }
}
