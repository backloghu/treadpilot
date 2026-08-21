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

    // MARK: - SegmentBandFit (finding 118, second round)

    /// The live holdable range for a profile, the way `SegmentEditorView` derives
    /// it — through the governor, so these tests move whenever the force-down
    /// ceiling does.
    private func holdable(maxBpm: Int, restingBpm: Int = 60) -> ClosedRange<Int> {
        HeartRateGovernor.holdableBandRangeBpm(
            for: HeartRateBasis(restingBpm: restingBpm, maxBpm: maxBpm))
    }

    private func heartRateSegment(lowBpm: Int, highBpm: Int) -> CustomSegmentRecord {
        let segment = CustomSegmentRecord(orderIndex: 0, name: "Zone 3",
                                          durationSeconds: 600,
                                          targetSpeedKmh: 6.0, targetIncline: 1)
        var target = heartRateTarget()
        target.lowBpm = lowBpm
        target.highBpm = highBpm
        segment.target = .heartRate(target)
        return segment
    }

    func testABandThatStillFitsTheBasisAsksForNothingAndSaysNothing() {
        // 144–155 against a maximum of 200: the force-down ceiling is 184, so the
        // band is holdable and the notice must not appear at all. nil is both the
        // "no adjustment" answer and the notice's own visibility condition.
        XCTAssertNil(SegmentBandFit.adjustment(forStoredLowBpm: 144, highBpm: 155,
                                               holdable: holdable(maxBpm: 200)))
    }

    func testTheBetaBlockerCaseOffersAnAdjustmentInsteadOfPerformingOne() {
        // The failure this replaces: a 150–165 segment built while the maximum
        // resolved to 200, then a 130 bpm override typed into the profile (the
        // beta-blocker correction spec section 4 asks the profile to prompt for).
        // Force-down is 120, so the holdable band tops out at 119 and the stored
        // band no longer fits.
        let holdable = holdable(maxBpm: 130)
        XCTAssertEqual(holdable, 60...119)

        let segment = heartRateSegment(lowBpm: 150, highBpm: 165)
        let adjustment = SegmentBandFit.adjustment(forStoredLowBpm: segment.hrLowBpm,
                                                   highBpm: segment.hrHighBpm,
                                                   holdable: holdable)
        XCTAssertEqual(adjustment, 114...119, "what the profile could hold instead")
        // The whole point of the ruling: asking the question changes nothing. The
        // stored plan is still the user's own until they tap the adjustment.
        XCTAssertEqual(segment.hrLowBpm, 150)
        XCTAssertEqual(segment.hrHighBpm, 165)
    }

    func testTheUnchangedBandIsStillRefusedAtRunTimeSoNothingIsLostByAsking() {
        // Why persisting the repair was never a safety requirement: the runner
        // arbitrates the *stored* band against the frozen basis, and a band whose
        // lower edge is at or above the force-down ceiling is not steered at all —
        // the segment runs fixed and the dashboard says so ("Band not reachable —
        // running fixed"). Leaving the plan alone leaves the user informed, not
        // exposed.
        var target = heartRateTarget()
        target.lowBpm = 150
        target.highBpm = 165
        let basis = HeartRateBasis(restingBpm: 60, maxBpm: 130)
        XCTAssertEqual(HeartRateGovernor.arbitration(for: target, basis: basis), .notSteerable)
    }

    func testOnlyTheEdgeThatNoLongerFitsIsMovedByTheOfferedAdjustment() {
        // The adjustment widens downward, never upward: the lower edge the user
        // set survives whenever it can, because the upper edge is the one that
        // costs effort (`HeartRateTarget.repairedBand`'s own rule).
        let adjustment = SegmentBandFit.adjustment(forStoredLowBpm: 100, highBpm: 125,
                                                   holdable: holdable(maxBpm: 130))
        XCTAssertEqual(adjustment, 100...119)
    }

    func testAStoredPairInTheWrongOrderIsNotReportedAsUnholdable() {
        // The governor normalises the pair itself (`HeartRateGovernor.band(for:)`),
        // so an inverted band is not an unholdable one — and a notice about it
        // would be a notice about a problem the loop does not have.
        XCTAssertNil(SegmentBandFit.adjustment(forStoredLowBpm: 155, highBpm: 144,
                                               holdable: holdable(maxBpm: 200)))
    }

    func testEveryOfferedAdjustmentIsItselfHoldableAndWideEnoughToHold() {
        // Whatever the basis, tapping the offer must not produce a second
        // unholdable band, and must not produce one narrower than the loop can
        // hold (one 0.2 km/h step moves the steady state by roughly 2 bpm).
        for maxBpm in [100, 120, 130, 150, 175, 200, 220] {
            let range = holdable(maxBpm: maxBpm)
            guard let adjustment = SegmentBandFit.adjustment(forStoredLowBpm: 150, highBpm: 165,
                                                            holdable: range) else { continue }
            XCTAssertGreaterThanOrEqual(adjustment.lowerBound, range.lowerBound, "max \(maxBpm)")
            XCTAssertLessThanOrEqual(adjustment.upperBound, range.upperBound, "max \(maxBpm)")
            XCTAssertGreaterThanOrEqual(adjustment.upperBound - adjustment.lowerBound,
                                        HeartRateTarget.minBandWidthBpm, "max \(maxBpm)")
            XCTAssertNil(SegmentBandFit.adjustment(forStoredLowBpm: adjustment.lowerBound,
                                                   highBpm: adjustment.upperBound,
                                                   holdable: range),
                         "the adjustment must be a fixed point: max \(maxBpm)")
        }
    }
}
