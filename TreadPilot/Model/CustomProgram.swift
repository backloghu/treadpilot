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
            let record = CustomSegmentRecord.copying(segment, orderIndex: index)
            record.program = custom
            custom.segments.append(record)
        }
        return custom
    }

    /// Duplicating one of this program's own segments, in place.
    ///
    /// Finding 86: `ProgramEditorView.duplicate(_:)` used to assemble the copy by
    /// hand a second time — the same call site finding 71 fixed once already —
    /// and it is also the wrong layer for it: a unit test that wants to exercise
    /// duplication has to construct a `View` with no `ModelContext` in its
    /// environment to call it, which resolves to a default with no container
    /// behind it and may trap or silently discard rather than assert. Moved here,
    /// a test constructs the two `@Model` objects directly and calls this. The
    /// view is left doing only the reindex and the save.
    ///
    /// Routes through `CustomSegmentRecord.copying(_:orderIndex:name:)` — the one
    /// place the assembly order (target before goal) lives — so a heart-rate
    /// segment's band, actuator, bounds and fallback survive the copy along with
    /// every goal kind.
    @discardableResult
    func duplicate(_ segment: CustomSegmentRecord) -> CustomSegmentRecord {
        let copy = CustomSegmentRecord.copying(
            segment.asWorkoutSegment,
            orderIndex: segment.orderIndex,
            name: segment.name + String(localized: " (copy)"))
        copy.program = self
        segments.append(copy)
        return copy
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
    /// The fixed target — and, for a heart-rate target, its start command. One
    /// pair of columns for both, which is what makes surrendering control (opt-in
    /// off, unusable payload) a read rather than a migration.
    var targetSpeedKmh: Double
    var targetIncline: Int
    // Both axes. New properties with default values are a lightweight SwiftData
    // migration — no VersionedSchema needed; the precedent is
    // WorkoutSampleRecord.timestamp.
    var goalKindRaw: String = SegmentGoal.Kind.time.rawValue
    var goalDistanceKm: Double = 0
    var goalHeartRateBelow: Int = 0
    var goalMaxSeconds: Int = 0
    var targetKindRaw: String = SegmentTarget.Kind.fixed.rawValue
    var hrLowBpm: Int = 0
    var hrHighBpm: Int = 0
    var hrActuatorRaw: String = HeartRateActuator.speed.rawValue
    var hrMinSpeedKmh: Double = 0
    var hrMaxSpeedKmh: Double = 0
    var hrMinIncline: Int = 0
    var hrMaxIncline: Int = 0
    var hrFallbackSpeedKmh: Double = 0
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
            case .untilHeartRateBelow where goalHeartRateBelow > 0 && goalMaxSeconds > 0:
                // Repaired rather than trusted: an implausible threshold degrades
                // to the plain time goal of the cap, as a failed sensor does.
                return WorkoutSegment.repaired(
                    .untilHeartRateBelow(bpm: goalHeartRateBelow, maxSeconds: goalMaxSeconds))
            case .time, .distance, .untilHeartRateBelow:
                // A distance goal without a distance would finish the instant it
                // starts, and a recovery goal without a threshold or without its
                // mandatory cap is not one: both read as the stored duration.
                return .time(seconds: durationSeconds)
            }
        }
        set {
            switch WorkoutSegment.repaired(newValue) {
            case .time(let seconds):
                goalKindRaw = SegmentGoal.Kind.time.rawValue
                durationSeconds = seconds
                goalDistanceKm = 0
            case .distance(let km):
                goalKindRaw = SegmentGoal.Kind.distance.rawValue
                goalDistanceKm = km
                durationSeconds = plannedDurationSeconds
            case .untilHeartRateBelow(let bpm, let maxSeconds):
                goalKindRaw = SegmentGoal.Kind.untilHeartRateBelow.rawValue
                goalHeartRateBelow = bpm
                goalMaxSeconds = maxSeconds
                goalDistanceKm = 0
                durationSeconds = maxSeconds
                // The walking-target rule, at the moment of storage: a recovery
                // segment cannot be stored with a standing belt.
                target = target.withStartSpeedFloor(WorkoutSegment.recoveryMinSpeedKmh)
            }
        }
    }

    /// The heart-rate columns as stored, unchecked. `target` and `targetKind`
    /// apply the two different checks they each need to it.
    private var storedHeartRateTarget: HeartRateTarget {
        HeartRateTarget(lowBpm: hrLowBpm, highBpm: hrHighBpm, actuator: hrActuator,
                        startSpeedKmh: targetSpeedKmh, startIncline: targetIncline,
                        minSpeedKmh: hrMinSpeedKmh, maxSpeedKmh: hrMaxSpeedKmh,
                        minIncline: hrMinIncline, maxIncline: hrMaxIncline,
                        fallbackSpeedKmh: hrFallbackSpeedKmh)
    }

    /// The segment's target, assembled from the stored discriminator and payload.
    /// A kind this build does not know, and a heart-rate payload that is missing
    /// or degenerate, both read as a fixed segment at the start command instead of
    /// trapping — which is also exactly what the opt-in-off case needs.
    var target: SegmentTarget {
        get {
            let fixed = SegmentTarget.fixed(speedKmh: targetSpeedKmh, incline: targetIncline)
            switch SegmentTarget.Kind(rawValue: targetKindRaw) ?? .fixed {
            case .fixed:
                return fixed
            case .heartRate:
                let heartRate = storedHeartRateTarget
                return heartRate.isUsable ? .heartRate(heartRate) : fixed
            }
        }
        set {
            targetKindRaw = newValue.kind.rawValue
            targetSpeedKmh = newValue.startSpeedKmh
            targetIncline = newValue.startIncline
            // The heart-rate columns are deliberately not cleared for a fixed
            // target: the discriminator decides which of them is read, so a band
            // the user typed survives a trip through the Fixed tab.
            guard let heartRate = newValue.heartRate else { return }
            hrLowBpm = heartRate.lowBpm
            hrHighBpm = heartRate.highBpm
            hrActuatorRaw = heartRate.actuator.rawValue
            hrMinSpeedKmh = heartRate.minSpeedKmh
            hrMaxSpeedKmh = heartRate.maxSpeedKmh
            hrMinIncline = heartRate.minIncline
            hrMaxIncline = heartRate.maxIncline
            hrFallbackSpeedKmh = heartRate.fallbackSpeedKmh
        }
    }

    /// The target's kind, as the editor's segmented picker binds it — the mirror
    /// of `goalKind`, for the same reason: switching to Heart rate must seed a
    /// payload the editor can represent, not land on all-zero columns.
    var targetKind: SegmentTarget.Kind {
        get { target.kind }
        set {
            switch newValue {
            case .fixed:
                target = .fixed(speedKmh: targetSpeedKmh, incline: targetIncline)
            case .heartRate:
                target = .heartRate(storedHeartRateTarget.repairedForEditing)
            }
        }
    }

    /// The actuated axis, typed. The editor binds this rather than the raw
    /// string; an unknown stored value reads as speed, the safe default.
    var hrActuator: HeartRateActuator {
        get { HeartRateActuator(rawValue: hrActuatorRaw) ?? .speed }
        set { hrActuatorRaw = newValue.rawValue }
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
            case .untilHeartRateBelow:
                goal = .untilHeartRateBelow(bpm: seededGoalHeartRateBelowBpm,
                                            maxSeconds: seededGoalDurationSeconds)
            case .time:
                goal = .time(seconds: seededGoalDurationSeconds)
            }
        }
    }

    /// The recovery threshold, kept inside the editor's range. Same rule as the
    /// two seeds below: a value the editor's own Stepper cannot represent leaves
    /// the user unable to walk it back.
    private var seededGoalHeartRateBelowBpm: Int {
        WorkoutSegment.goalHeartRateBelowRangeBpm.contains(goalHeartRateBelow)
            ? goalHeartRateBelow
            : WorkoutSegment.defaultGoalHeartRateBelowBpm
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
        WorkoutSegment(id: uuid, name: name, goal: goal, target: target)
    }

    var plannedDurationSeconds: Int {
        asWorkoutSegment.plannedDurationSeconds
    }

    /// Rewrites the stored planned duration from the goal and the target speed.
    /// The editor has to call this after changing the speed or the distance of a
    /// distance-goal segment, and after changing a recovery goal's cap: for both
    /// `durationSeconds` is a derived mirror.
    func refreshPlannedDuration() {
        switch goal {
        case .time:
            return
        case .distance, .untilHeartRateBelow:
            durationSeconds = plannedDurationSeconds
        }
    }

    /// A record carrying every axis of `segment`. Both duplication paths forgot
    /// the goal axis in phase 1 and one of them shipped the bug, so the assembly
    /// order lives here once: target before goal, because a distance goal derives
    /// its stored planned duration from the target speed.
    static func copying(_ segment: WorkoutSegment, orderIndex: Int,
                        name: String? = nil) -> CustomSegmentRecord {
        let record = CustomSegmentRecord(orderIndex: orderIndex,
                                         name: name ?? segment.name,
                                         durationSeconds: segment.plannedDurationSeconds,
                                         targetSpeedKmh: segment.nominalSpeedKmh,
                                         targetIncline: segment.nominalIncline)
        record.target = segment.target
        record.goal = segment.goal
        return record
    }
}
