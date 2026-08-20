// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import Foundation

/// Body data for the calorie calculation.
struct BodyProfile: Equatable {
    var weightKg: Double
    var heightCm: Double
    var age: Int
    var isMale: Bool

    /// The default when there is neither HealthKit data nor an override.
    static let fallback = BodyProfile(weightKg: 75, heightCm: 175, age: 40, isMale: true)
}

/// Elevation calculation from speed and incline: at small angles, distance
/// covered × incline% is a good approximation (10 km/h @ 10% = 1000 m/hour).
/// Only distance covered at a positive incline counts as elevation gain.
enum ElevationMath {
    static func gainPerSecond(speedKmh: Double, inclinePercent: Int) -> Double {
        guard speedKmh > 0, inclinePercent > 0 else { return 0 }
        return speedKmh / 3.6 * Double(inclinePercent) / 100
    }
}

/// Calorie estimation. Two modes:
/// - with heart rate available, HR-based (Keytel et al., 2005, J Sports Sci);
/// - without it, MET-based, from the ACSM walking/running VO2 equations.
enum CalorieEngine {

    /// Above this heart rate the HR-based estimate is considered reliable
    /// (the Keytel formula was built for the exercise range).
    static let heartRateThreshold = 90

    /// kcal/min from heart rate (Keytel: kJ/min, divided by 4.184).
    static func kcalPerMinute(heartRate: Int, profile: BodyProfile) -> Double {
        let hr = Double(heartRate)
        let kg = profile.weightKg
        let age = Double(profile.age)
        let kjPerMinute: Double = profile.isMale
            ? -55.0969 + 0.6309 * hr + 0.1988 * kg + 0.2017 * age
            : -20.4022 + 0.4472 * hr - 0.1263 * kg + 0.0740 * age
        return max(0, kjPerMinute / 4.184)
    }

    /// kcal/min from speed + incline (ACSM: VO2 ml/kg/min; 1 l O2 ≈ 5 kcal).
    /// Below 7.2 km/h the walking equation applies, above it the running one.
    static func kcalPerMinute(speedKmh: Double, inclinePercent: Int, profile: BodyProfile) -> Double {
        guard speedKmh > 0 else { return restingKcalPerMinute(profile) }
        let metersPerMinute = speedKmh * 1000 / 60
        let grade = Double(inclinePercent) / 100
        let vo2: Double = speedKmh < 7.2
            ? 3.5 + 0.1 * metersPerMinute + 1.8 * metersPerMinute * grade
            : 3.5 + 0.2 * metersPerMinute + 0.9 * metersPerMinute * grade
        return vo2 * profile.weightKg / 1000 * 5
    }

    /// Resting burn (1 MET).
    static func restingKcalPerMinute(_ profile: BodyProfile) -> Double {
        3.5 * profile.weightKg / 1000 * 5
    }

    /// The calories for one second of the workout — the recorder integrates this.
    static func kcalForSecond(speedKmh: Double, inclinePercent: Int,
                              heartRate: Int, profile: BodyProfile) -> Double {
        let perMinute = heartRate >= heartRateThreshold
            ? kcalPerMinute(heartRate: heartRate, profile: profile)
            : kcalPerMinute(speedKmh: speedKmh, inclinePercent: inclinePercent, profile: profile)
        return perMinute / 60
    }
}
