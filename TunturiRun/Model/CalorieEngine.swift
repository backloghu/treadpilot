import Foundation

/// Testadatok a kalóriaszámításhoz.
struct BodyProfile: Equatable {
    var weightKg: Double
    var heightCm: Double
    var age: Int
    var isMale: Bool

    /// Alapértelmezés, ha se HealthKit-adat, se felülírás nincs.
    static let fallback = BodyProfile(weightKg: 75, heightCm: 175, age: 40, isMale: true)
}

/// Kalóriabecslés. Két üzemmód:
/// - pulzus birtokában HR-alapú (Keytel és tsai., 2005, J Sports Sci);
/// - anélkül MET-alapú, az ACSM gyaloglás/futás VO2-egyenleteiből.
enum CalorieEngine {

    /// E fölött a pulzus fölött tekintjük a HR-alapú becslést megbízhatónak
    /// (a Keytel-képlet edzés-tartományra készült).
    static let heartRateThreshold = 90

    /// kcal/perc pulzus alapján (Keytel: kJ/perc, osztva 4,184-gyel).
    static func kcalPerMinute(heartRate: Int, profile: BodyProfile) -> Double {
        let hr = Double(heartRate)
        let kg = profile.weightKg
        let age = Double(profile.age)
        let kjPerMinute: Double = profile.isMale
            ? -55.0969 + 0.6309 * hr + 0.1988 * kg + 0.2017 * age
            : -20.4022 + 0.4472 * hr - 0.1263 * kg + 0.0740 * age
        return max(0, kjPerMinute / 4.184)
    }

    /// kcal/perc sebesség + dőlés alapján (ACSM: VO2 ml/kg/perc; 1 l O2 ≈ 5 kcal).
    /// 7,2 km/h alatt a gyaloglás-, fölötte a futás-egyenlet.
    static func kcalPerMinute(speedKmh: Double, inclinePercent: Int, profile: BodyProfile) -> Double {
        guard speedKmh > 0 else { return restingKcalPerMinute(profile) }
        let metersPerMinute = speedKmh * 1000 / 60
        let grade = Double(inclinePercent) / 100
        let vo2: Double = speedKmh < 7.2
            ? 3.5 + 0.1 * metersPerMinute + 1.8 * metersPerMinute * grade
            : 3.5 + 0.2 * metersPerMinute + 0.9 * metersPerMinute * grade
        return vo2 * profile.weightKg / 1000 * 5
    }

    /// Nyugalmi égés (1 MET).
    static func restingKcalPerMinute(_ profile: BodyProfile) -> Double {
        3.5 * profile.weightKg / 1000 * 5
    }

    /// Egy másodpercnyi edzés kalóriája — a rögzítő ezt integrálja.
    static func kcalForSecond(speedKmh: Double, inclinePercent: Int,
                              heartRate: Int, profile: BodyProfile) -> Double {
        let perMinute = heartRate >= heartRateThreshold
            ? kcalPerMinute(heartRate: heartRate, profile: profile)
            : kcalPerMinute(speedKmh: speedKmh, inclinePercent: inclinePercent, profile: profile)
        return perMinute / 60
    }
}
