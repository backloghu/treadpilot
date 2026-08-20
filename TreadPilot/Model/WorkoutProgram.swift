// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import Foundation

/// What ends a segment. A segment has two independent axes: the goal (when is it
/// over) and the target (what does it command). All three cases are declared now
/// so the type does not have to be reopened when heart-rate control lands, but
/// only .time and .distance are produced today.
enum SegmentGoal: Equatable, Hashable {
    case time(seconds: Int)
    case distance(km: Double)
    /// Active recovery: hold the target until the heart rate drops below `bpm`,
    /// but never longer than `maxSeconds`. Nothing produces this yet — until the
    /// runner has a heart-rate feed it behaves as a plain time goal of
    /// `maxSeconds`, which is also how it has to behave when the sensor fails.
    case untilHeartRateBelow(bpm: Int, maxSeconds: Int)

    /// The stored discriminator (`CustomSegmentRecord.goalKindRaw`).
    enum Kind: String {
        case time
        case distance
        case untilHeartRateBelow
    }

    var kind: Kind {
        switch self {
        case .time:
            return .time
        case .distance:
            return .distance
        case .untilHeartRateBelow:
            return .untilHeartRateBelow
        }
    }
}

/// One workout program segment: a target speed and incline, held until the
/// segment's goal is reached.
struct WorkoutSegment: Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var goal: SegmentGoal
    var targetSpeedKmh: Double
    var targetIncline: Int

    init(id: UUID = UUID(), name: String, goal: SegmentGoal,
         targetSpeedKmh: Double, targetIncline: Int) {
        self.id = id
        self.name = name
        self.goal = goal
        self.targetSpeedKmh = targetSpeedKmh
        self.targetIncline = targetIncline
    }

    /// A time-goal segment. Kept as its own initializer so every call site that
    /// only ever knew a duration — the built-in programs, the sample data, the
    /// tests — reads exactly as it did before the goal axis existed.
    init(id: UUID = UUID(), name: String, duration: TimeInterval,
         targetSpeedKmh: Double, targetIncline: Int) {
        self.init(id: id, name: name, goal: .time(seconds: Int(duration)),
                  targetSpeedKmh: targetSpeedKmh, targetIncline: targetIncline)
    }

    /// The slowest speed an estimate may divide by. A segment with a zero (or
    /// nonsense) speed would otherwise produce an infinite planned duration and
    /// poison every program total; the runner's ETA uses the same floor, so the
    /// two can never disagree.
    static let minEstimateSpeedKmh = TreadmillLimits().minSpeedKmh
    /// Upper bound for every duration estimate. An estimate is a division: a
    /// nonsense input has to yield an implausible number, never an overflow.
    static let maxEstimateSeconds = 24 * 3600
    /// The distances a distance goal may be given: a tenth of a kilometre up to
    /// a marathon. The editor's stepper takes its range from here, so the two
    /// cannot drift apart.
    static let goalDistanceRangeKm = 0.1...42.2
    /// The grid a distance goal snaps to, and the editor's Stepper step.
    /// Hoisted for the same reason as `goalDurationStepSeconds`: seeding a
    /// value the Stepper cannot represent leaves the editor unable to walk it
    /// back, so the grid has to exist in exactly one place.
    static let goalDistanceStepKm = 0.1
    /// The durations a time goal may be given, and the grid the editor's
    /// Stepper snaps to. Hoisted here for the same reason as
    /// `goalDistanceRangeKm`: switching a goal kind must never seed a value
    /// outside what the editor can represent, so `CustomSegmentRecord`'s own
    /// clamp and the editor's Stepper must read the same numbers instead of
    /// two literals that can drift apart.
    static let goalDurationRangeSeconds = 15...7200
    static let goalDurationStepSeconds = 15

    /// The speed the segment commands. It reads from the stored target today;
    /// when the target axis lands it comes from `SegmentTarget` instead.
    var nominalSpeedKmh: Double { targetSpeedKmh }

    /// The incline the segment commands — the same indirection, for the same
    /// reason: with the target axis in place a heart-rate segment's commanded
    /// incline is its starting incline, and every call site that reads the plan
    /// rather than the stored column already goes through here.
    var nominalIncline: Int { targetIncline }

    /// The divisor of every estimate: the commanded speed, floored and finite.
    private var estimateSpeedKmh: Double {
        let speed = nominalSpeedKmh
        return speed.isFinite && speed > Self.minEstimateSpeedKmh ? speed : Self.minEstimateSpeedKmh
    }

    /// Every planned duration passes through here, and so does the runner's live
    /// ETA: `ProgramRunner.clampedSeconds` calls this function and only rounds the
    /// result — one ceiling, applied once. When the two had their own, a 42.2 km
    /// segment at 0.8 km/h planned 52 hours while its ETA was capped at 24, and the
    /// program progress bar was 55% full at second zero because it divided the one
    /// by the other.
    static func cappedDuration(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return min(seconds, TimeInterval(maxEstimateSeconds))
    }

    /// How long the segment is expected to last. Exact for a time goal, an
    /// estimate otherwise — see `isDurationEstimated`.
    var plannedDuration: TimeInterval {
        switch goal {
        case .time(let seconds):
            return Self.cappedDuration(TimeInterval(seconds))
        case .distance(let km):
            guard km.isFinite, km > 0 else { return 0 }
            return Self.cappedDuration(km / estimateSpeedKmh * 3600)
        case .untilHeartRateBelow(_, let maxSeconds):
            // The time cap is the only bound known in advance.
            return Self.cappedDuration(TimeInterval(maxSeconds))
        }
    }

    /// `plannedDuration` in whole seconds. The ceiling is already applied there —
    /// this only rounds, so the two cannot say different things.
    var plannedDurationSeconds: Int {
        Int(plannedDuration.rounded())
    }

    /// How far the segment is expected to cover. Exact for a distance goal, an
    /// estimate otherwise — see `isDistanceEstimated`. The estimated cases read
    /// the *capped* duration: a distance derived from a longer time than the plan
    /// admits would put the program totals on two different scales again.
    var plannedDistanceKm: Double {
        switch goal {
        case .distance(let km):
            return km
        case .time, .untilHeartRateBelow:
            return plannedDuration / 3600 * nominalSpeedKmh
        }
    }

    var isDurationEstimated: Bool {
        if case .time = goal { return false }
        return true
    }

    var isDistanceEstimated: Bool {
        if case .distance = goal { return false }
        return true
    }
}

