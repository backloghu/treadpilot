// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import XCTest
@testable import TreadPilot

/// `TargetBandChart.runs(in:)`, the pure grouping behind the band
/// `SessionDetailView` draws behind the heart-rate chart (spec section 4,
/// "Recording and review", finding 115).
final class HistoryViewTests: XCTestCase {

    private func sample(_ offsetSeconds: Int, low: Int = 0, high: Int = 0) -> WorkoutSampleRecord {
        WorkoutSampleRecord(offsetSeconds: offsetSeconds, speedKmh: 8.0, inclinePercent: 0,
                            heartRate: 150, distanceKm: 0, targetHrLow: low, targetHrHigh: high)
    }

    func testAWorkoutThatWasNeverGovernedProducesNoRunsAtAll() {
        let samples = (1...5).map { sample($0) }
        XCTAssertTrue(TargetBandChart.runs(in: samples).isEmpty)
    }

    func testAWhollyGovernedWorkoutIsOneRunSpanningIt() {
        let samples = (1...5).map { sample($0, low: 144, high: 155) }
        let runs = TargetBandChart.runs(in: samples)
        XCTAssertEqual(runs, [TargetBandRun(startOffsetSeconds: 1, endOffsetSeconds: 5,
                                            lowBpm: 144, highBpm: 155)])
    }

    func testAFixedSegmentInTheMiddleSplitsTheRunInTwoRatherThanBridgingIt() {
        // A mixed program: governed, then a plain segment, then governed again.
        // The gap must be a real gap, not a line drawn straight across it.
        let samples = [sample(1, low: 144, high: 155), sample(2, low: 144, high: 155),
                       sample(3), sample(4),
                       sample(5, low: 144, high: 155)]
        let runs = TargetBandChart.runs(in: samples)
        XCTAssertEqual(runs, [
            TargetBandRun(startOffsetSeconds: 1, endOffsetSeconds: 2, lowBpm: 144, highBpm: 155),
            TargetBandRun(startOffsetSeconds: 5, endOffsetSeconds: 5, lowBpm: 144, highBpm: 155),
        ])
    }

    func testABandChangeAtASegmentBoundarySplitsTheRunEvenWithNoGap() {
        // Segment 1's zone-2 band hands straight to segment 2's zone-3 band with
        // no ungoverned second in between; the run still has to split, because
        // a single rectangle spanning both would draw the wrong band for half
        // of it.
        let samples = [sample(1, low: 120, high: 132), sample(2, low: 120, high: 132),
                       sample(3, low: 144, high: 155), sample(4, low: 144, high: 155)]
        let runs = TargetBandChart.runs(in: samples)
        XCTAssertEqual(runs, [
            TargetBandRun(startOffsetSeconds: 1, endOffsetSeconds: 2, lowBpm: 120, highBpm: 132),
            TargetBandRun(startOffsetSeconds: 3, endOffsetSeconds: 4, lowBpm: 144, highBpm: 155),
        ])
    }
}
