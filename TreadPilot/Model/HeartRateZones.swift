// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import Foundation

/// The five training zones, defined on the heart-rate reserve.
enum HeartRateZone: Int, CaseIterable, Sendable {
    case one = 1
    case two
    case three
    case four
    case five

    /// Spelled out (not derived from `rawValue`) so it diffs against the spec.
    var lowerReserveFraction: Double {
        switch self {
        case .one: return 0.50
        case .two: return 0.60
        case .three: return 0.70
        case .four: return 0.80
        case .five: return 0.90
        }
    }

    /// nil for zone five, which is open-topped on purpose: a reading above the
    /// estimated maximum is still the hardest zone, not "no zone".
    var next: HeartRateZone? { HeartRateZone(rawValue: rawValue + 1) }

    /// "Z3" — a token, not localized; the zone's name belongs to the view layer.
    var shortLabel: String { "Z\(rawValue)" }
}

/// One user's zone boundaries by the heart-rate reserve (Karvonen) method:
/// `target = resting + fraction × (max − resting)` (Karvonen, Kentala & Mustala,
/// 1957). Pure value type; no HealthKit import.
struct HeartRateZones: Equatable, Sendable {

    /// At 20 bpm each 10%-wide band is 2 bpm, already an optical sensor's
    /// resolution; narrower means the profile is wrong, not the user remarkable.
    static let minimumReserveBpm = 20

    /// The floor sits just under the lowest published elite-endurance rates: Health's
    /// `restingHeartRate` is a whole day's computed value, not a raw sample, so a 28
    /// there is a measurement. Above 120 nothing is resting.
    static let restingRangeBpm = 25...120

    /// The maxima that may be *adopted*: the floor is what `220 − age` yields at
    /// the oldest age the profile accepts, the ceiling is above any published
    /// adult observation. The profile's stepper spans it.
    static let maxRangeBpm = 120...230

    /// The maxima worth *reporting* as evidence, the wider question: 118 contradicts
    /// the formula and must be shown though it may not be adopted, while a day
    /// peaking below 100 is a day without exertion rather than a ceiling.
    static let reportableMaxRangeBpm = 100...230

    /// The bottom of the normal adult range (AHA: 60–100), not its middle:
    /// over-estimating resting raises every boundary and reports the user a zone
    /// low, which is what makes a phase-3 governor push harder.
    static let fallbackRestingBpm = 60

    /// The same range the profile editor offers, so the formula cannot be fed an
    /// age the UI cannot show.
    static let formulaAgeRange = 10...100

    /// Two, because one day is what an artefact looks like: a garbled second owns
    /// the highest daily maximum, never the second-highest.
    static let corroboratingDaysRequired = 2

    /// A year covers a full training season; without a window a stale artefact or
    /// an old fitness level would stay authoritative forever.
    static let observedMaxLookbackMonths = 12

    /// `220 − age` has a residual spread of 10–12 bpm (Tanaka, Monahan & Seals,
    /// 2001), so ~2.5 SD of headroom accepts a genuine outlier while rejecting
    /// the 200+ spikes an optical sensor produces at a cadence near the pulse.
    static let observedMaxRaiseLimitBpm = 30

    let restingBpm: Int
    let maxBpm: Int

    /// Fails rather than clamps when the pair leaves no usable reserve (two
    /// hand-entered overrides can): inventing zones would put the user in "Z4"
    /// on numbers nobody believes.
    init?(restingBpm: Int, maxBpm: Int) {
        guard restingBpm > 0, maxBpm - restingBpm >= Self.minimumReserveBpm else { return nil }
        self.restingBpm = restingBpm
        self.maxBpm = maxBpm
    }

    var reserveBpm: Int { maxBpm - restingBpm }

    /// Rounded, because every rate this is compared against is an integer.
    func heartRate(atReserveFraction fraction: Double) -> Int {
        restingBpm + Int((fraction * Double(reserveBpm)).rounded())
    }

    func lowerBoundBpm(of zone: HeartRateZone) -> Int {
        heartRate(atReserveFraction: zone.lowerReserveFraction)
    }

