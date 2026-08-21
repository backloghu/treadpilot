// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import SwiftData
import XCTest
@testable import TreadPilot

/// Finding 73: the seeded heart-rate program, exercised through the same
/// `SampleData.seed(into:)` the `-seedSampleData` launch flag calls — not a
/// hand-built stand-in for it, so a change to the seeding function itself is
/// what this test actually watches.
final class SampleDataTests: XCTestCase {

    /// Values `testSeedDefaultsWritesTheVersionedDisclaimerKeyAndTheHeartRateOptIn`
    /// overwrote in the shared `UserDefaults.standard`, restored in `tearDown()`
    /// — a plain stored property rather than `addTeardownBlock`, whose closure
    /// would have to send `UserDefaults`/`Any?` across an isolation boundary
    /// under this project's strict concurrency checking.
    private var priorDefaultsValues: [String: Any?] = [:]

    override func tearDown() {
        let defaults = UserDefaults.standard
        for (key, value) in priorDefaultsValues {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        priorDefaultsValues = [:]
        super.tearDown()
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: WorkoutSessionRecord.self, WorkoutSampleRecord.self,
            CustomProgram.self, CustomSegmentRecord.self,
            configurations: configuration)
        return ModelContext(container)
    }

    func testSeedingAddsAHeartRateProgramWithAGovernedZoneAndARecoverySegment() throws {
        let context = try makeContext()
        SampleData.seed(into: context)

        let programs = try context.fetch(FetchDescriptor<CustomProgram>())
        guard let hrProgram = programs.first(where: { $0.name == "Heart-rate zone" }) else {
            return XCTFail("expected a seeded heart-rate program")
        }
        let segments = hrProgram.sortedSegments
        XCTAssertEqual(segments.count, 3)

        XCTAssertFalse(segments[0].asWorkoutSegment.isHeartRateDriven, "the warm-up is fixed")

        guard let zoneTarget = segments[1].target.heartRate else {
            return XCTFail("expected the second segment to carry a heart-rate target")
        }
        // isUsable, not merely non-nil: an unusable payload reads back as a
        // fixed target from `target`'s own getter, so this is the honest check.
        XCTAssertTrue(zoneTarget.isUsable, "the editor could not represent an unusable seed")
        XCTAssertGreaterThan(zoneTarget.maxSpeedKmh, zoneTarget.minSpeedKmh,
                             "a real, if modest, speed corridor")

        guard case .untilHeartRateBelow(let bpm, let maxSeconds) = segments[2].goal else {
            return XCTFail("expected the third segment to be a recovery goal, got \(segments[2].goal)")
        }
        XCTAssertTrue(WorkoutSegment.goalHeartRateBelowRangeBpm.contains(bpm))
        XCTAssertGreaterThan(maxSeconds, 0, "the mandatory time cap")
        XCTAssertGreaterThan(segments[2].targetSpeedKmh, 0, "a recovery segment always walks")
    }

    /// `SampleData.seed` wipes before it inserts — a second run (the flag can
    /// be passed on any launch) must not pile up a second copy.
    func testSeedingTwiceDoesNotDuplicateTheHeartRateProgram() throws {
        let context = try makeContext()
        SampleData.seed(into: context)
        SampleData.seed(into: context)

        let programs = try context.fetch(FetchDescriptor<CustomProgram>())
        XCTAssertEqual(programs.filter { $0.name == "Heart-rate zone" }.count, 1)
    }

    /// Regression for the retired `disclaimer.accepted` key (no reader left):
    /// `seedDefaults()` must write the versioned key `ContentView` actually
    /// gates on, so this fails the moment `DisclaimerView.currentVersion` is
    /// bumped again without updating the seeder, or the key is renamed.
    func testSeedDefaultsWritesTheVersionedDisclaimerKeyAndTheHeartRateOptIn() throws {
        let defaults = UserDefaults.standard
        let keys = ["disclaimer.acceptedVersion", ProgramRunner.heartRateControlDefaultsKey,
                    "heartRateControl.confirmedOnce"]
        for key in keys {
            priorDefaultsValues[key] = defaults.object(forKey: key)
            defaults.removeObject(forKey: key)
        }

        SampleData.seedDefaults()

        XCTAssertEqual(defaults.integer(forKey: "disclaimer.acceptedVersion"),
                       DisclaimerView.currentVersion)
        XCTAssertTrue(defaults.bool(forKey: ProgramRunner.heartRateControlDefaultsKey),
                      "a seeded run must start with the capability already on")
        XCTAssertTrue(defaults.bool(forKey: "heartRateControl.confirmedOnce"),
                      "the one-time confirmation must already be latched, or the toggle dialog blocks the screenshot flow")
    }

    /// Spec section 4's history band overlay needs at least one seeded
    /// workout whose samples carry a real target band; every other seeded
    /// workout must stay at the untouched 0/0 default so the chart does not
    /// draw a band where none was ever governed.
    func testExactlyOneSeededWorkoutCarriesAHeartRateTargetBand() throws {
        let context = try makeContext()
        SampleData.seed(into: context)

        let sessions = try context.fetch(FetchDescriptor<WorkoutSessionRecord>())
        let sessionsWithABand = sessions.filter { session in
            session.sortedSamples.contains { $0.hasTargetHeartRateBand }
        }
        XCTAssertEqual(sessionsWithABand.count, 1)

        guard let bandedSession = sessionsWithABand.first else {
            return XCTFail("expected exactly one seeded workout with a target band")
        }
        let bandedSamples = bandedSession.sortedSamples.filter { $0.hasTargetHeartRateBand }
        XCTAssertFalse(bandedSamples.isEmpty)
        for sample in bandedSamples {
            XCTAssertGreaterThan(sample.targetHrHigh, sample.targetHrLow)
        }
    }
}
