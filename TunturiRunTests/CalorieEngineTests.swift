import XCTest
@testable import TunturiRun

final class CalorieEngineTests: XCTestCase {

    private let male75 = BodyProfile(weightKg: 75, heightCm: 178, age: 40, isMale: true)
    private let female60 = BodyProfile(weightKg: 60, heightCm: 165, age: 35, isMale: false)

    // MARK: - MET-alapú (ACSM) ág

    func testWalkingFlatUsesWalkingEquation() {
        // 5 km/h, 0%: VO2 = 3,5 + 0,1×83,33 = 11,83 ml/kg/perc → ~4,44 kcal/perc 75 kg-nál.
        let kcal = CalorieEngine.kcalPerMinute(speedKmh: 5, inclinePercent: 0, profile: male75)
        XCTAssertEqual(kcal, 4.44, accuracy: 0.05)
    }

    func testRunningFlatUsesRunningEquation() {
        // 10 km/h, 0%: VO2 = 3,5 + 0,2×166,67 = 36,83 → ~13,81 kcal/perc.
        let kcal = CalorieEngine.kcalPerMinute(speedKmh: 10, inclinePercent: 0, profile: male75)
        XCTAssertEqual(kcal, 13.81, accuracy: 0.05)
    }

    func testInclineIncreasesBurn() {
        let flat = CalorieEngine.kcalPerMinute(speedKmh: 6, inclinePercent: 0, profile: male75)
        let hilly = CalorieEngine.kcalPerMinute(speedKmh: 6, inclinePercent: 8, profile: male75)
        XCTAssertGreaterThan(hilly, flat * 1.5)
    }

    func testZeroSpeedIsRestingBurn() {
        let kcal = CalorieEngine.kcalPerMinute(speedKmh: 0, inclinePercent: 0, profile: male75)
        XCTAssertEqual(kcal, CalorieEngine.restingKcalPerMinute(male75), accuracy: 0.001)
        XCTAssertEqual(kcal, 1.3125, accuracy: 0.001) // 3,5 × 75 / 1000 × 5
    }

    // MARK: - HR-alapú (Keytel) ág

    func testKeytelMale() {
        // 140 bpm, 75 kg, 40 év: (-55,0969 + 88,326 + 14,91 + 8,068)/4,184 ≈ 13,44.
        let kcal = CalorieEngine.kcalPerMinute(heartRate: 140, profile: male75)
        XCTAssertEqual(kcal, 13.44, accuracy: 0.05)
    }

    func testKeytelFemale() {
        // 140 bpm, 60 kg, 35 év: (-20,4022 + 62,608 - 7,578 + 2,59)/4,184 ≈ 8,90.
        let kcal = CalorieEngine.kcalPerMinute(heartRate: 140, profile: female60)
        XCTAssertEqual(kcal, 8.90, accuracy: 0.05)
    }

    func testKeytelNeverNegative() {
        XCTAssertGreaterThanOrEqual(CalorieEngine.kcalPerMinute(heartRate: 40, profile: female60), 0)
    }

    // MARK: - Ág-választás

    func testSecondIntegrationPrefersHeartRateWhenAvailable() {
        let withHR = CalorieEngine.kcalForSecond(speedKmh: 5, inclinePercent: 0,
                                                 heartRate: 140, profile: male75)
        XCTAssertEqual(withHR, CalorieEngine.kcalPerMinute(heartRate: 140, profile: male75) / 60,
                       accuracy: 0.0001)
    }

    func testSecondIntegrationFallsBackToMETWithoutHeartRate() {
        let noHR = CalorieEngine.kcalForSecond(speedKmh: 5, inclinePercent: 0,
                                               heartRate: 0, profile: male75)
        XCTAssertEqual(noHR, CalorieEngine.kcalPerMinute(speedKmh: 5, inclinePercent: 0,
                                                         profile: male75) / 60,
                       accuracy: 0.0001)
    }

    func testLowHeartRateBelowThresholdUsesMET() {
        let lowHR = CalorieEngine.kcalForSecond(speedKmh: 5, inclinePercent: 0,
                                                heartRate: CalorieEngine.heartRateThreshold - 1,
                                                profile: male75)
        XCTAssertEqual(lowHR, CalorieEngine.kcalPerMinute(speedKmh: 5, inclinePercent: 0,
                                                          profile: male75) / 60,
                       accuracy: 0.0001)
    }
}
