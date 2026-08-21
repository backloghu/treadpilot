// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import XCTest
@testable import TreadPilot

final class HeartRateZonesTests: XCTestCase {

    // MARK: - HeartRateZone enum

    func testLowerReserveFractionsMatchTheSpecifiedBoundaries() {
        // The five boundaries the 1.1 specification fixes: 50/60/70/80/90% of reserve.
        XCTAssertEqual(HeartRateZone.one.lowerReserveFraction, 0.50)
        XCTAssertEqual(HeartRateZone.two.lowerReserveFraction, 0.60)
        XCTAssertEqual(HeartRateZone.three.lowerReserveFraction, 0.70)
        XCTAssertEqual(HeartRateZone.four.lowerReserveFraction, 0.80)
        XCTAssertEqual(HeartRateZone.five.lowerReserveFraction, 0.90)
    }

    func testShortLabelsAreTheUntranslatedZTokens() {
        XCTAssertEqual(HeartRateZone.one.shortLabel, "Z1")
        XCTAssertEqual(HeartRateZone.two.shortLabel, "Z2")
        XCTAssertEqual(HeartRateZone.three.shortLabel, "Z3")
        XCTAssertEqual(HeartRateZone.four.shortLabel, "Z4")
        XCTAssertEqual(HeartRateZone.five.shortLabel, "Z5")
    }

    func testEveryZoneChainsToTheNextExceptFive() {
        XCTAssertEqual(HeartRateZone.one.next, .two)
        XCTAssertEqual(HeartRateZone.two.next, .three)
        XCTAssertEqual(HeartRateZone.three.next, .four)
        XCTAssertEqual(HeartRateZone.four.next, .five)
        // Zone five is open-topped: a reading above the estimated maximum is
        // still the hardest zone, not "no zone".
        XCTAssertNil(HeartRateZone.five.next)
    }

    // MARK: - Zone boundaries (Karvonen), resting 60 / max 180 → reserve 120

    // Hand-computed once, reused by every test below:
    // Z1 = 60 + 0.50×120 = 120   Z2 = 60 + 0.60×120 = 132
    // Z3 = 60 + 0.70×120 = 144   Z4 = 60 + 0.80×120 = 156
    // Z5 = 60 + 0.90×120 = 168
    private let zones = HeartRateZones(restingBpm: 60, maxBpm: 180)!

    func testReserveBpmIsMaxMinusResting() {
        XCTAssertEqual(zones.reserveBpm, 120)
    }

    func testLowerBoundsForEveryZone() {
        XCTAssertEqual(zones.lowerBoundBpm(of: .one), 120)
        XCTAssertEqual(zones.lowerBoundBpm(of: .two), 132)
        XCTAssertEqual(zones.lowerBoundBpm(of: .three), 144)
        XCTAssertEqual(zones.lowerBoundBpm(of: .four), 156)
        XCTAssertEqual(zones.lowerBoundBpm(of: .five), 168)
    }

    func testDisplayBoundsAreInclusiveAndNonOverlapping() {
        // Every zone ends one beat below the next zone's floor; zone five has
        // no upper edge to print.
        let one = zones.boundsBpm(of: .one)
        XCTAssertEqual(one.lower, 120)
        XCTAssertEqual(one.upper, 131)
        let two = zones.boundsBpm(of: .two)
        XCTAssertEqual(two.lower, 132)
        XCTAssertEqual(two.upper, 143)
        let three = zones.boundsBpm(of: .three)
        XCTAssertEqual(three.lower, 144)
        XCTAssertEqual(three.upper, 155)
        let four = zones.boundsBpm(of: .four)
        XCTAssertEqual(four.lower, 156)
        XCTAssertEqual(four.upper, 167)
        let five = zones.boundsBpm(of: .five)
        XCTAssertEqual(five.lower, 168)
        XCTAssertNil(five.upper)
    }

    func testZoneOwnershipAtEveryBoundaryFromBelowAtAndAbove() {
        // Every listed boundary belongs to exactly one zone: the case just
        // below a floor is the previous zone (or nil, for zone one's floor),
        // the floor itself and the case just above both belong to that zone.
        let cases: [(bpm: Int, expected: HeartRateZone?, why: String)] = [
            (0, nil, "0 means \"no reading\" everywhere in this codebase"),
            (50, nil, "below resting itself, and far below zone one's floor"),
            (119, nil, "one beat below zone one's floor — genuinely outside the zones"),
            (120, .one, "zone one's floor, exactly"),
            (121, .one, "one beat above zone one's floor"),
            (131, .one, "top of zone one, one beat below zone two's floor"),
            (132, .two, "zone two's floor, exactly"),
            (143, .two, "top of zone two"),
            (144, .three, "zone three's floor, exactly"),
            (155, .three, "top of zone three"),
            (156, .four, "zone four's floor, exactly"),
            (167, .four, "top of zone four"),
            (168, .five, "zone five's floor, exactly"),
            (180, .five, "exactly at the estimated maximum"),
            (200, .five, "above the estimated maximum — zone five is open-topped"),
        ]
        for (bpm, expected, why) in cases {
            XCTAssertEqual(zones.zone(for: bpm), expected, why)
        }
    }

