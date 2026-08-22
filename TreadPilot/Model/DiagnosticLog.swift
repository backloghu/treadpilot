// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import Foundation

// MARK: - One field of one event

/// What a log field may hold. Deliberately five cases: everything the loop
/// decides from is a number, a name, a flag or an absence, and a value type this
/// small can be serialised by hand — which is what makes the number formatting
/// honest (`8.2`, not `8.199999999999999`) and the key order stable.
enum DiagnosticValue: Equatable, Sendable {
    case text(String)
    case count(Int)
    /// A measurement, with the number of decimals its unit is honest at: speeds
    /// live on the protocol's 0.1 km/h grid, so a speed printed to fifteen
    /// decimals invites a reader to believe a precision the wire does not carry.
    case number(Double, decimals: Int)
    case flag(Bool)
    /// JSON `null`: the fact does not exist yet (no frozen basis, no measured
    /// frame). Written rather than omitted, so a line's shape does not change
    /// with the state of the world.
    case absent

    var json: String {
        switch self {
        case .text(let text):
            return DiagnosticLog.quoted(text)
        case .count(let value):
            return String(value)
        case .number(let value, let decimals):
            // A non-finite number has no honest decimal form, and `nan` is not
            // JSON. It reads as the absence it is.
            guard value.isFinite else { return "null" }
            return String(format: "%.\(max(0, decimals))f", value)
        case .flag(let value):
            return value ? "true" : "false"
        case .absent:
            return "null"
        }
    }
}

/// One named value in one event. The **name carries the unit** — `speedKmh`,
/// `heartRateBpm`, `secondsSinceLastCommand`, `incline` — because the file is
/// meant to be read by somebody who does not have this source in front of them.
struct DiagnosticField: Equatable, Sendable {
    let name: String
    let value: DiagnosticValue

    static func text(_ name: String, _ value: String) -> Self {
        DiagnosticField(name: name, value: .text(value))
    }

    static func text(_ name: String, _ value: String?) -> Self {
        DiagnosticField(name: name, value: value.map { .text($0) } ?? .absent)
    }

    static func int(_ name: String, _ value: Int) -> Self {
        DiagnosticField(name: name, value: .count(value))
    }

    static func int(_ name: String, _ value: Int?) -> Self {
        DiagnosticField(name: name, value: value.map { .count($0) } ?? .absent)
    }

    static func flag(_ name: String, _ value: Bool) -> Self {
        DiagnosticField(name: name, value: .flag(value))
    }

    /// A speed, on the protocol's own grid.
    static func speed(_ name: String, _ speedKmh: Double) -> Self {
        DiagnosticField(name: name, value: .number(speedKmh, decimals: 1))
    }

    static func speed(_ name: String, _ speedKmh: Double?) -> Self {
        DiagnosticField(name: name,
                        value: speedKmh.map { .number($0, decimals: 1) } ?? .absent)
    }

    /// Measured seconds. One decimal, because every clock in this feature is
    /// measured rather than counted in timer fires and a tick is not a second.
    static func seconds(_ name: String, _ seconds: Double) -> Self {
        DiagnosticField(name: name, value: .number(seconds, decimals: 1))
    }

    static func km(_ name: String, _ km: Double) -> Self {
        DiagnosticField(name: name, value: .number(km, decimals: 3))
    }

    static func fraction(_ name: String, _ value: Double) -> Self {
        DiagnosticField(name: name, value: .number(value, decimals: 2))
    }
}

/// The event vocabulary. The raw values are what the file says, so this enum is
/// the file format's own index — a reader can grep one kind out of a workout
/// without knowing anything else about the app.
enum DiagnosticEvent: String, Sendable, CaseIterable {
    /// The workout's frame: program, opt-in, frozen basis, device limits and the
    /// governor's own constants, so every later line can be checked against the
    /// rules it was decided under.
    case workoutBegan
    case workoutEnded
    /// A segment's goal and target, and for a heart-rate segment the arbitration
    /// of its band against the ceilings derived from the frozen basis.
    case segmentStarted
    case segmentEnded
    /// One turn of the governor: the whole `HeartRateGovernor.Input`, the
    /// decision, what the runner did about it, and what the dashboard was told.
    case governorEvaluated
    /// One `setTarget`, with what was asked for, what the client accepted, and
    /// who asked.
    case clientWrite
    /// A dial turned by hand, and the hand-back it latches.
    case manualIntervention
    /// The treadmill link going stale and coming back.
    case staleness
    /// The Watch feed going quiet and coming back.
    case watchFeed
    /// The stop lifecycle: requested, insisted on, aided, obeyed, abandoned,
    /// failed.
    case stop
    /// The pause lifecycle: requested, honoured, given up on (finding 205).
    case pause
    /// The program's suspend and resume transitions, with what caused each —
    /// an app pause, a standstill, a belt no longer running, a moving belt.
    case programSuspension
    /// A recovery goal's threshold crossings and hold window.
    case recovery
}

/// Who asked for a write. Named in the file, because "the loop stepped" and "a
/// boundary wrote the next segment's entry command" are the two writes an
/// analyst has to tell apart, and the value that reaches the wire is the same
/// shape either way.
enum DiagnosticWriteOrigin: String, Sendable {
    /// The band-following law — the one path in this feature that adds load.
    case governor
    /// The 92% force-down: a reduction the band did not ask for.
    case brake
    /// The feed-loss fallback.
    case fallback
    /// A segment boundary's entry command.
    case segmentEntry
    /// The resume write after a pause.
    case resume
    /// A person, on the app's own ± tiles.
    case user
    /// An explicit start.
    case start
    /// The stop insistence's belt-and-braces reduction.
    case stopAid
}

