// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import Foundation
import SwiftData

/// A workout program edited by the user.
@Model
final class CustomProgram {
    var uuid: UUID
    var name: String
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \CustomSegmentRecord.program)
    var segments: [CustomSegmentRecord]

    init(name: String) {
        self.uuid = UUID()
        self.name = name
        self.createdAt = Date()
        self.segments = []
    }

    var sortedSegments: [CustomSegmentRecord] {
        segments.sorted { $0.orderIndex < $1.orderIndex }
    }

    /// The program's planned length. It sums the goals, not the stored
    /// `durationSeconds` column: for a distance segment that column is only a
    /// mirror of the estimate and can lag a speed change by one edit.
    var totalSeconds: Int {
        segments.reduce(0) { $0 + $1.plannedDurationSeconds }
    }

    /// True when the program's total time is only a projection. Tests each
    /// segment's goal kind directly against the stored discriminator and
    /// constructs nothing, the same way `totalSeconds` already avoids it:
    /// `ProgramListView` used to read `asWorkoutProgram.hasEstimatedDuration`,
    /// which sorts and rebuilds every segment into a `WorkoutSegment` per row
    /// just to extract one Bool.
    var hasEstimatedDuration: Bool {
        segments.contains { $0.goal.kind != .time }
    }

    /// Conversion into runnable form. The identifiers are the stored uuids, so
    /// the dashboard picker's selection stays stable across re-conversion.
    var asWorkoutProgram: WorkoutProgram {
        WorkoutProgram(
            id: uuid,
            name: name,
            segments: sortedSegments.map(\.asWorkoutSegment)
        )
    }

    /// Copying a built-in or another program into a custom one.
    static func copy(of program: WorkoutProgram, name: String) -> CustomProgram {
        let custom = CustomProgram(name: name)
        for (index, segment) in program.segments.enumerated() {
            let record = CustomSegmentRecord(
                orderIndex: index,
                name: segment.name,
                durationSeconds: segment.plannedDurationSeconds,
                targetSpeedKmh: segment.targetSpeedKmh,
                targetIncline: segment.targetIncline
            )
            // After the targets, because a distance goal derives its stored
            // planned duration from the segment's speed.
            record.goal = segment.goal
            record.program = custom
            custom.segments.append(record)
        }
        return custom
    }
}

@Model
final class CustomSegmentRecord {
    var uuid: UUID
    var orderIndex: Int
    var name: String
    /// For a time goal this *is* the goal; for a distance goal it is the planned
    /// duration, so the existing list labels and ordering keep working.
    var durationSeconds: Int
    var targetSpeedKmh: Double
    var targetIncline: Int
    // The goal axis. New properties with default values are a lightweight
    // SwiftData migration — no VersionedSchema needed; the precedent is
    // WorkoutSampleRecord.timestamp.
    var goalKindRaw: String = SegmentGoal.Kind.time.rawValue
    var goalDistanceKm: Double = 0
    var program: CustomProgram?

    init(orderIndex: Int, name: String, durationSeconds: Int,
         targetSpeedKmh: Double, targetIncline: Int) {
        self.uuid = UUID()
        self.orderIndex = orderIndex
        self.name = name
        self.durationSeconds = durationSeconds
        self.targetSpeedKmh = targetSpeedKmh
        self.targetIncline = targetIncline
    }

    /// The segment's goal, assembled from the stored discriminator and payload.
    /// A kind this build does not know — a record written by a newer one — reads
    /// as a time goal instead of trapping, so the program stays openable.
    var goal: SegmentGoal {
        get {
            switch SegmentGoal.Kind(rawValue: goalKindRaw) ?? .time {
            case .distance where goalDistanceKm > 0:
                return .distance(km: goalDistanceKm)
            case .time, .distance, .untilHeartRateBelow:
                // A distance goal without a distance would finish the instant it
                // starts; the heart-rate goal's own columns arrive with
                // heart-rate control, until then the stored duration is its cap.
                return .time(seconds: durationSeconds)
            }
        }
        set {
            switch newValue {
            case .time(let seconds):
                goalKindRaw = SegmentGoal.Kind.time.rawValue
                durationSeconds = seconds
                goalDistanceKm = 0
            case .distance(let km):
                goalKindRaw = SegmentGoal.Kind.distance.rawValue
                goalDistanceKm = km
                durationSeconds = plannedDurationSeconds
            case .untilHeartRateBelow(_, let maxSeconds):
                // There is no column for the bpm yet, and a stored kind whose
                // payload is missing would read back as something else anyway:
                // the honest degradation is the time cap the getter would give.
                goalKindRaw = SegmentGoal.Kind.time.rawValue
                durationSeconds = maxSeconds
                goalDistanceKm = 0
            }
        }
    }

    /// The goal's kind, as the editor's segmented picker binds it. It exists so
    /// the editor never touches `goalKindRaw` itself: switching to a distance
    /// goal seeds the distance from what the segment would have covered anyway,
    /// instead of landing on a 0 km goal that would finish instantly.
    var goalKind: SegmentGoal.Kind {
        get { goal.kind }
        set {
            switch newValue {
            case .distance:
                goal = .distance(km: goalDistanceKm > 0 ? goalDistanceKm : seededGoalDistanceKm)
            case .time, .untilHeartRateBelow:
                // There is no editor for the heart-rate goal yet — see `goal`.
                goal = .time(seconds: seededGoalDurationSeconds)
            }
        }
    }

    /// The planned distance, snapped to the editor's step and kept inside its
    /// range.
    private var seededGoalDistanceKm: Double {
        let km = asWorkoutSegment.plannedDistanceKm
        let step = WorkoutSegment.goalDistanceStepKm
        let range = WorkoutSegment.goalDistanceRangeKm
        guard km.isFinite, km > range.lowerBound else { return range.lowerBound }
        return min((km / step).rounded() * step, range.upperBound)
    }

    /// The stored planned-duration mirror, snapped to the editor's 15 s step
    /// and kept inside its range. Mirrors `seededGoalDistanceKm`: switching to
    /// Time must never seed a value the editor's own Stepper cannot represent
    /// — a 12 km @ 5 km/h mirror is 8640 s, entirely outside the 15...7200 s
    /// the Stepper allows, and a mirror like 2571 s falls inside the range
    /// but off its 15 s grid.
    private var seededGoalDurationSeconds: Int {
        let step = WorkoutSegment.goalDurationStepSeconds
        let range = WorkoutSegment.goalDurationRangeSeconds
        let snapped = Int((Double(durationSeconds) / Double(step)).rounded()) * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    /// Runnable form. The identifier is the stored uuid so the dashboard
    /// picker's selection stays stable across re-conversion.
    var asWorkoutSegment: WorkoutSegment {
        WorkoutSegment(id: uuid, name: name, goal: goal,
                       targetSpeedKmh: targetSpeedKmh, targetIncline: targetIncline)
    }

    var plannedDurationSeconds: Int {
        asWorkoutSegment.plannedDurationSeconds
    }

    /// Rewrites the stored planned duration from the goal and the target speed.
    /// The editor has to call this after changing the speed or the distance of a
    /// distance-goal segment: for those `durationSeconds` is a derived mirror.
    func refreshPlannedDuration() {
        guard case .distance = goal else { return }
        durationSeconds = plannedDurationSeconds
    }
}
