// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import XCTest
@testable import TreadPilot

/// `CustomProgram.duplicate(_:)`, the segment-duplication path
/// `ProgramEditorView`'s context menu calls. Finding 71: the call site used to
/// assemble the copy by hand and copied only the fixed-target columns, so
/// duplicating a heart-rate segment silently produced a plain fixed segment —
/// the band, the actuator, the bounds and the fallback were all gone, with
/// nothing saying so. Finding 86: the fix moved the *assembly* into
/// `CustomSegmentRecord.copying`, but the call site was still assembled a
/// second time inside the view, and the tests for it constructed a `View` and
/// called a method that reads `@Environment(\.modelContext)` outside any view
/// hierarchy — which resolves to a default with no container behind it, so the
/// test could trap or silently discard rather than assert. Duplication is a
/// model operation now: these tests build the two `@Model` objects directly and
/// call `CustomProgram.duplicate(_:)`, with no `View` and no environment in
/// sight. `ProgramEditorView`'s own `duplicate(_:)` is left doing only the
/// reindex and the save, which needs no test of its own beyond what
/// `move`/`delete` already cover for reindexing.
final class ProgramEditorViewTests: XCTestCase {

    private func heartRateTarget() -> HeartRateTarget {
        HeartRateTarget(lowBpm: 144, highBpm: 155, actuator: .speed,
                        startSpeedKmh: 6.0, startIncline: 1,
                        minSpeedKmh: 4.0, maxSpeedKmh: 10.0,
                        minIncline: 0, maxIncline: 4,
                        fallbackSpeedKmh: 4.5)
    }

    func testDuplicatingAHeartRateSegmentPreservesItsTarget() {
        let program = CustomProgram(name: "Program")
        let segment = CustomSegmentRecord(orderIndex: 0, name: "Zone 3",
                                          durationSeconds: 600,
                                          targetSpeedKmh: 6.0, targetIncline: 1)
        segment.target = .heartRate(heartRateTarget())
        segment.program = program
        program.segments.append(segment)

        let copy = program.duplicate(segment)

        let segments = program.sortedSegments
        XCTAssertEqual(segments.count, 2)
        XCTAssertTrue(segments.contains(where: { $0 === copy }))
        XCTAssertEqual(copy.name, "Zone 3" + String(localized: " (copy)"))
        XCTAssertNotEqual(copy.uuid, segment.uuid, "a real second segment, not the same record")
        XCTAssertEqual(copy.target, .heartRate(heartRateTarget()))
        XCTAssertEqual(copy.goal, segment.goal)
        XCTAssertTrue(copy.asWorkoutSegment.isHeartRateDriven)
        XCTAssertEqual(copy.asWorkoutSegment.heartRateTarget, heartRateTarget())
    }

    func testDuplicatingADistanceGoalSegmentStillCarriesBothAxes() {
        // The other half of finding 71's history: a distance goal reverted to
        // a time goal through this same call site before phase 1 fixed
        // `CustomProgram.copy(of:)` and this one was left behind.
        let program = CustomProgram(name: "Program")
        let segment = CustomSegmentRecord(orderIndex: 2, name: "Long run",
                                          durationSeconds: 0,
                                          targetSpeedKmh: 9.0, targetIncline: 0)
        segment.goal = .distance(km: 5.0)
        segment.program = program
        program.segments.append(segment)

        let copy = program.duplicate(segment)

        XCTAssertEqual(copy.goal, .distance(km: 5.0))
        XCTAssertEqual(copy.targetSpeedKmh, 9.0)
    }

    func testDuplicatingAppendsWithoutDisturbingTheOriginalsOrderIndex() {
        let program = CustomProgram(name: "Program")
        let first = CustomSegmentRecord(orderIndex: 0, name: "First",
                                        durationSeconds: 120,
                                        targetSpeedKmh: 5.0, targetIncline: 0)
        first.program = program
        program.segments.append(first)

        let copy = program.duplicate(first)

        // The reindex after a real duplication is the editor's own job
        // (`reindex(program.sortedSegments)`, unit-tested by the move/delete
        // paths already) — this asserts only what the model call itself
        // guarantees: a second, distinct record carrying the copy's name,
        // with the original untouched.
        XCTAssertEqual(program.segments.count, 2)
        XCTAssertEqual(first.orderIndex, 0, "the original is not renumbered by duplicating it")
        XCTAssertEqual(copy.orderIndex, first.orderIndex, "copying carries the source's own index — the caller reindexes")
        XCTAssertEqual(copy.name, "First" + String(localized: " (copy)"))
    }
}