    func testHeartRateAtReserveFraction() {
        XCTAssertEqual(zones.heartRate(atReserveFraction: 0), 60)
        XCTAssertEqual(zones.heartRate(atReserveFraction: 0.5), 120)
        XCTAssertEqual(zones.heartRate(atReserveFraction: 1.0), 180)
        // 0.333 × 120 = 39.96, rounds to 40: exercises the rounding, not just
        // an exact multiple of the reserve.
        XCTAssertEqual(zones.heartRate(atReserveFraction: 0.333), 100)
        // Fractions above 1 are legal — the estimated maximum is not a ceiling
        // on the arithmetic, only on where the zones are drawn:
        // 7/6 × 120 = 140.0 → 60 + 140 = 200, matching the 200 bpm case above.
        XCTAssertEqual(zones.heartRate(atReserveFraction: 7.0 / 6.0), 200)
    }

    // MARK: - Failable init — degenerate profiles

    func testInitFailsWhenMaxEqualsResting() {
        // Zero reserve: dividing by it would be nonsense, so this must be nil,
        // not a clamp to some arbitrary zone.
        XCTAssertNil(HeartRateZones(restingBpm: 150, maxBpm: 150))
    }

    func testInitFailsWhenMaxIsBelowResting() {
        XCTAssertNil(HeartRateZones(restingBpm: 150, maxBpm: 120))
    }

    func testInitFailsWhenTheReserveIsOneBelowTheMinimum() {
        // 100…119 is a reserve of 19 bpm, one short of minimumReserveBpm (20).
        XCTAssertNil(HeartRateZones(restingBpm: 100, maxBpm: 119))
    }

    func testInitSucceedsAtExactlyTheMinimumReserve() {
        let boundary = HeartRateZones(restingBpm: 100, maxBpm: 120)
        XCTAssertNotNil(boundary)
        XCTAssertEqual(boundary?.reserveBpm, 20)
    }

    func testInitFailsForNonPositiveRestingRate() {
        XCTAssertNil(HeartRateZones(restingBpm: 0, maxBpm: 180))
        XCTAssertNil(HeartRateZones(restingBpm: -10, maxBpm: 180))
    }

    // MARK: - Resolution: maximum heart rate (override → Health-observed → 220 − age)

    func testResolvedMaxBpmOverrideWinsOutrightOverHealthAndFormula() {
        // Age 40 → formula 180; a Health value of 170 would otherwise be
        // irrelevant — the override must not even consult it.
        XCTAssertEqual(HeartRateZones.resolvedMax(age: 40, overrideBpm: 200, healthObservedBpm: 170).bpm, 200)
    }

    func testResolvedMaxBpmOverrideIsClampedToThePlausibleBand() {
        XCTAssertEqual(HeartRateZones.resolvedMax(age: 40, overrideBpm: 300, healthObservedBpm: nil).bpm, 230)
        XCTAssertEqual(HeartRateZones.resolvedMax(age: 40, overrideBpm: 50, healthObservedBpm: nil).bpm, 120)
        // The range's own edges need no clamping.
        XCTAssertEqual(HeartRateZones.resolvedMax(age: 40, overrideBpm: 120, healthObservedBpm: nil).bpm, 120)
        XCTAssertEqual(HeartRateZones.resolvedMax(age: 40, overrideBpm: 230, healthObservedBpm: nil).bpm, 230)
    }

    func testResolvedMaxBpmFallsBackToTheAgeFormulaWithNoOverrideOrHealthValue() {
        // 220 − 40 = 180.
        XCTAssertEqual(HeartRateZones.resolvedMax(age: 40, overrideBpm: nil, healthObservedBpm: nil).bpm, 180)
    }

    func testResolvedMaxBpmAcceptsAHealthObservedValueAtExactlyTheRaiseLimit() {
        // Age-based 180; 210 − 180 = 30 = observedMaxRaiseLimitBpm, inclusive.
        XCTAssertEqual(HeartRateZones.resolvedMax(age: 40, overrideBpm: nil, healthObservedBpm: 210).bpm, 210)
    }

