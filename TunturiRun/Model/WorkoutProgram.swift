import Foundation

/// Egy edzésprogram-szegmens: adott ideig tartandó cél sebesség és dőlés.
struct WorkoutSegment: Identifiable, Equatable, Hashable {
    let id = UUID()
    var name: String
    var duration: TimeInterval
    var targetSpeedKmh: Double
    var targetIncline: Int
}

struct WorkoutProgram: Identifiable, Equatable, Hashable {
    let id = UUID()
    var name: String
    var segments: [WorkoutSegment]

    var totalDuration: TimeInterval {
        segments.reduce(0) { $0 + $1.duration }
    }

    /// Beépített bemutató programok az első tesztekhez — szándékosan óvatos sebességekkel.
    static let builtIn: [WorkoutProgram] = [
        WorkoutProgram(name: "Óvatos teszt (6 perc)", segments: [
            WorkoutSegment(name: "Séta", duration: 120, targetSpeedKmh: 3.0, targetIncline: 0),
            WorkoutSegment(name: "Tempós séta", duration: 120, targetSpeedKmh: 5.0, targetIncline: 1),
            WorkoutSegment(name: "Levezetés", duration: 120, targetSpeedKmh: 3.0, targetIncline: 0),
        ]),
        WorkoutProgram(name: "Intervall 5×(1+1) perc", segments: [
            WorkoutSegment(name: "Bemelegítés", duration: 180, targetSpeedKmh: 5.0, targetIncline: 0)
        ]
        + (1...5).flatMap { round in [
            WorkoutSegment(name: "Gyors \(round)", duration: 60, targetSpeedKmh: 9.0, targetIncline: 0),
            WorkoutSegment(name: "Pihenő \(round)", duration: 60, targetSpeedKmh: 6.0, targetIncline: 0),
        ]}
        + [WorkoutSegment(name: "Levezetés", duration: 180, targetSpeedKmh: 4.5, targetIncline: 0)]),
    ]
}
