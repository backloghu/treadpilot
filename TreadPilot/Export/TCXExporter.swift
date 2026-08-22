// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import Foundation

/// Why a workout could not be written out as a file.
enum TCXExportError: Error {
    /// A simulated workout. It never happened, so it may not leave the app as a
    /// file the user could upload as a real run — the same rule that keeps demo
    /// workouts out of Apple Health (`HealthKitExporter.export`).
    case demoSession
}

/// A finished workout as a Garmin TCX v2 document.
///
/// Strava's Apple Health import ignores workouts written by third-party apps,
/// so a TreadPilot workout can never reach Strava through Health; the interim
/// path is a file the user uploads at strava.com/upload by hand. GPX is not an
/// option — it makes latitude/longitude mandatory and a treadmill has neither —
/// while TCX carries the time, distance, heart-rate and speed series with no
/// `Position` element at all, which is exactly what makes Strava render the
/// result as an indoor activity with no map.
///
/// The document is the whole of this type's job: no UI, no share sheet, no
/// upload. The direct Strava API upload reuses `document(for:)` verbatim.
struct TCXExporter {

    // MARK: - Format constants

    private static let trainingCenterNamespace =
        "http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2"
    /// Per-sample speed is not a TCX v2 `Trackpoint` member; it lives in this
    /// extension. `ns3` is the prefix every Garmin-produced file binds it to —
    /// readers key on the URI, not the prefix, but matching the convention keeps
    /// this file diffable against a real device's export.
    private static let activityExtensionNamespace =
        "http://www.garmin.com/xmlschemas/ActivityExtension/v2"
    private static let schemaInstanceNamespace = "http://www.w3.org/2001/XMLSchema-instance"
    private static let schemaLocation =
        "http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2"
        + " http://www.garmin.com/xmlschemas/TrainingCenterDatabasev2.xsd"

    /// `Sport` is a closed TCX enum — Running, Biking, Other — with no walking
    /// member, so the 6.5 km/h split the Health export uses to pick between
    /// `.running` and `.walking` has nothing to map onto here and is deliberately
    /// not reused. Every workout goes out as Running: Strava then renders a run
    /// with pace, splits and a heart-rate analysis, and re-typing it to Walk is
    /// one menu in Strava that keeps all of it. `Other` imports as a bare
    /// "Workout" and loses the pace rendering for good.
    private static let sport = "Running"

    private static let fileNamePrefix = "TreadPilot_"
    private static let fileExtension = "tcx"

    // MARK: - Document

    /// The complete TCX document for one workout, including the XML declaration.
    static func document(for session: WorkoutSessionRecord) -> String {
        let start = session.startedAt
        // The same span the Health export writes (`HealthKitExporter.export`):
        // a session whose end was never recorded reaches as far past its start
        // as its own bookkeeping does.
        let end = session.endedAt
            ?? start.addingTimeInterval(TimeInterval(max(session.totalSeconds, 1)))
        let clock = UTCTimestamps()
        let startTime = clock.string(from: start)

        var lines: [String] = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<TrainingCenterDatabase xmlns=\"\(trainingCenterNamespace)\""
                + " xmlns:ns3=\"\(activityExtensionNamespace)\""
                + " xmlns:xsi=\"\(schemaInstanceNamespace)\""
                + " xsi:schemaLocation=\"\(schemaLocation)\">",
            "  <Activities>",
            "    <Activity Sport=\"\(sport)\">",
            "      <Id>\(startTime)</Id>",
            "      <Lap StartTime=\"\(startTime)\">",
            // TCX's TotalTimeSeconds is timer time, not elapsed time — a Garmin
            // lap excludes what its auto-pause stopped — and the trackpoints
            // below exist one per *moving* second, so moving time is the only
            // figure the track can corroborate. Elapsed time stays recoverable
            // from the trackpoints' own wall clocks, which is where Strava reads
            // it from anyway.
            "        <TotalTimeSeconds>"
                + decimal(Double(session.movingSeconds), places: 1)
                + "</TotalTimeSeconds>",
            "        <DistanceMeters>"
                + decimal(session.distanceKm * 1000, places: 2)
                + "</DistanceMeters>",
            "        <Calories>\(calories(for: session))</Calories>",
        ]
        // Zero means "nothing was measured" on this record, and the schema's own
        // bpm type starts at 1 — so an unmeasured rate is an absent element, not
        // a zero one.
        if session.avgHeartRate > 0 {
            lines.append("        <AverageHeartRateBpm><Value>"
                         + "\(bpm(session.avgHeartRate))"
                         + "</Value></AverageHeartRateBpm>")
        }
        if session.maxHeartRate > 0 {
            lines.append("        <MaximumHeartRateBpm><Value>"
                         + "\(bpm(session.maxHeartRate))"
                         + "</Value></MaximumHeartRateBpm>")
        }
        lines.append("        <Intensity>Active</Intensity>")
        lines.append("        <TriggerMethod>Manual</TriggerMethod>")

