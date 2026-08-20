// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import Foundation

/// One workout program segment: a target speed and incline to hold for a given time.
struct WorkoutSegment: Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var duration: TimeInterval
    var targetSpeedKmh: Double
    var targetIncline: Int
}

struct WorkoutProgram: Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var segments: [WorkoutSegment]
    var isBuiltIn = false

    var totalDuration: TimeInterval {
        segments.reduce(0) { $0 + $1.duration }
    }

    /// The program's expected total distance, from the segments' target speeds.
    var totalDistanceKm: Double {
        segments.reduce(0) { $0 + $1.duration / 3600 * $1.targetSpeedKmh }
    }

    /// The program's expected total elevation gain (positive-incline segments only).
    var totalElevationGainM: Double {
        segments.reduce(0) {
            $0 + ElevationMath.gainPerSecond(speedKmh: $1.targetSpeedKmh,
                                             inclinePercent: $1.targetIncline) * $1.duration
        }
    }

    /// Time-weighted average speed.
    var averageSpeedKmh: Double {
        totalDuration > 0 ? totalDistanceKm / (totalDuration / 3600) : 0
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
