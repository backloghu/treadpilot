// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import XCTest
@testable import TreadPilot

/// What a cold launch is allowed to believe about the user's heart rate. The
/// store reads Health only when the profile screen asks it to (the permission
/// sheet may not precede the disclaimer), so everything a first launch zones
/// against comes out of these keys.
@MainActor
final class ProfileStoreTests: XCTestCase {

    private let keys = ["profile.age", "profile.maxHeartRate", "profile.restingHeartRate",
                        "health.age", "health.maxHeartRate", "health.restingHeartRate",
                        "health.weight", "health.height", "health.isMale"]

    override func setUp() {
        super.setUp()
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    override func tearDown() {
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        super.tearDown()
    }

    func testAColdLaunchZonesAgainstTheLastKnownHealthValues() {
        // A trained user: Health says the resting rate is 48, and no override
        // exists. Before the values were persisted, this launch used the 60 bpm
        // fallback until the profile screen was opened.
        UserDefaults.standard.set(48, forKey: "health.restingHeartRate")
        UserDefaults.standard.set(40, forKey: "health.age")

        let store = ProfileStore()
        XCTAssertEqual(store.healthRestingHeartRate, 48)
        XCTAssertEqual(store.effectiveRestingHeartRate, 48)
        XCTAssertEqual(store.resolvedRestingHeartRate.source, .health)
        // Age from Health too, so the maximum is 220 − 40.
        XCTAssertEqual(store.effectiveMaxHeartRate, 180)

        // Resting 48 / max 180 → reserve 132: Z3 starts at 48 + 0.7 × 132 =
        // 140.4 → 140. On the 60 bpm fallback Z3 would start at 144, so 141 bpm
        // is exactly where the two bases disagree.
        XCTAssertEqual(store.heartRateZones?.zone(for: 141), .three)
        XCTAssertEqual(HeartRateZones(restingBpm: 60, maxBpm: 180)?.zone(for: 141), .two)
    }

    func testAColdLaunchWithNoStoredHealthValuesUsesTheDocumentedFallbacks() {
        let store = ProfileStore()
        XCTAssertNil(store.healthRestingHeartRate)
        XCTAssertEqual(store.effectiveRestingHeartRate, HeartRateZones.fallbackRestingBpm)
        XCTAssertEqual(store.resolvedRestingHeartRate.source, .fallback)
        XCTAssertEqual(store.resolvedMaxHeartRate.source, .ageFormula)
    }

    func testAnOverrideStillWinsOverAStoredHealthValue() {
        UserDefaults.standard.set(48, forKey: "health.restingHeartRate")
        UserDefaults.standard.set(190, forKey: "health.maxHeartRate")
        UserDefaults.standard.set(55, forKey: "profile.restingHeartRate")
        UserDefaults.standard.set(200, forKey: "profile.maxHeartRate")

        let store = ProfileStore()
        XCTAssertEqual(store.effectiveRestingHeartRate, 55)
        XCTAssertEqual(store.resolvedRestingHeartRate.source, .userOverride)
        XCTAssertEqual(store.effectiveMaxHeartRate, 200)
        XCTAssertEqual(store.resolvedMaxHeartRate.source, .userOverride)
    }

    func testAStoredObservedMaximumRaisesTheAgeEstimateWithinTheLimit() {
        // What refreshFromHealthKit stores is already corroborated across days;
        // this is the wiring from there to the zone boundaries.
        UserDefaults.standard.set(40, forKey: "health.age")
        UserDefaults.standard.set(196, forKey: "health.maxHeartRate")

        let store = ProfileStore()
        XCTAssertEqual(store.effectiveMaxHeartRate, 196)
        XCTAssertEqual(store.resolvedMaxHeartRate.source, .healthObserved)
    }

    func testAnObservedMaximumBelowTheFormulaIsSurfacedAsContradictingEvidence() {
        // A 55-year-old on a beta-blocker: Health holds a year of workouts
        // topping out at 118 bpm. The formula's 165 stands — an observed rate is
        // a lower bound — but the profile has to say that Health disagrees
        // instead of printing "default — no Health data".
        UserDefaults.standard.set(55, forKey: "health.age")
        UserDefaults.standard.set(118, forKey: "health.maxHeartRate")

        let store = ProfileStore()
        XCTAssertEqual(store.healthMaxHeartRate, 118)
        XCTAssertEqual(store.effectiveMaxHeartRate, 165)
        XCTAssertEqual(store.resolvedMaxHeartRate.source, .ageFormula)
        XCTAssertEqual(store.healthMaxHeartRateContradictingEstimate, 118)
    }

    func testHealthEvidenceAboveTheEstimateContradictsNothingAndNeitherDoesAnOverride() {
        UserDefaults.standard.set(40, forKey: "health.age")
        UserDefaults.standard.set(196, forKey: "health.maxHeartRate")
        let adopted = ProfileStore()
        // Adopted, so there is nothing to argue with.
        XCTAssertNil(adopted.healthMaxHeartRateContradictingEstimate)

        // An override is a decision, not an estimate: 118 does not contradict it.
        UserDefaults.standard.set(118, forKey: "health.maxHeartRate")
        UserDefaults.standard.set(150, forKey: "profile.maxHeartRate")
        XCTAssertNil(ProfileStore().healthMaxHeartRateContradictingEstimate)
    }

    func testTheZoneBasisIsFrozenWhileAWorkoutRecords() {
        // Age 40 → 220 − 40 = 180, resting from the 60 bpm fallback.
        UserDefaults.standard.set(40, forKey: "health.age")
        let store = ProfileStore()
        let recorder = SessionRecorder()
        recorder.heartRateBasisProvider = { [weak store] in store?.heartRateBasis }

        // Nothing recording: the readers see the live basis.
        XCTAssertNil(recorder.heartRateBasis)
        XCTAssertEqual(recorder.activeHeartRateZones, store.heartRateZones)

        recorder.freezeHeartRateBasis()
        XCTAssertEqual(recorder.heartRateBasis, HeartRateBasis(restingBpm: 60, maxBpm: 180))
        XCTAssertEqual(recorder.activeHeartRateZones?.zone(for: 145), .three)
    }

    func testAnOverrideEditMidWorkoutCannotMoveTheRunningWorkoutsBasis() {
        // The reproduction: the user opens Profile mid-run and taps the maximum
        // stepper. The chip jumped Z3 → Z2 and, in phase 3, the force-down and
        // stop ceilings would have moved under a governor steering the belt.
        UserDefaults.standard.set(40, forKey: "health.age")
        let store = ProfileStore()
        let recorder = SessionRecorder()
        recorder.heartRateBasisProvider = { [weak store] in store?.heartRateBasis }
        recorder.freezeHeartRateBasis()
        let frozen = recorder.heartRateBasis

        store.overrideMaxHeartRate = 200
        // The live basis moved: at 200 the Z3 floor is 60 + 0.7 × 140 = 158.
        XCTAssertEqual(store.heartRateZones?.zone(for: 145), .two)
        // The workout's did not.
        XCTAssertEqual(recorder.heartRateBasis, frozen)
        XCTAssertEqual(recorder.activeHeartRateZones?.zone(for: 145), .three)

        // Released with the session, so the next workout starts from the edit.
        recorder.releaseHeartRateBasis()
        XCTAssertEqual(recorder.activeHeartRateZones, store.heartRateZones)
        XCTAssertEqual(recorder.activeHeartRateZones?.zone(for: 145), .two)
    }
}