        // A workout with no samples — stopped in its first second, or a record
        // whose samples were pruned — still exports: the lap's own summary is
        // the whole workout, and `Track` is optional in the schema. An empty
        // `<Track/>` would instead claim a track that recorded nothing.
        let track = trackpoints(for: session, start: start, end: end, clock: clock)
        if !track.isEmpty {
            lines.append("        <Track>")
            lines.append(contentsOf: track)
            lines.append("        </Track>")
        }
        lines.append("      </Lap>")
        // Schema order inside Activity: Id, Lap, Notes, Training, Creator.
        if let notes = notes(for: session) {
            lines.append("      <Notes>\(notes)</Notes>")
        }
        lines.append(contentsOf: creator(for: session))
        lines.append("    </Activity>")
        lines.append("  </Activities>")
        lines.append("</TrainingCenterDatabase>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// One trackpoint per recorded second.
    ///
    /// `Time` is the wall clock, never the moving-time offset: after a pause the
    /// two diverge, and a track whose times drift from the workout's real clock
    /// imports at the wrong time of day. The fallback for a row migrated from a
    /// build without the field (`timestamp` still at its `.distantPast`
    /// sentinel) and the guard that drops a sample past the session's end are
    /// both the Health export's (`HealthKitExporter.export`), so the two exports
    /// of one workout describe the same span rather than two different ones.
    private static func trackpoints(for session: WorkoutSessionRecord,
                                    start: Date, end: Date,
                                    clock: UTCTimestamps) -> [String] {
        // Collected before any line is built: the distance synthesis below
        // must integrate over exactly this ordered, end-filtered sequence, so
        // its output lines up index for index with the trackpoints emitted
        // from it.
        var emitted: [(sample: WorkoutSampleRecord, timestamp: Date)] = []
        for sample in session.sortedSamples {
            let timestamp = sample.timestamp > start
                ? sample.timestamp
                : start.addingTimeInterval(TimeInterval(sample.offsetSeconds))
            guard timestamp <= end else { continue }
            emitted.append((sample, timestamp))
        }

        let distancesMeters = synthesizedDistancesMeters(
            for: emitted.map { $0.sample }, recordedTotalKm: session.distanceKm)

        var lines: [String] = []
        for (index, entry) in emitted.enumerated() {
            lines.append("          <Trackpoint>")
            lines.append("            <Time>\(clock.string(from: entry.timestamp))</Time>")
            lines.append("            <DistanceMeters>"
                         + decimal(distancesMeters[index], places: 2)
                         + "</DistanceMeters>")
            if entry.sample.heartRate > 0 {
                lines.append("            <HeartRateBpm><Value>"
                             + "\(bpm(entry.sample.heartRate))"
                             + "</Value></HeartRateBpm>")
            }
            // The extension's unit is m/s, so the recorded km/h is converted
            // here rather than left for the reader to guess at.
            lines.append("            <Extensions>")
            lines.append("              <ns3:TPX>")
            lines.append("                <ns3:Speed>"
                         + decimal(entry.sample.speedKmh / 3.6, places: 3)
                         + "</ns3:Speed>")
            lines.append("              </ns3:TPX>")
            lines.append("            </Extensions>")
            lines.append("          </Trackpoint>")
        }
        return lines
    }

    /// Per-trackpoint `DistanceMeters`, synthesized from belt speed rather
    /// than copied verbatim from the pad's own odometer.
    ///
    /// The FitShow status frame reports distance in 0.1 km units
    /// (`FitShowProtocol.swift`: `raw / 10`) — the pad cannot do finer — so
    /// the per-second `sample.distanceKm` this function would otherwise copy
    /// is a 100 m staircase, plateaued for 40-70 seconds at walking/running
    /// speed. Strava derives pace from consecutive `DistanceMeters` deltas,
    /// so a staircase reads as alternating stops and sprints: the sawtooth
    /// pace chart this function exists to remove. The fix integrates the
    /// belt's own per-sample speed into a smooth cumulative series, then
    /// rescales that series so its own total lands exactly on
    /// `recordedTotalKm` — the pad's own total stays authoritative, only the
    /// shape between the two ends changes. A session with no usable speed
    /// (every sample at 0 km/h) or no recorded distance has nothing to
    /// integrate or rescale to, so it falls back to the pad's own recorded
    /// series unchanged.
    ///
    /// `samples` must be the same ordered, end-filtered sequence the caller
    /// is about to emit as trackpoints — the result lines up with it index
    /// for index.
    private static func synthesizedDistancesMeters(for samples: [WorkoutSampleRecord],
                                                    recordedTotalKm: Double) -> [Double] {
        guard !samples.isEmpty else { return [] }

        var integratedKm: [Double] = []
        integratedKm.reserveCapacity(samples.count)
        var runningKm = 0.0
        var previousOffsetSeconds = samples[0].offsetSeconds
        for (index, sample) in samples.enumerated() {
            let dtSeconds = index == 0
                ? 1.0
                : Double(max(0, sample.offsetSeconds - previousOffsetSeconds))
            runningKm += sample.speedKmh / 3600.0 * dtSeconds
            integratedKm.append(runningKm)
            previousOffsetSeconds = sample.offsetSeconds
        }

        let integratedTotalKm = integratedKm[integratedKm.count - 1]
        guard recordedTotalKm > 0, integratedTotalKm > 0 else {
            return samples.map { $0.distanceKm * 1000 }
        }

        let scale = recordedTotalKm / integratedTotalKm
        var distancesMeters = integratedKm.map { $0 * scale * 1000 }
        // The rescale lands the last point on `recordedTotalKm` to within
        // float noise, but "to within" is not good enough: Strava — and this
        // file's own exact-match test — expect the last trackpoint to render
        // identical to the Lap's own DistanceMeters, so it is pinned rather
        // than trusted to the arithmetic.
        distancesMeters[distancesMeters.count - 1] = recordedTotalKm * 1000
        return distancesMeters
    }

    /// The treadmill, named. `Device_t` is the one `Creator` shape whose members
    /// are all fixed by the schema, so the identifiers TreadPilot cannot know
    /// for a FitShow belt go out as zero instead of invented. A nameless belt
    /// gets no element at all: an empty `<Name/>` is not a device.
    private static func creator(for session: WorkoutSessionRecord) -> [String] {
        let name = session.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return [] }
        return [
            "      <Creator xsi:type=\"Device_t\">",
            "        <Name>\(escaped(name))</Name>",
            "        <UnitId>0</UnitId>",
            "        <ProductID>0</ProductID>",
            "        <Version>",
            "          <VersionMajor>0</VersionMajor>",
            "          <VersionMinor>0</VersionMinor>",
            "          <BuildMajor>0</BuildMajor>",
            "          <BuildMinor>0</BuildMinor>",
            "        </Version>",
            "      </Creator>",
        ]
    }

