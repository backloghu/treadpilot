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

    var totalSeconds: Int {
        segments.reduce(0) { $0 + $1.durationSeconds }
    }

    /// Conversion into runnable form. The identifiers are the stored uuids, so
    /// the dashboard picker's selection stays stable across re-conversion.
    var asWorkoutProgram: WorkoutProgram {
        WorkoutProgram(
            id: uuid,
            name: name,
            segments: sortedSegments.map { segment in
                WorkoutSegment(
                    id: segment.uuid,
                    name: segment.name,
                    duration: TimeInterval(segment.durationSeconds),
                    targetSpeedKmh: segment.targetSpeedKmh,
                    targetIncline: segment.targetIncline
                )
            }
        )
    }

    /// Copying a built-in or another program into a custom one.
    static func copy(of program: WorkoutProgram, name: String) -> CustomProgram {
        let custom = CustomProgram(name: name)
        for (index, segment) in program.segments.enumerated() {
            let record = CustomSegmentRecord(
                orderIndex: index,
                name: segment.name,
                durationSeconds: Int(segment.duration),
                targetSpeedKmh: segment.targetSpeedKmh,
                targetIncline: segment.targetIncline
            )
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
    var durationSeconds: Int
    var targetSpeedKmh: Double
    var targetIncline: Int
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
}