// MARK: - The log

/// A developer-toggled, workout-scoped JSONL event log — one JSON object per
/// line, every line carrying a wall clock and the workout-relative second.
///
/// **Why it exists.** Heart-rate control is a closed loop on a moving belt whose
/// rules are stated in `docs/1.1-spec.md` section 4, and the first hardware runs
/// produce a sentence like "it accelerated strangely in segment 3". The samples
/// `WorkoutSampleRecord` already keeps answer *what the belt did*; they cannot
/// answer *why the loop did it*, because the reference the ladder measures from,
/// the counters its windows are stated in, the arbitration of the band and the
/// difference between a value requested and a value the client accepted are all
/// gone by the time a sample is written. This file records the decision together
/// with its inputs, so a run can be checked against the spec's invariants after
/// the fact.
///
/// **It observes and never steers.** No call into this type may change what the
/// belt is told: `HeartRateGovernor` stays a pure function and is not
/// instrumented at all — the call sites log, the law does not. Every number here
/// is either handed in by the caller or computed by the governor's own pure
/// helpers, so the log cannot disagree with the loop about what the loop saw.
///
/// **Off by default, and off means silent.** With `isEnabled` false nothing is
/// formatted, no directory is created and no file is opened. Nothing leaves the
/// device: files live in Application Support and are only shared if the user
/// shares them.
///
/// **A singleton, deliberately.** The three call sites are the runner, the
/// client and one settings screen; threading a new dependency through the
/// composition root would buy nothing, and `WatchHeartRateManager.shared` is the
/// same shape. Tests construct their own instance with an injected directory,
/// which is what keeps the file behaviour testable.
///
/// **The file is a workout's.** `beginWorkout` opens one and the next
/// `beginWorkout` rotates to the next; events after `workoutEnded` (a stop the
/// belt has not obeyed, a link going stale) keep appending to the workout they
/// belong to. Events arriving before any workout has begun are dropped — the
/// unit of analysis is a workout, and a file with no frame around it cannot be
/// checked against anything.
@MainActor
final class DiagnosticLog: ObservableObject {

    /// The instance production uses. See the type's own note.
    static let shared = DiagnosticLog()

    /// Off is the *absence* of the key, so the feature ships silent with no
    /// default registered anywhere — the same shape as
    /// `ProgramRunner.heartRateControlDefaultsKey`.
    nonisolated static let isEnabledDefaultsKey = "diagnosticLog.enabled"

    nonisolated static let directoryName = "DiagnosticLogs"
    nonisolated static let filePrefix = "workout-"
    nonisolated static let fileExtension = "jsonl"
    /// How many workouts are kept. Enough to cover an evening's testing; the
    /// rest are rotated away, because a diagnostic tool that fills a phone is
    /// one the user switches off.
    nonisolated static let keptFileCount = 10

    /// Buffered lines this many, or this long, before the sink is asked to
    /// write. Both bounds exist: the count keeps a busy workout's memory flat
    /// and the interval keeps a quiet one's tail from being lost to a crash.
    nonisolated static let flushLineCount = 24
    nonisolated static let flushIntervalSeconds: Double = 5

    /// The reserved names a line's header uses. A field may not shadow one, or
    /// the object would carry a duplicate key — `line(_:fields:…)` drops any
    /// that tries, and a test holds it to that.
    nonisolated static let reservedFieldNames: Set<String> = ["seq", "at", "t", "event"]