/// Renderings of a segment's goal, target, speed and pace. They live next to
/// the model so the dashboard, the editor and the program lists cannot drift
/// apart in how a segment reads. Program-level totals are not this enum's
/// concern — a total's two-decimal precision (e.g. `%.2f km`) is a deliberate
/// difference from a segment's one-decimal label, not an omission.
///
/// TODO: `SessionFormat` lives in TreadPilot/UI/HistoryView.swift. Calling it is
/// legal (one module), but the dependency points the wrong way — the app's only
/// duration formatter belongs in the model layer, next to this enum. Moving it
/// touches a UI file, so it is left to a separate change.
enum SegmentFormat {
    /// "5:00" for a time goal, "5.0 km" for a distance goal.
    static func goal(_ goal: SegmentGoal) -> String {
        switch goal {
        case .time(let seconds):
            return SessionFormat.duration(seconds)
        case .distance(let km):
            return distance(km)
        case .untilHeartRateBelow(let bpm, let maxSeconds):
            return String(localized: "<\(bpm) bpm, max \(SessionFormat.duration(maxSeconds))")
        }
    }

    /// "8.0 km/h"
    static func speed(_ speedKmh: Double) -> String {
        String(format: "%.1f km/h", speedKmh)
    }

    /// "8.0 km/h · 0%" — the same order and separator the segment rows use.
    static func target(speedKmh: Double, incline: Int) -> String {
        speed(speedKmh) + " · \(incline)%"
    }

    /// "5.0 km"
    static func distance(_ km: Double) -> String {
        String(format: "%.1f km", km)
    }