    func testResolvedMaxBpmRejectsAHealthObservedValueOneBeyondTheRaiseLimit() {
        // 211 − 180 = 31 > 30 → the observed value is treated as an artefact,
        // the age formula stands.
        XCTAssertEqual(HeartRateZones.resolvedMax(age: 40, overrideBpm: nil, healthObservedBpm: 211).bpm, 180)
    }

    func testResolvedMaxBpmRejectsAHealthObservedValueAtOrBelowTheAgeEstimate() {
        // An observed maximum may only raise the estimate, never lower it —
        // "at" (180) and "below" (170) both fall back to the formula.
        XCTAssertEqual(HeartRateZones.resolvedMax(age: 40, overrideBpm: nil, healthObservedBpm: 180).bpm, 180)
        XCTAssertEqual(HeartRateZones.resolvedMax(age: 40, overrideBpm: nil, healthObservedBpm: 170).bpm, 180)
    }

    func testResolvedMaxBpmRejectsAHealthObservedValueBelowThePlausibleBand() {
        XCTAssertEqual(HeartRateZones.resolvedMax(age: 40, overrideBpm: nil, healthObservedBpm: 100).bpm, 180)
    }

    func testResolvedMaxBpmRejectsAHealthObservedValueAboveThePlausibleBandEvenWithinTheRaiseLimit() {
        // Age 10 → age-based 210 (the youngest the editor allows), so 235 is
        // only 25 bpm above it — inside the raise limit — but 235 sits outside
        // maxRangeBpm (120...230), so the range gate alone must reject it.
        XCTAssertEqual(HeartRateZones.resolvedMax(age: 10, overrideBpm: nil, healthObservedBpm: 235).bpm, 210)
    }

    func testAgeBasedMaxBpmClampsAgeToTheFormulaRange() {
        XCTAssertEqual(HeartRateZones.ageBasedMaxBpm(age: 40), 180)
        // Ages outside the editor's range clamp to its edges before 220 − age.
        XCTAssertEqual(HeartRateZones.ageBasedMaxBpm(age: 5), 210)   // clamped to 10
        XCTAssertEqual(HeartRateZones.ageBasedMaxBpm(age: 150), 120) // clamped to 100
        // The range's own edges need no clamping.
        XCTAssertEqual(HeartRateZones.ageBasedMaxBpm(age: 10), 210)
        XCTAssertEqual(HeartRateZones.ageBasedMaxBpm(age: 100), 120)
    }

    // MARK: - The observed maximum has to be corroborated across days

    func testASingleArtefactDayCannotBecomeTheObservedMaximum() {
        // The reproduction: one noisy handlebar second at 205 bpm, on one day,
        // for a 40-year-old whose age-based maximum is 180. 205 is inside
        // maxRangeBpm and inside the raise limit, so only the corroboration
        // requirement can stop it — and it must, because every zone boundary
        // and every phase-3 ceiling would move up with it.
        let dailyMaxima = [205, 152, 148, 151, 149]
        XCTAssertEqual(HeartRateZones.corroboratedObservedMaxBpm(dailyMaxima: dailyMaxima), 152)
        XCTAssertEqual(HeartRateZones.resolvedMax(age: 40, overrideBpm: nil,
                                                     healthObservedBpm: 152).bpm, 180)
    }

    func testTwoDaysAgreeingRaiseTheObservedMaximum() {
        // A genuine maximum shows up on more than one hard session.
        XCTAssertEqual(HeartRateZones.corroboratedObservedMaxBpm(
            dailyMaxima: [198, 196, 171, 168]), 196)
        XCTAssertEqual(HeartRateZones.resolvedMax(age: 40, overrideBpm: nil,
                                                     healthObservedBpm: 196).bpm, 196)
    }

    func testAnImplausibleDayIsDroppedBeforeRankingRatherThanConsumingTheTopSlot() {
        // 250 is not a heart rate. If it were merely ranked, it would occupy the
        // uncorroborated top slot and let the single 205 day through as the
        // "corroborated" one — so out-of-band days are dropped first.
        XCTAssertNil(HeartRateZones.corroboratedObservedMaxBpm(dailyMaxima: [250, 205]))
    }

    func testTooFewDaysToCorroborateAnythingYieldsNoObservedMaximum() {
        XCTAssertNil(HeartRateZones.corroboratedObservedMaxBpm(dailyMaxima: []))
        XCTAssertNil(HeartRateZones.corroboratedObservedMaxBpm(dailyMaxima: [190]))
        // Days with no reading at all (0) are not days that agree.
        XCTAssertNil(HeartRateZones.corroboratedObservedMaxBpm(dailyMaxima: [190, 0, 0]))
    }

