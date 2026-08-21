// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import Foundation
import SwiftData

/// Why the app itself stopped the belt, if it did — distinct from an ordinary
/// end (a segment or program finishing, or the user pressing stop). The live
/// dashboard banner that used to be the only renderer of this fact lives in a
/// view that unmounts the instant the console reports idle (finding 138), so
/// the reason needs a home that outlives it: the workout record itself.
enum WorkoutStopReason: String, CaseIterable, Sendable {
    case none
    case heartRateCeiling
}

/// One recorded workout. It owns its samples with a cascade delete.
@Model
final class WorkoutSessionRecord {
    var startedAt: Date
    var endedAt: Date?
    var deviceName: String
    var programName: String?
    /// Actual moving time (s) — paused time is counted separately.
    var movingSeconds: Int
    var pausedSeconds: Int
    var distanceKm: Double
    /// The treadmill's own calorie value (a raw estimate, without body data).
    var padKcal: Int
    /// The app's own calculation.
    var computedKcal: Double
    var avgSpeedKmh: Double
    var maxSpeedKmh: Double
    var avgHeartRate: Int
    var maxHeartRate: Int
    var healthKitSynced: Bool
    /// Whether the Watch supplied heart rate during the workout. Informational
    /// only: since #182 the phone always writes the workout to Health and the
    /// Watch discards its own instance, so this never gates the export.
    var watchProvidedHeartRate: Bool = false
    /// Total elevation gained, in metres (the integral of speed × positive incline).
    var elevationGainM: Double = 0
    /// A demo (simulated treadmill) workout — not written to Apple Health.
    var isDemo: Bool = false
    /// Moving seconds that had a fresh Watch heart rate — the one feed a
    /// governor may consume (spec section 4). Optional so a workout recorded
    /// before this build reads as unmeasured instead of claiming, via a
    /// defaulted 0, that nothing was ever missing.
    var watchHeartRateSeconds: Int?
    /// Why the app stopped the belt, if it did — the lightweight-migration
    /// default `.none` reads as "an ordinary end" for every workout recorded
    /// before this build, same as for one nothing ever stopped early
    /// (finding 138). Latched by `SessionRecorder`, never by `ProgramRunner`
    /// directly, so a later manual workout — which never runs the program
    /// start path that used to be the only place the live flag was cleared —
    /// begins on a fresh record instead of inheriting the previous one's
    /// reason (finding 142).
    var stopReasonRaw: String = WorkoutStopReason.none.rawValue
    /// Whether the app asked the belt to stop and had not seen it obeyed by
    /// the time this recording closed. Kept apart from `stopReasonRaw`
    /// because the two facts are independent: a heart-rate-ceiling stop can
    /// succeed or fail to be obeyed, and an ordinary stop can fail on its
    /// own (finding 139).
    var beltDidNotStop: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \WorkoutSampleRecord.session)
    var samples: [WorkoutSampleRecord]

    init(startedAt: Date, deviceName: String, programName: String?) {
        self.startedAt = startedAt
        self.endedAt = nil
        self.deviceName = deviceName
        self.programName = programName
        self.movingSeconds = 0
        self.pausedSeconds = 0
        self.distanceKm = 0
        self.padKcal = 0
        self.computedKcal = 0
        self.avgSpeedKmh = 0
        self.maxSpeedKmh = 0
        self.avgHeartRate = 0
        self.maxHeartRate = 0
        self.healthKitSynced = false
        // Zero, not nil: a workout this build records is measured from its first
        // second, and only a migrated row may stay unmeasured.
        self.watchHeartRateSeconds = 0
        self.samples = []
    }

    var totalSeconds: Int { movingSeconds + pausedSeconds }

    /// A record this build does not recognize reads as `.none` instead of
    /// trapping, the same tolerance `CustomSegmentRecord.goal` gives an
    /// unknown discriminator.
    var stopReason: WorkoutStopReason {
        get { WorkoutStopReason(rawValue: stopReasonRaw) ?? .none }
        set { stopReasonRaw = newValue.rawValue }
    }

    /// The share of moving time that had a live Watch heart rate, 0…100 — not
    /// of the merged reading the dashboard shows, because the handlebar sensor
    /// may not steer a belt. nil is "unmeasured", which is a different answer
    /// from 0%: that one means the Watch delivered nothing all workout.
    var watchHeartRateCoveragePercent: Double? {
        guard movingSeconds > 0, let seconds = watchHeartRateSeconds else { return nil }
        let covered = min(max(seconds, 0), movingSeconds)
        return Double(covered) / Double(movingSeconds) * 100
    }

    /// The share as a whole percent, for printing. "100%" is reserved for a feed
    /// that dropped nothing and "0%" for one that delivered nothing, so 1793 of
    /// 1800 seconds reads 99%, not 100%: whether the feed was gapless is the one
    /// question this number exists to answer.
    var watchHeartRateCoverageWholePercent: Int? {
        guard let percent = watchHeartRateCoveragePercent else { return nil }
        if percent >= 100 { return 100 }
        if percent <= 0 { return 0 }
        return min(max(Int(percent.rounded()), 1), 99)
    }

    var sortedSamples: [WorkoutSampleRecord] {
        samples.sorted { $0.offsetSeconds < $1.offsetSeconds }
    }
}

/// A one-per-second sample from the workout.
@Model
final class WorkoutSampleRecord {
    var offsetSeconds: Int
    /// Wall-clock timestamp — needed for the Health export, because the
    /// moving-time offset would drift from the wall clock after pauses.
    var timestamp: Date = Date.distantPast
    var speedKmh: Double
    var inclinePercent: Int
    var heartRate: Int
    var distanceKm: Double
    /// The heart-rate band the governor was actually holding this second —
    /// the *arbitrated* one (`ProgramRunner.governedBandBpm`), never the
    /// segment's stored request, which the arbitration may have clamped away
    /// from. Both default to 0 for a lightweight migration and for any second
    /// nothing was governing; spec section 4, "Recording and review".
    var targetHrLow: Int = 0
    var targetHrHigh: Int = 0
    var session: WorkoutSessionRecord?

    init(offsetSeconds: Int, speedKmh: Double, inclinePercent: Int,
         heartRate: Int, distanceKm: Double,
         targetHrLow: Int = 0, targetHrHigh: Int = 0) {
        self.offsetSeconds = offsetSeconds
        self.timestamp = Date()
        self.speedKmh = speedKmh
        self.inclinePercent = inclinePercent
        self.heartRate = heartRate
        self.distanceKm = distanceKm
        self.targetHrLow = targetHrLow
        self.targetHrHigh = targetHrHigh
    }

    /// Was this second actually governed? 0/0 is the untouched default, and no
    /// real band starts at 0 bpm — so the history chart can draw the band for
    /// exactly the seconds that had one, and nothing for a workout that was
    /// never governed.
    var hasTargetHeartRateBand: Bool { targetHrHigh > 0 }
}