    /// The inclusive span for display; nil `upper` for zone five, which has no
    /// top. Every other zone ends a beat below the next floor, so printed ranges
    /// cannot overlap.
    func boundsBpm(of zone: HeartRateZone) -> (lower: Int, upper: Int?) {
        (lowerBoundBpm(of: zone), zone.next.map { lowerBoundBpm(of: $0) - 1 })
    }

    /// nil for two readings: 0, which means "no reading" everywhere in this
    /// codebase, and anything under zone one's floor, which is genuinely outside
    /// the zones rather than in the lowest one.
    func zone(for heartRate: Int) -> HeartRateZone? {
        guard heartRate > 0 else { return nil }
        // Boundaries increase strictly, so the last floor reached is the zone.
        return HeartRateZone.allCases.last { heartRate >= lowerBoundBpm(of: $0) }
    }

    // MARK: - Resolution

    /// Returned by the resolver because the numbers cannot be compared: an
    /// observed maximum of exactly `220 − age` looks like the formula's answer.
    enum MaxSource: Equatable, Sendable {
        case userOverride
        case healthObserved
        case ageFormula
    }

    /// Which branch produced the effective resting rate, for the same reason.
    enum RestingSource: Equatable, Sendable {
        case userOverride
        case health
        case fallback
    }

    /// The highest daily maximum that `corroboratingDaysRequired` days reached,
    /// ranked over the *reportable* band so it surfaces evidence `resolvedMax` will
    /// not adopt. Implausible days drop before ranking, so one cannot hold the top
    /// slot and let a genuine day through beneath it.
    static func corroboratedObservedMaxBpm(dailyMaxima: [Int]) -> Int? {
        let ranked = dailyMaxima.filter { reportableMaxRangeBpm.contains($0) }.sorted(by: >)
        guard ranked.count >= corroboratingDaysRequired else { return nil }
        return ranked[corroboratingDaysRequired - 1]
    }

    /// `220 − age`. The age is clamped to what the profile editor can express, so
    /// a stored nonsense age cannot leave the plausible band.
    static func ageBasedMaxBpm(age: Int) -> Int {
        220 - clamp(age, to: formulaAgeRange)
    }

    /// Maximum heart rate: override → Health-observed → `220 − age`.
    ///
    /// An observed rate is evidence in one direction only — reaching 190 proves
    /// the maximum is at least 190, never sprinting proves nothing — so it may
    /// raise the estimate and never lower it, bounded by `observedMaxRaiseLimitBpm`
    /// and by `maxRangeBpm`, the adoption band, narrower than the reportable one.
    /// An override wins outright, clamped against an absurd stored value.
    static func resolvedMax(age: Int, overrideBpm: Int?,
                            healthObservedBpm: Int?) -> (bpm: Int, source: MaxSource) {
        if let overrideBpm { return (clamp(overrideBpm, to: maxRangeBpm), .userOverride) }
        let ageBased = ageBasedMaxBpm(age: age)
        guard let observed = healthObservedBpm,
              maxRangeBpm.contains(observed),
              observed > ageBased,
              observed - ageBased <= observedMaxRaiseLimitBpm else { return (ageBased, .ageFormula) }
        return (observed, .healthObserved)
    }

    /// Resting heart rate: override → Health → `fallbackRestingBpm`. An
    /// implausible Health sample is skipped rather than clamped: unlike an
    /// override, nobody asked for it, so the documented fallback is more honest.
    static func resolvedResting(overrideBpm: Int?,
                                healthBpm: Int?) -> (bpm: Int, source: RestingSource) {
        if let overrideBpm { return (clamp(overrideBpm, to: restingRangeBpm), .userOverride) }
        if let healthBpm, restingRangeBpm.contains(healthBpm) { return (healthBpm, .health) }
        return (fallbackRestingBpm, .fallback)
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// The basis one workout runs on: the resolved pair as it stood when the session
/// began (spec section 4). Phase 3's ceilings are percentages of `maxBpm`, so
/// freezing the pair freezes them with it.
struct HeartRateBasis: Equatable, Sendable {
    let restingBpm: Int
    let maxBpm: Int

    /// nil when the pair leaves no usable reserve — see `HeartRateZones.init`.
    var zones: HeartRateZones? { HeartRateZones(restingBpm: restingBpm, maxBpm: maxBpm) }
}