    func testTheCorroboratedMaximumIsTheSecondHighestDayInAnyOrder() {
        // Order of the collection query's buckets must not matter.
        XCTAssertEqual(HeartRateZones.corroboratedObservedMaxBpm(
            dailyMaxima: [140, 190, 160, 188]), 188)
        XCTAssertEqual(HeartRateZones.corroboratedObservedMaxBpm(
            dailyMaxima: [188, 190]), 188)
        // Two identical days corroborate each other.
        XCTAssertEqual(HeartRateZones.corroboratedObservedMaxBpm(
            dailyMaxima: [190, 190]), 190)
    }

    // MARK: - Resolution: which branch won

    func testTheResolverNamesTheBranchInsteadOfLeavingItToBeGuessed() {
        // The case the profile screen cannot infer from the numbers: age 40, no
        // override, an observed maximum of exactly 220 − 40. Equality would
        // claim "from Health" for a value that came from the formula.
        let resolved = HeartRateZones.resolvedMax(age: 40, overrideBpm: nil, healthObservedBpm: 180)
        XCTAssertEqual(resolved.bpm, 180)
        XCTAssertEqual(resolved.source, .ageFormula)
    }

    func testMaxSourceForEveryBranch() {
        XCTAssertEqual(HeartRateZones.resolvedMax(age: 40, overrideBpm: 190,
                                                  healthObservedBpm: 200).source, .userOverride)
        XCTAssertEqual(HeartRateZones.resolvedMax(age: 40, overrideBpm: nil,
                                                  healthObservedBpm: 200).source, .healthObserved)
        XCTAssertEqual(HeartRateZones.resolvedMax(age: 40, overrideBpm: nil,
                                                  healthObservedBpm: nil).source, .ageFormula)
        // Rejected as an artefact: the value is the formula's, and so is the source.
        XCTAssertEqual(HeartRateZones.resolvedMax(age: 40, overrideBpm: nil,
                                                  healthObservedBpm: 211).source, .ageFormula)
    }

    func testRestingSourceForEveryBranch() {
        XCTAssertEqual(HeartRateZones.resolvedResting(overrideBpm: 70,
                                                      healthBpm: 48).source, .userOverride)
        XCTAssertEqual(HeartRateZones.resolvedResting(overrideBpm: nil,
                                                      healthBpm: 48).source, .health)
        XCTAssertEqual(HeartRateZones.resolvedResting(overrideBpm: nil,
                                                      healthBpm: nil).source, .fallback)
        // A Health sample of exactly the fallback still came from Health.
        XCTAssertEqual(HeartRateZones.resolvedResting(overrideBpm: nil,
                                                      healthBpm: 60).source, .health)
        // An implausible sample is skipped, so the fallback is what won.
        XCTAssertEqual(HeartRateZones.resolvedResting(overrideBpm: nil,
                                                      healthBpm: 20).source, .fallback)
    }

    // MARK: - Resolution: resting heart rate (override → Health → fallback)

    func testResolvedRestingBpmOverrideWinsOutrightOverHealth() {
        XCTAssertEqual(HeartRateZones.resolvedResting(overrideBpm: 70, healthBpm: 55).bpm, 70)
    }

    func testResolvedRestingBpmOverrideIsClampedToThePlausibleBand() {
        XCTAssertEqual(HeartRateZones.resolvedResting(overrideBpm: 20, healthBpm: nil).bpm, 25)
        XCTAssertEqual(HeartRateZones.resolvedResting(overrideBpm: 150, healthBpm: nil).bpm, 120)
        // The range's own edges need no clamping.
        XCTAssertEqual(HeartRateZones.resolvedResting(overrideBpm: 25, healthBpm: nil).bpm, 25)
        XCTAssertEqual(HeartRateZones.resolvedResting(overrideBpm: 120, healthBpm: nil).bpm, 120)
    }

