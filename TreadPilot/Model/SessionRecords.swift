// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import Foundation
import SwiftData

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
        self.samples = []
    }

    var totalSeconds: Int { movingSeconds + pausedSeconds }

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
    var session: WorkoutSessionRecord?

    init(offsetSeconds: Int, speedKmh: Double, inclinePercent: Int,
         heartRate: Int, distanceKm: Double) {
        self.offsetSeconds = offsetSeconds
        self.timestamp = Date()
        self.speedKmh = speedKmh
        self.inclinePercent = inclinePercent
        self.heartRate = heartRate
        self.distanceKm = distanceKm
    }
}