    /// "3.2 / 5.0 km" — the dashboard's large readout for a distance goal.
    static func distanceProgress(_ km: Double, goalKm: Double) -> String {
        String(format: "%.1f / %.1f km", km, goalKm)
    }

    /// "7:30 min/km" — runners think in pace. Nil for a standing belt, and for
    /// a speed so low that the pace would say nothing. The unit goes through
    /// the catalog: it used to be a bare " min/km" literal that never reached
    /// the String Catalog, so the Hungarian build showed it in English.
    static func pace(speedKmh: Double) -> String? {
        guard speedKmh.isFinite, speedKmh > 0 else { return nil }
        let secondsPerKm = 3600 / speedKmh
        guard secondsPerKm.isFinite,
              secondsPerKm < Double(WorkoutSegment.maxEstimateSeconds) else { return nil }
        return SessionFormat.duration(Int(secondsPerKm.rounded())) + " " + String(localized: "min/km")
    }
}

struct WorkoutProgram: Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var segments: [WorkoutSegment]
    var isBuiltIn = false

    var totalDuration: TimeInterval {
        segments.reduce(0) { $0 + $1.plannedDuration }
    }

    /// The program's expected total distance: exact for the distance segments,
    /// derived from the target speed for the rest. `hasEstimatedDistance` says
    /// whether any of it is a projection — a distance goal's kilometres are the
    /// contract, a time goal's are an expectation.
    var totalDistanceKm: Double {
        segments.reduce(0) { $0 + $1.plannedDistanceKm }
    }

    /// The program's expected total elevation gain (positive-incline segments only).
    var totalElevationGainM: Double {
        segments.reduce(0) {
            $0 + ElevationMath.gainPerSecond(speedKmh: $1.nominalSpeedKmh,
                                             inclinePercent: $1.nominalIncline) * $1.plannedDuration
        }
    }

    /// Time-weighted average speed.
    var averageSpeedKmh: Double {
        totalDuration > 0 ? totalDistanceKm / (totalDuration / 3600) : 0
    }

    /// True when the total time is only a projection (any distance or
    /// heart-rate goal) — the UI prefixes such a total with `~`.
    var hasEstimatedDuration: Bool {
        segments.contains { $0.isDurationEstimated }
    }

    /// True when the total distance is only a projection. A time-only program
    /// falls in here too: its distance was always derived from target speeds,
    /// the flag just says so out loud now. No UI reads this yet — it is kept
    /// for phase 3, where a `.untilHeartRateBelow` segment's distance is
    /// genuinely unknown in advance.
    var hasEstimatedDistance: Bool {
        segments.contains { $0.isDistanceEstimated }
    }

    /// Built-in demo programs for the first tests — deliberately cautious speeds.
    static let builtIn: [WorkoutProgram] = [
        WorkoutProgram(name: String(localized: "Gentle test (6 min)"), segments: [
            WorkoutSegment(name: String(localized: "Walk"), duration: 120, targetSpeedKmh: 3.0, targetIncline: 0),
            WorkoutSegment(name: String(localized: "Brisk walk"), duration: 120, targetSpeedKmh: 5.0, targetIncline: 1),
            WorkoutSegment(name: String(localized: "Cool-down"), duration: 120, targetSpeedKmh: 3.0, targetIncline: 0),
        ], isBuiltIn: true),
        WorkoutProgram(name: String(localized: "Intervals 5×(1+1) min"), segments: [
            WorkoutSegment(name: String(localized: "Warm-up"), duration: 180, targetSpeedKmh: 5.0, targetIncline: 0)
        ]
        + (1...5).flatMap { round in [
            WorkoutSegment(name: String(localized: "Fast \(round)"), duration: 60, targetSpeedKmh: 9.0, targetIncline: 0),
            WorkoutSegment(name: String(localized: "Recovery \(round)"), duration: 60, targetSpeedKmh: 6.0, targetIncline: 0),
        ]}
        + [WorkoutSegment(name: String(localized: "Cool-down"), duration: 180, targetSpeedKmh: 4.5, targetIncline: 0)],
        isBuiltIn: true),
    ]
}