    /// The program's name, when the workout ran one — the one fact no summary
    /// element can carry, and what tells the user in Strava which of their own
    /// programs this run was.
    private static func notes(for session: WorkoutSessionRecord) -> String? {
        guard let program = session.programName?
            .trimmingCharacters(in: .whitespacesAndNewlines), !program.isEmpty
        else { return nil }
        return escaped(program)
    }

    // MARK: - File

    /// The document on disk, ready to hand to a share sheet or an upload.
    ///
    /// The temporary directory on purpose: the file is a hand-off, not a record
    /// — the workout itself lives in SwiftData — and one name per workout start
    /// means re-exporting the same session replaces its file instead of
    /// littering the directory with copies.
    static func writeFile(for session: WorkoutSessionRecord) throws -> URL {
        guard !session.isDemo else { throw TCXExportError.demoSession }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName(for: session.startedAt), isDirectory: false)
        // `.atomic` replaces a file already at that name.
        try Data(document(for: session).utf8).write(to: url, options: .atomic)
        return url
    }

    /// `TreadPilot_yyyy-MM-dd_HHmm.tcx`, in the device's own time zone: the user
    /// reads this name in a share sheet, so it says when *they* ran, not when
    /// UTC did. `en_US_POSIX` keeps the digits Arabic and the pattern literal
    /// whatever calendar or numbering the device prefers.
    private static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        return "\(fileNamePrefix)\(formatter.string(from: date)).\(fileExtension)"
    }

    // MARK: - Values

    /// ISO 8601 in UTC with the trailing `Z`, which is what the `xsd:dateTime`
    /// fields of TCX want. One instance per document rather than a shared one:
    /// `ISO8601DateFormatter` is a class with mutable state, so it could not be
    /// a `static let` under strict concurrency checking anyway.
    private struct UTCTimestamps {
        private let formatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            return formatter
        }()

        func string(from date: Date) -> String { formatter.string(from: date) }
    }

    /// A locale-independent decimal. `String(format:)` passes no locale, so it
    /// formats in the C locale and the separator stays a point on a Hungarian
    /// phone too — a `NumberFormatter`, or anything else built on
    /// `Locale.current`, would write `5000,00`, which is not an `xsd:double`.
    /// A non-finite value has no `xsd:double` form either ("nan" is not one), so
    /// a corrupt row exports as zero rather than as a document no reader can
    /// parse.
    private static func decimal(_ value: Double, places: Int) -> String {
        String(format: "%.\(places)f", value.isFinite ? value : 0)
    }

    /// The Health export's precedence (`HealthKitExporter.export`): the app's own
    /// calculation when it has one, the treadmill's raw estimate otherwise.
    /// `Calories` is an `unsignedShort`, so the figure is rounded into range.
    private static func calories(for session: WorkoutSessionRecord) -> Int {
        let kcal = session.computedKcal > 0 ? session.computedKcal : Double(session.padKcal)
        guard kcal.isFinite else { return 0 }
        return min(max(Int(kcal.rounded()), 0), 65535)
    }

    /// A heart rate the schema accepts: `Value` is an `unsignedByte` limited to
    /// 1…255, and a belt's handlebar sensor can report noise outside that.
    private static func bpm(_ value: Int) -> Int { min(max(value, 1), 255) }

    /// XML escaping for every interpolated string. The device name arrives over
    /// BLE and the program name is typed by the user, so an unescaped `&` or `<`
    /// in either one is a document no parser will read. Characters XML 1.0
    /// forbids outright — the C0 controls other than tab, newline and carriage
    /// return have no escape sequence at all in XML 1.0 — are dropped for the
    /// same reason.
    private static func escaped(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                if scalar.value >= 0x20 { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }
}
