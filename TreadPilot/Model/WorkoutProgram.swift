import Foundation

/// Egy edzésprogram-szegmens: adott ideig tartandó cél sebesség és dőlés.
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

    /// A program várható össztávja a szakaszok célsebességéből.
    var totalDistanceKm: Double {
        segments.reduce(0) { $0 + $1.duration / 3600 * $1.targetSpeedKmh }
    }

    /// A program várható összes emelkedése (csak a pozitív dőlésű szakaszok).
    var totalElevationGainM: Double {
        segments.reduce(0) {
            $0 + ElevationMath.gainPerSecond(speedKmh: $1.targetSpeedKmh,
                                             inclinePercent: $1.targetIncline) * $1.duration
        }
    }

    /// Idővel súlyozott átlagsebesség.
    var averageSpeedKmh: Double {
        totalDuration > 0 ? totalDistanceKm / (totalDuration / 3600) : 0
    }

    /// Beépített bemutató programok az első tesztekhez — szándékosan óvatos sebességekkel.
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