    func testAnEliteRestingRateFromHealthIsUsedInsteadOfTheFallback() {
        // Health's restingHeartRate is a whole day's computed value, not a raw
        // sample, so 28 bpm is a measurement — and published elite endurance
        // rates reach the high twenties. Skipping it cost 10 bpm on every
        // boundary and reported the user a zone low.
        XCTAssertEqual(HeartRateZones.resolvedResting(overrideBpm: nil, healthBpm: 28).bpm, 28)
        XCTAssertEqual(HeartRateZones.resolvedResting(overrideBpm: nil, healthBpm: 28).source, .health)
        // The consequence, with a maximum of 190: the true Z3 floor is
        // 28 + 0.7 × 162 = 141, the fallback's is 60 + 0.7 × 130 = 151, so 145
        // bpm is exactly where the two bases disagree.
        XCTAssertEqual(HeartRateZones(restingBpm: 28, maxBpm: 190)?.zone(for: 145), .three)
        XCTAssertEqual(HeartRateZones(restingBpm: 60, maxBpm: 190)?.zone(for: 145), .two)
    }

    func testTheRestingBandStillRejectsWhatIsNotARestingRate() {
        // One below the floor, and a rate nothing at rest reaches.
        XCTAssertEqual(HeartRateZones.resolvedResting(overrideBpm: nil, healthBpm: 24).bpm, 60)
        XCTAssertEqual(HeartRateZones.resolvedResting(overrideBpm: nil, healthBpm: 121).bpm, 60)
    }

    func testResolvedRestingBpmUsesHealthWhenThereIsNoOverride() {
        XCTAssertEqual(HeartRateZones.resolvedResting(overrideBpm: nil, healthBpm: 55).bpm, 55)
    }

    func testResolvedRestingBpmSkipsAnImplausibleHealthSampleRatherThanClampingIt() {
        // Unlike an override, nobody asked for this value — the documented
        // fallback (60) is the honest answer, not a clamp to the band's edge.
        XCTAssertEqual(HeartRateZones.resolvedResting(overrideBpm: nil, healthBpm: 20).bpm, 60)
        XCTAssertEqual(HeartRateZones.resolvedResting(overrideBpm: nil, healthBpm: 150).bpm, 60)
    }

    func testResolvedRestingBpmFallsBackWithNoOverrideOrHealthValue() {
        XCTAssertEqual(HeartRateZones.resolvedResting(overrideBpm: nil, healthBpm: nil).bpm, 60)
    }

    // MARK: - Evidence that contradicts the formula is reported, not suppressed

    func testAnObservedMaximumBelowTheFormulaIsReportedThoughItIsNotAdopted() {
        // The reproduction: a 55-year-old on a beta-blocker whose year of Health
        // workouts tops out at 118 bpm on more than one day. 118 is below
        // maxRangeBpm, so it may not be adopted — but suppressing it left the
        // profile printing "no Health data" while Health held a year of
        // contradicting evidence.
        XCTAssertEqual(HeartRateZones.corroboratedObservedMaxBpm(
            dailyMaxima: [118, 117, 112, 104]), 117)
        XCTAssertEqual(HeartRateZones.resolvedMax(age: 55, overrideBpm: nil,
                                                     healthObservedBpm: 117).bpm, 165)
        XCTAssertEqual(HeartRateZones.resolvedMax(age: 55, overrideBpm: nil,
                                                  healthObservedBpm: 117).source, .ageFormula)
    }

    func testADayThatNeverLeftRestIsNotEvidenceOfACeiling() {
        // Below the reportable floor there is nothing to report: a day peaking
        // at 96 bpm is a day without exertion, not a ceiling.
        XCTAssertNil(HeartRateZones.corroboratedObservedMaxBpm(dailyMaxima: [96, 92, 88]))
        // The floor's own edge is reportable.
        XCTAssertEqual(HeartRateZones.corroboratedObservedMaxBpm(dailyMaxima: [100, 100]), 100)
        XCTAssertNil(HeartRateZones.corroboratedObservedMaxBpm(dailyMaxima: [99, 99]))
    }

    func testTheReportFloorIsBelowTheAdoptionFloor() {
        // Two different questions, and the code used to answer both with one
        // range: report anything plausible, adopt only what the formula's own
        // band admits.
        XCTAssertLessThan(HeartRateZones.reportableMaxRangeBpm.lowerBound,
                          HeartRateZones.maxRangeBpm.lowerBound)
        XCTAssertEqual(HeartRateZones.reportableMaxRangeBpm.upperBound,
                       HeartRateZones.maxRangeBpm.upperBound)
    }

    // MARK: - The workout's frozen basis

    func testABasisCarriesItsOwnZones() {
        let basis = HeartRateBasis(restingBpm: 60, maxBpm: 180)
        XCTAssertEqual(basis.zones, HeartRateZones(restingBpm: 60, maxBpm: 180))
        // A degenerate pair has no zones to draw, exactly as the live path.
        XCTAssertNil(HeartRateBasis(restingBpm: 150, maxBpm: 150).zones)
    }
}