    /// The developer toggle. Switching it off flushes what is already buffered
    /// and then closes the file: the lines were collected while the user wanted
    /// them, and dropping them would lose exactly the tail that explains why
    /// they reached for the switch.
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.isEnabledDefaultsKey)
            guard !isEnabled else { return }
            // Switching on deliberately does not open a file: the workout's
            // frame — basis, limits, opt-in — is written by `beginWorkout`, and
            // a file that starts mid-workout has no frame to check against.
            Task { [weak self] in
                await self?.flush()
                self?.fileURL = nil
            }
        }
    }

    /// One log file on disk, for the share sheet.
    struct StoredLog: Identifiable, Equatable, Sendable {
        let url: URL
        let name: String
        let modifiedAt: Date
        let sizeBytes: Int

        var id: URL { url }
    }

    private let defaults: UserDefaults
    /// nil only if Application Support cannot be resolved at all, in which case
    /// the log is inert rather than crashing a workout.
    private let directory: URL?
    private let sink = Sink()

    private var fileURL: URL?
    private var lastFileName: String?
    private var sameSecondCounter = 0
    /// The workout-relative clock. Monotonic, so a wall-clock change cannot
    /// re-order a workout's own seconds — `at` carries the wall clock instead.
    private var anchor = ContinuousClock.now
    private var sequence = 0
    private var buffer: [String] = []
    /// Whether the open workout has already had its `workoutEnded` line — see
    /// `endWorkout(_:)` for who the two candidate writers are.
    private var didEndCurrentWorkout = false
    /// Batches belonging to a file that has already been closed. A file switch
    /// happens on the main actor while a flush is in flight, so the lines have
    /// to keep their destination with them.
    private var pending: [(url: URL, lines: [String])] = []
    private var lastFlushAt = ContinuousClock.now
    /// The flush chain. Each flush awaits the previous one, which is what makes
    /// the file's line order the event order — a bare `Task` per flush would let
    /// two batches reach the actor in either order.
    private var flushTask: Task<Void, Never>?

    private var timestamps = ISO8601DateFormatter()
    private var fileNames = DateFormatter()

    // Transition trackers. They live here rather than in the runner or the
    // client because "has this changed since the last line" is a question about
    // the log and about nothing else: a counter kept in the loop for the sake of
    // logging is a counter a later edit can make load-bearing.
    private var feed = FeedTracker()
    private var staleness = StalenessTracker()
    private var recovery = RecoveryTracker()
    private var dial = DialTracker()
    /// Whether the belt is the demo plant. `TreadmillControlling` does not carry
    /// it — the runner cannot see it — so the client states it here once.
    private var isDemoMode = false

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.directory = directory ?? Self.defaultDirectory()
        isEnabled = defaults.bool(forKey: Self.isEnabledDefaultsKey)
        timestamps.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fileNames.locale = Locale(identifier: "en_US_POSIX")
        fileNames.dateFormat = "yyyy-MM-dd_HHmmss"
    }

    nonisolated static func defaultDirectory() -> URL? {
        // `create: false`: resolving the log's home must not be enough to make
        // Application Support exist. Nothing on disk happens until a line is
        // actually written.
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil, create: false)
        else { return nil }
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    // MARK: - Recording

    /// One event, appended. The fields are an `@autoclosure` so that with the
    /// toggle off — the shipped default — nothing is built, nothing is
    /// formatted, and the cost at a call site inside the 200 ms poll or the 1 Hz
    /// loop is one Bool read.
    func record(_ event: DiagnosticEvent, _ fields: @autoclosure () -> [DiagnosticField]) {
        guard isEnabled, fileURL != nil else { return }
        sequence += 1
        let now = ContinuousClock.now
        let line = Self.line(event, fields: fields(),
                             at: timestamps.string(from: Date()),
                             workoutSeconds: Self.seconds(anchor.duration(to: now)),
                             sequence: sequence)
        buffer.append(line)
        guard buffer.count >= Self.flushLineCount
                || Self.seconds(lastFlushAt.duration(to: now)) >= Self.flushIntervalSeconds
        else { return }
        scheduleFlush()
    }

    /// A workout's file, opened. Rotation and the relative clock both belong to
    /// one workout, so both happen here.
    func beginWorkout(_ fields: @autoclosure () -> [DiagnosticField]) {
        guard isEnabled, let directory else { return }
        closeCurrentFile()
        let name = nextFileName(at: Date())
        fileURL = directory.appendingPathComponent(name, isDirectory: false)
        anchor = .now
        lastFlushAt = anchor
        sequence = 0
        didEndCurrentWorkout = false
        feed = FeedTracker()
        staleness = StalenessTracker()
        recovery = RecoveryTracker()
        dial = DialTracker()
        record(.workoutBegan, fields())
    }

    /// The workout, over. Flushed at once: this is the line an analyst reads
    /// first, and the app may be killed the moment the user leaves the screen.
    ///
    /// First writer wins. Two owners can see the same workout end — the runner
    /// announces a program's end at the moment its goal is reached, and
    /// `SessionRecorder` announces the recording's end when the belt actually
    /// stands — and a file with two `workoutEnded` lines has two "read me
    /// first" lines and no answer to which one is true.
    func endWorkout(_ fields: @autoclosure () -> [DiagnosticField]) {
        guard isEnabled, fileURL != nil, !didEndCurrentWorkout else { return }
        didEndCurrentWorkout = true
        record(.workoutEnded, fields())
        scheduleFlush()
    }

    /// Is a workout's file open? The runner asks before announcing an end, so a
    /// teardown of a program that was never logged says nothing.
    var isWorkoutOpen: Bool { fileURL != nil }

    /// Is a workout open *and not yet ended*? `SessionRecorder` asks before
    /// opening a manual workout's file: a program workout the runner has already
    /// framed must not be re-opened by the recording that runs alongside it —
    /// but a file whose workout has ended is only collecting a tail, and the
    /// next workout deserves its own frame.
    var isWorkoutLive: Bool { fileURL != nil && !didEndCurrentWorkout }

    func noteDemoMode(_ isDemo: Bool) { isDemoMode = isDemo }

    var demoMode: Bool { isDemoMode }

    // MARK: - Transitions

    /// The Watch feed, one tick. Emits only on the edges of a gap: the level is
    /// already in every `governorEvaluated` line, and a line per second would
    /// bury the decisions.
    func noteHeartRateFeed(bpm: Int, deltaSeconds: Double) {
        guard isEnabled, fileURL != nil else { return }
        guard let transition = feed.advanced(bpm: bpm, deltaSeconds: deltaSeconds) else { return }
        record(.watchFeed, [.text("phase", transition.phase),
                            .int("heartRateBpm", bpm),
                            .seconds("gapSeconds", transition.gapSeconds)])
    }

    /// The treadmill link going stale and coming back. `gapSeconds` is the age
    /// of the frame in hand, which is the number the client's own freshness
    /// horizon is compared against.
    func noteLinkStaleness(isStale: Bool, secondsSinceFrame: Double) {
        guard isEnabled, fileURL != nil else { return }
        guard staleness.changed(to: isStale) else { return }
        record(.staleness, [.text("phase", isStale ? "stale" : "fresh"),
                            .seconds("frameAgeSeconds", secondsSinceFrame)])
    }

    /// A recovery goal's threshold crossings, and the hold window filling.
    func noteRecovery(thresholdBpm: Int, heartRateBpm: Int,
                      holdSeconds: Double, requiredSeconds: Double) {
        guard isEnabled, fileURL != nil, thresholdBpm > 0 else { return }
        guard let phase = recovery.advanced(thresholdBpm: thresholdBpm,
                                            heartRateBpm: heartRateBpm,
                                            holdSeconds: holdSeconds,
                                            requiredSeconds: requiredSeconds) else { return }
        record(.recovery, [.text("phase", phase),
                           .int("thresholdBpm", thresholdBpm),
                           .int("heartRateBpm", heartRateBpm),
                           .seconds("holdSeconds", holdSeconds),
                           .seconds("requiredSeconds", requiredSeconds)])
    }

    /// Fact 3, as the client's `ConsoleDialDetector` reports it. The magnitude
    /// and the direction come from the two numbers the inference itself compares
    /// — the app's own command and the measured value — so a reader can see how
    /// decisive the intervention was, not merely that one was inferred.
    func noteDial(isSpeedSetByHand: Bool, isInclineSetByHand: Bool,
                  commandedSpeedKmh: Double, measuredSpeedKmh: Double,
                  commandedIncline: Int, measuredIncline: Int) {
        guard isEnabled, fileURL != nil else { return }
        if dial.latched(.speed, isSetByHand: isSpeedSetByHand) {
            record(.manualIntervention,
                   [.text("phase", "dialInferred"), .text("axis", "speed"),
                    .text("unit", "kmh"),
                    .speed("commandedSpeedKmh", commandedSpeedKmh),
                    .speed("measuredSpeedKmh", measuredSpeedKmh),
                    .speed("magnitudeKmh", abs(measuredSpeedKmh - commandedSpeedKmh)),
                    .text("direction", measuredSpeedKmh >= commandedSpeedKmh ? "up" : "down")])
        }
        if dial.latched(.incline, isSetByHand: isInclineSetByHand) {
            record(.manualIntervention,
                   [.text("phase", "dialInferred"), .text("axis", "incline"),
                    .text("unit", "level"),
                    .int("commandedIncline", commandedIncline),
                    .int("measuredIncline", measuredIncline),
                    .int("magnitudeLevels", abs(measuredIncline - commandedIncline)),
                    .text("direction", measuredIncline >= commandedIncline ? "up" : "down")])
        }
    }

    // MARK: - Files

    /// The recent logs, newest first. The names sort chronologically, so the
    /// listing needs no date parsing to be right.
    func recentLogs() -> [StoredLog] {
        guard let directory else { return [] }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return [] }
        return urls
            .filter { $0.pathExtension == Self.fileExtension }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return StoredLog(url: url, name: url.lastPathComponent,
                                 modifiedAt: values?.contentModificationDate ?? .distantPast,
                                 sizeBytes: values?.fileSize ?? 0)
            }
            .sorted { $0.name > $1.name }
    }

    /// Everything buffered, on disk. Awaited by the share sheet's own screen, so
    /// what is offered is what has happened.
    func flush() async {
        scheduleFlush()
        await flushTask?.value
    }

    private func scheduleFlush() {
        let previous = flushTask
        flushTask = Task { [weak self] in
            await previous?.value
            await self?.drain()
        }
    }

    /// The buffer, drained in order. It loops rather than taking one batch: a
    /// caller awaiting `flush()` has to see everything that was buffered when it
    /// asked, including the lines a call site added while the sink was busy.
    private func drain() async {
        lastFlushAt = .now
        while !pending.isEmpty || !buffer.isEmpty {
            if !pending.isEmpty {
                let batch = pending.removeFirst()
                await sink.append(batch.lines, to: batch.url, keeping: Self.keptFileCount)
                continue
            }
            guard let url = fileURL else {
                // The file was closed under us (the toggle went off): the lines
                // have nowhere honest to go.
                buffer.removeAll(keepingCapacity: true)
                return
            }
            let batch = buffer
            buffer.removeAll(keepingCapacity: true)
            await sink.append(batch, to: url, keeping: Self.keptFileCount)
        }
    }

    private func closeCurrentFile() {
        guard let url = fileURL, !buffer.isEmpty else { return }
        pending.append((url, buffer))
        buffer.removeAll(keepingCapacity: true)
    }

    /// The file's name, from the local wall clock so a tester can find the run
    /// they just did. Two workouts inside one second get a suffix rather than
    /// sharing a file.
    private func nextFileName(at date: Date) -> String {
        let stamp = fileNames.string(from: date)
        let base = "\(Self.filePrefix)\(stamp)"
        if lastFileName?.hasPrefix(base) == true {
            sameSecondCounter += 1
        } else {
            sameSecondCounter = 0
        }
        let name = sameSecondCounter == 0
            ? "\(base).\(Self.fileExtension)"
            : "\(base)-\(sameSecondCounter).\(Self.fileExtension)"
        lastFileName = name
        return name
    }

    // MARK: - Pure serialisation

    /// One line. Pure and `nonisolated`, so the file format is a property of a
    /// tested function rather than of an I/O path: `seq`, `at`, `t` and `event`
    /// come first and always, then the event's own fields in the order the call
    /// site named them.
    ///
    /// Serialised by hand rather than through `JSONEncoder` for two reasons that
    /// both matter here: key order (a keyed container's output order is not
    /// promised, and an unstable order makes a diff of two runs unreadable) and
    /// number formatting (`Double` round-tripping prints 8.199999999999999 for a
    /// speed the wire carries as the integer 82).
    nonisolated static func line(_ event: DiagnosticEvent, fields: [DiagnosticField],
                                 at timestamp: String, workoutSeconds: Double,
                                 sequence: Int) -> String {
        var out = "{\"seq\":\(sequence),\"at\":\(quoted(timestamp))"
        out += ",\"t\":\(DiagnosticValue.number(workoutSeconds, decimals: 1).json)"
        out += ",\"event\":\(quoted(event.rawValue))"
        var seen = reservedFieldNames
        for field in fields where !field.name.isEmpty {
            // A duplicate key is not a JSON object any reader can trust, and the
            // header's names are the ones that must survive.
            guard seen.insert(field.name).inserted else { continue }
            out += ",\(quoted(field.name)):\(field.value.json)"
        }
        return out + "}"
    }

    /// A JSON string. Only the escapes the grammar requires: quote, backslash,
    /// the three named control characters, and `\u00xx` for the rest of C0.
    /// Everything else — accents, the en dash this project's strings are full of
    /// — is valid UTF-8 inside a JSON string and passes through.
    nonisolated static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// Which files rotation removes: everything past the newest `limit`, by
    /// name, which for this naming scheme is by time. Pure, because "the ten
    /// most recent are kept" is a property worth testing without a filesystem.
    nonisolated static func rotated(_ names: [String], keeping limit: Int) -> [String] {
        let ours = names.filter { $0.hasPrefix(filePrefix) && $0.hasSuffix(".\(fileExtension)") }
        guard ours.count > max(0, limit) else { return [] }
        return Array(ours.sorted(by: >).dropFirst(max(0, limit)))
    }

    nonisolated static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
    }

    // MARK: - The sink

    /// The file writer. An actor, so the I/O is off the main thread — no logging
    /// call may block the client's 200 ms poll or the runner's 1 Hz loop — and so
    /// two flushes cannot interleave inside one file.
    private actor Sink {
        /// The file this sink has already created the directory for and rotated
        /// around. Rotation happens once per file, not once per batch.
        private var preparedURL: URL?

        func append(_ lines: [String], to url: URL, keeping limit: Int) {
            guard !lines.isEmpty else { return }
            if preparedURL != url {
                prepare(url, keeping: limit)
                preparedURL = url
            }
            guard let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8) else {
                return
            }
            guard let handle = try? FileHandle(forWritingTo: url) else {
                try? data.write(to: url, options: .atomic)
                return
            }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }

        /// The directory, created; and the older workouts, rotated away. The new
        /// file is excluded from the rotation by name, so a run cannot delete the
        /// file it is about to write.
        private func prepare(_ url: URL, keeping limit: Int) {
            let directory = url.deletingLastPathComponent()
            let manager = FileManager.default
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
            let doomed = DiagnosticLog.rotated(names.filter { $0 != url.lastPathComponent },
                                               keeping: max(0, limit - 1))
            for name in doomed {
                try? manager.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    // MARK: - Trackers

    /// The Watch feed's edges. `0` is "no fresh reading" everywhere in this
    /// codebase, and the gap that matters is the one the governor's own
    /// `secondsWithoutHeartRate` is stated in — measured seconds, not ticks.
    private struct FeedTracker {
        private var hasReading: Bool?
        private var gapSeconds: Double = 0

        struct Transition {
            let phase: String
            let gapSeconds: Double
        }

        mutating func advanced(bpm: Int, deltaSeconds: Double) -> Transition? {
            let isFresh = bpm > 0
            let delta = deltaSeconds.isFinite && deltaSeconds > 0 ? deltaSeconds : 0
            guard let previous = hasReading else {
                hasReading = isFresh
                gapSeconds = isFresh ? 0 : delta
                // The first tick of a workout with no feed at all is a gap that
                // starts here: silence from the beginning is worth a line.
                return isFresh ? nil : Transition(phase: "gapStarted", gapSeconds: 0)
            }
            // The gap is measured before it is cleared: the line that says the
            // feed came back is the only place its length is ever reported. It
            // counts the same seconds `Tallies.secondsWithoutHeartRate` counts —
            // the tick a reading went missing included, the tick it returned not.
            let elapsedGap = gapSeconds + (isFresh ? 0 : delta)
            hasReading = isFresh
            gapSeconds = isFresh ? 0 : elapsedGap
            guard previous != isFresh else { return nil }
            return isFresh
                ? Transition(phase: "gapEnded", gapSeconds: elapsedGap)
                : Transition(phase: "gapStarted", gapSeconds: 0)
        }
    }

    private struct StalenessTracker {
        private var isStale: Bool?

        mutating func changed(to next: Bool) -> Bool {
            defer { isStale = next }
            guard let isStale else { return next } // a fresh link is the norm
            return isStale != next
        }
    }

    /// A recovery goal's crossings. The hold window's completion is reported
    /// once, because the runner ends the segment on it and the line is the
    /// evidence for that ending.
    private struct RecoveryTracker {
        private var isBelow: Bool?
        private var didComplete = false

        mutating func advanced(thresholdBpm: Int, heartRateBpm: Int,
                               holdSeconds: Double, requiredSeconds: Double) -> String? {
            if holdSeconds >= requiredSeconds, !didComplete {
                didComplete = true
                return "holdComplete"
            }
            guard heartRateBpm > 0 else { return nil }
            let below = heartRateBpm < thresholdBpm
            defer { isBelow = below }
            guard isBelow != below else { return nil }
            return below ? "belowThreshold" : "aboveThreshold"
        }
    }

    /// The hand-back verdicts, per axis. It reports a latch and a release, so a
    /// segment boundary retiring the verdict (`segmentBegan`) is visible rather
    /// than silently re-arming the next segment's report.
    private struct DialTracker {
        private var speed = false
        private var incline = false

        mutating func latched(_ axis: HeartRateActuator, isSetByHand: Bool) -> Bool {
            switch axis {
            case .speed:
                defer { speed = isSetByHand }
                return isSetByHand && !speed
            case .incline:
                defer { incline = isSetByHand }
                return isSetByHand && !incline
            }
        }
    }
}

// MARK: - The fields each call site writes

/// The field builders. Pure, `nonisolated` and static, so what the log says
/// about a decision is testable without a treadmill, a workout or a filesystem —
/// and so the two hot call sites (`ProgramRunner.steer`,
/// `FitShowTreadmillClient.write`) contain a call and not a paragraph.
extension DiagnosticLog {

    /// The half of a workout's frame that does not depend on a program: the
    /// frozen basis with the two ceilings derived from it — written out rather
    /// than left as percentages to recompute, because they are what every tally
    /// in the file is counted against — and the device's limits.
    private nonisolated static func basisAndLimitFields(basis: HeartRateBasis?,
                                                        limits: TreadmillLimits)
        -> [DiagnosticField] {
        let ceilings = basis.map { HeartRateGovernor.ceilings(for: $0) }
        return [
            .int("basisMaxBpm", basis?.maxBpm),
            .int("basisRestingBpm", basis?.restingBpm),
            .int("forceDownCeilingBpm", ceilings?.forceDownBpm),
            .int("stopCeilingBpm", ceilings?.stopBpm),
            .speed("limitMinSpeedKmh", limits.minSpeedKmh),
            .speed("limitMaxSpeedKmh", limits.maxSpeedKmh),
            .int("limitMinIncline", limits.minIncline),
            .int("limitMaxIncline", limits.maxIncline),
            .flag("limitsFromDevice", limits.fromDevice),
        ]
    }

    /// The frame of a workout no program is driving — a manual start in the
    /// app, or a belt started at the console. Same event and same field names
    /// as a program workout's frame, so a reader's grep does not care which
    /// kind it was: `program` is null and `manual` says so explicitly. The
    /// governor's constants are absent because nothing governs a manual
    /// workout; the stop and pause lifecycles carry their own windows per
    /// event.
    nonisolated static func manualWorkoutFields(isControlEnabled: Bool,
                                                isDemo: Bool,
                                                basis: HeartRateBasis?,
                                                limits: TreadmillLimits) -> [DiagnosticField] {
        [
            .text("program", nil),
            .flag("manual", true),
            .flag("heartRateControlEnabled", isControlEnabled),
            .flag("demoMode", isDemo),
            .text("appVersion", appVersion()),
        ]
        + basisAndLimitFields(basis: basis, limits: limits)
    }

    nonisolated static func workoutFields(program: WorkoutProgram,
                                         isHeartRateDriven: Bool,
                                         isControlEnabled: Bool,
                                         isDemo: Bool,
                                         basis: HeartRateBasis?,
                                         limits: TreadmillLimits) -> [DiagnosticField] {
        var fields: [DiagnosticField] = [
            .text("program", program.name),
            .int("segments", program.segments.count),
            .flag("isHeartRateDriven", isHeartRateDriven),
            .flag("heartRateControlEnabled", isControlEnabled),
            .flag("demoMode", isDemo),
            .text("appVersion", appVersion()),
        ]
        fields += basisAndLimitFields(basis: basis, limits: limits)
        fields += [
            // The governor's constants. With these on the first line of the file
            // the whole run can be checked against the rules without the source.
            .seconds("evaluationIntervalSeconds", HeartRateGovernor.evaluationIntervalSeconds),
            .seconds("settleAfterChangeSeconds", HeartRateGovernor.settleAfterChangeSeconds),
            .seconds("inclineSettleAfterChangeSeconds",
                     HeartRateGovernor.inclineSettleAfterChangeSeconds),
            .speed("maxSpeedStepKmh", HeartRateGovernor.maxSpeedStepKmh),
            .int("maxInclineStep", HeartRateGovernor.maxInclineStep),
            .int("reversalMarginBpm", HeartRateGovernor.reversalMarginBpm),
            .seconds("feedLossFallbackSeconds", HeartRateGovernor.feedLossFallbackSeconds),
            .fraction("forceDownCeilingFraction", HeartRateGovernor.forceDownCeilingFraction),
            .seconds("forceDownHoldSeconds", HeartRateGovernor.forceDownHoldSeconds),
            .fraction("stopCeilingFraction", HeartRateGovernor.stopCeilingFraction),
            .seconds("stopHoldSeconds", HeartRateGovernor.stopHoldSeconds),
            .seconds("stallWindowSeconds", HeartRateGovernor.stallWindowSeconds),
        ]
        return fields
    }

    nonisolated static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// A segment's frame: what ends it, what it commands, and — for a
    /// heart-rate segment — the arbitration of its band against the ceilings
    /// derived from the same frozen basis, with both bands written out. A band
    /// the app has been forbidden to chase and a band it is holding must not
    /// look the same in the file.
    nonisolated static func segmentFields(index: Int, segment: WorkoutSegment,
                                          entry: HeartRateGovernor.Command,
                                          isEntryClampedByCeiling: Bool,
                                          arbitration: HeartRateGovernor.BandArbitration?,
                                          status: ProgramRunner.GovernorStatus?)
        -> [DiagnosticField] {
        var fields: [DiagnosticField] = [
            .int("index", index),
            .text("name", segment.name),
            .text("goal", segment.goal.kind.rawValue),
        ]
        switch segment.goal {
        case .time(let seconds):
            fields.append(.seconds("goalSeconds", Double(seconds)))
        case .distance(let km):
            fields.append(.km("goalKm", km))
        case .untilHeartRateBelow(let bpm, let maxSeconds):
            fields.append(.int("goalBelowBpm", bpm))
            fields.append(.seconds("goalMaxSeconds", Double(maxSeconds)))
        }
        fields += [
            .speed("entrySpeedKmh", entry.speedKmh),
            .int("entryIncline", entry.incline),
            .flag("entryClampedByCeiling", isEntryClampedByCeiling),
            .text("status", status.map { name(of: $0) }),
        ]
        guard let target = segment.heartRateTarget else {
            fields.append(.text("target", "fixed"))
            return fields
        }
        let band = HeartRateGovernor.band(for: target)
        fields += [
            .text("target", "heartRate"),
            .text("actuator", target.actuator.rawValue),
            .int("requestedBandLowBpm", band.lowerBound),
            .int("requestedBandHighBpm", band.upperBound),
            .text("arbitration", arbitration.map { name(of: $0) }),
            .int("heldBandLowBpm", arbitration?.band?.lowerBound),
            .int("heldBandHighBpm", arbitration?.band?.upperBound),
            .flag("bandIsReduced", arbitration?.isReduced ?? false),
            .speed("minSpeedKmh", target.minSpeedKmh),
            .speed("maxSpeedKmh", target.maxSpeedKmh),
            .int("minIncline", target.minIncline),
            .int("maxIncline", target.maxIncline),
            .speed("fallbackSpeedKmh", target.fallbackSpeedKmh),
        ]
        return fields
    }

    /// One evaluation, whole: the input the ladder saw, the reference every rung
    /// measures from, the decision, what the runner did about it and what the
    /// dashboard was told. Every number is either the caller's own or comes from
    /// a pure `HeartRateGovernor` helper, so the log cannot disagree with the
    /// law about what the law was looking at.
    nonisolated static func governorFields(input: HeartRateGovernor.Input,
                                           decision: HeartRateGovernor.Decision,
                                           action: ProgramRunner.GovernorAction,
                                           status: ProgramRunner.GovernorStatus,
                                           isHandedBack: Bool,
                                           isLinkStale: Bool) -> [DiagnosticField] {
        let reference = HeartRateGovernor.reference(command: input.command,
                                                    lastAppliedChange: input.lastAppliedChange,
                                                    appCommand: input.appCommand,
                                                    belt: input.belt)
        let arbitration = HeartRateGovernor.arbitration(for: input.target, basis: input.basis)
        let band = arbitration.band ?? HeartRateGovernor.band(for: input.target)
        let ceilings = HeartRateGovernor.ceilings(for: input.basis)
        var fields: [DiagnosticField] = [
            .int("heartRateBpm", input.heartRate),
            .int("bandLowBpm", band.lowerBound),
            .int("bandHighBpm", band.upperBound),
            .int("bandErrorBpm", bandErrorBpm(heartRate: input.heartRate, band: band)),
            .text("arbitration", name(of: arbitration)),
            .int("forceDownCeilingBpm", ceilings.forceDownBpm),
            .int("stopCeilingBpm", ceilings.stopBpm),
            .text("actuator", input.target.actuator.rawValue),
            // The three facts, kept apart in the file exactly as they are in the
            // code: the client's target (an observation), the app's own last
            // write, the live copy of it, and the belt's measurement.
            .speed("clientTargetSpeedKmh", input.command.speedKmh),
            .int("clientTargetIncline", input.command.incline),
            .speed("appCommandSpeedKmh", input.appCommand?.speedKmh),
            .int("appCommandIncline", input.appCommand?.incline),
            .speed("lastWriteFromSpeedKmh", input.lastAppliedChange.from.speedKmh),
            .speed("lastWriteToSpeedKmh", input.lastAppliedChange.to.speedKmh),
            .int("lastWriteFromIncline", input.lastAppliedChange.from.incline),
            .int("lastWriteToIncline", input.lastAppliedChange.to.incline),
            .speed("measuredSpeedKmh", input.belt.measured?.speedKmh),
            .int("measuredIncline", input.belt.measured?.incline),
            .flag("isSpeedSetByHand", input.belt.isSpeedSetByHand),
            .flag("isInclineSetByHand", input.belt.isInclineSetByHand),
            // The one number every rung measures from.
            .speed("referenceSpeedKmh", reference.speedKmh),
            .int("referenceIncline", reference.incline),
            .flag("isAtUpperBound",
                  HeartRateGovernor.isAtUpperBound(
                    reference: reference,
                    appCommand: input.appCommand ?? input.lastAppliedChange.to,
                    target: input.target, limits: input.limits)),
            .seconds("secondsSinceSegmentStart", input.secondsSinceSegmentStart),
            .seconds("secondsSinceLastCommand", input.secondsSinceLastCommand),
            .seconds("secondsSinceLoadChange", input.secondsSinceLoadChange),
            .seconds("secondsWithoutHeartRate", input.tallies.secondsWithoutHeartRate),
            .seconds("secondsAboveForceDownCeiling",
                     input.tallies.secondsAboveForceDownCeiling),
            .seconds("secondsAboveStopCeiling", input.tallies.secondsAboveStopCeiling),
            .seconds("secondsAtUpperBoundBelowBand",
                     input.tallies.secondsAtUpperBoundBelowBand),
            .flag("didForceDown", input.tallies.didForceDown),
            .seconds("secondsBelowBandAfterForceDown",
                     input.tallies.secondsBelowBandAfterForceDown),
            .text("decision", name(of: decision)),
            .text("reason", reasonName(of: decision)),
        ]
        let commanded = commandedBy(decision)
        fields += [
            .speed("decisionSpeedKmh", commanded?.speedKmh),
            .int("decisionIncline", commanded?.incline),
            .text("action", name(of: action)),
            .text("status", name(of: status)),
            .flag("isHandedBack", isHandedBack),
            .flag("isLinkStale", isLinkStale),
        ]
        return fields
    }

    /// A write, as the two values that matter: what was asked for and what the
    /// client accepted. The pair is never collapsed — a stale link, an
    /// outstanding stop and the machine's own limits all clamp a write, and a
    /// rule reporting itself as acting while its value was refused is the one
    /// failure this log exists to catch.
    nonisolated static func writeFields(origin: DiagnosticWriteOrigin,
                                        requested: HeartRateGovernor.Command,
                                        clamped: HeartRateGovernor.Command,
                                        previous: HeartRateGovernor.Command?) -> [DiagnosticField] {
        [.text("origin", origin.rawValue),
         .speed("requestedSpeedKmh", requested.speedKmh),
         .int("requestedIncline", requested.incline),
         .speed("clampedSpeedKmh", clamped.speedKmh),
         .int("clampedIncline", clamped.incline),
         .flag("wasClamped", !HeartRateGovernor.isSameCommand(requested, clamped)),
         .speed("previousSpeedKmh", previous?.speedKmh),
         .int("previousIncline", previous?.incline)]
    }

    nonisolated static func bandErrorBpm(heartRate: Int, band: ClosedRange<Int>) -> Int {
        if heartRate <= 0 { return 0 }
        if heartRate > band.upperBound { return heartRate - band.upperBound }
        if heartRate < band.lowerBound { return heartRate - band.lowerBound }
        return 0
    }

    nonisolated static func commandedBy(_ decision: HeartRateGovernor.Decision)
        -> HeartRateGovernor.Command? {
        switch decision {
        case .adjust(let command, _), .fallback(let command): return command
        case .hold, .frozen, .emergencyStop, .manualControl: return nil
        }
    }

    // MARK: - Names

    // Exhaustive switches, no `default`: a new case has to be named here rather
    // than reaching the file as whichever string happened to be listed first.

    nonisolated static func name(of decision: HeartRateGovernor.Decision) -> String {
        switch decision {
        case .hold: return "hold"
        case .adjust: return "adjust"
        case .frozen: return "frozen"
        case .fallback: return "fallback"
        case .emergencyStop: return "emergencyStop"
        case .manualControl: return "manualControl"
        }
    }

    nonisolated static func reasonName(of decision: HeartRateGovernor.Decision) -> String? {
        switch decision {
        case .hold(let reason), .adjust(_, let reason): return name(of: reason)
        case .frozen, .fallback, .emergencyStop, .manualControl: return nil
        }
    }

    nonisolated static func name(of reason: HeartRateGovernor.Reason) -> String {
        switch reason {
        case .belowBand: return "belowBand"
        case .aboveBand: return "aboveBand"
        case .insideBand: return "insideBand"
        case .settling: return "settling"
        case .hysteresis: return "hysteresis"
        case .ceilingForceDown: return "ceilingForceDown"
        case .atBound: return "atBound"
        case .targetUnreachable: return "targetUnreachable"
        case .outOfBounds: return "outOfBounds"
        case .bandNotSteerable: return "bandNotSteerable"
        }
    }

    nonisolated static func name(of arbitration: HeartRateGovernor.BandArbitration) -> String {
        switch arbitration {
        case .steerable: return "steerable"
        case .clamped: return "clamped"
        case .notSteerable: return "notSteerable"
        }
    }

    nonisolated static func name(of action: ProgramRunner.GovernorAction) -> String {
        switch action {
        case .none: return "none"
        case .write: return "write"
        case .stop: return "stop"
        case .handBack: return "handBack"
        }
    }

    nonisolated static func name(of status: ProgramRunner.GovernorStatus) -> String {
        switch status {
        case .holding: return "holding"
        case .adjusting: return "adjusting"
        case .ceiling: return "ceiling"
        case .targetNotReached: return "targetNotReached"
        case .frozen: return "frozen"
        case .fallback: return "fallback"
        case .handedBack: return "handedBack"
        case .stopping: return "stopping"
        case .controlOff: return "controlOff"
        case .noBasis: return "noBasis"
        case .targetNotUsable: return "targetNotUsable"
        case .bandNotSteerable: return "bandNotSteerable"
        case .linkStale: return "linkStale"
        }
    }

    nonisolated static func name(of state: ProgramRunner.RunnerState) -> String {
        switch state {
        case .idle: return "idle"
        case .armed: return "armed"
        case .waitingForBelt: return "waitingForBelt"
        case .running: return "running"
        case .suspended: return "suspended"
        case .finished: return "finished"
        }
    }

    nonisolated static func name(of status: FitShow.Status) -> String {
        switch status {
        case .idle: return "idle"
        case .end: return "end"
        case .countdown: return "countdown"
        case .running: return "running"
        case .stopping: return "stopping"
        case .error: return "error"
        case .safety: return "safety"
        case .study: return "study"
        case .ready: return "ready"
        case .paused: return "paused"
        }
    }
}
