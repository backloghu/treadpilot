import Foundation
import HealthKit

/// Testadat-profil: HealthKitből olvassuk, app-beli felülírással.
/// A felülírások UserDefaults-ban tárolódnak; az effektív profil
/// mezőnként: felülírás → HealthKit-érték → alapértelmezés.
@MainActor
final class ProfileStore: ObservableObject {

    @Published private(set) var healthWeightKg: Double?
    @Published private(set) var healthHeightCm: Double?
    @Published private(set) var healthAge: Int?
    @Published private(set) var healthIsMale: Bool?
    @Published private(set) var healthKitStatus: String?

    @Published var overrideWeightKg: Double? { didSet { saveOverrides() } }
    @Published var overrideHeightCm: Double? { didSet { saveOverrides() } }
    @Published var overrideAge: Int? { didSet { saveOverrides() } }
    @Published var overrideIsMale: Bool? { didSet { saveOverrides() } }

    private let store = HKHealthStore()
    private let defaults = UserDefaults.standard

    init() {
        overrideWeightKg = defaults.object(forKey: "profile.weight") as? Double
        overrideHeightCm = defaults.object(forKey: "profile.height") as? Double
        overrideAge = defaults.object(forKey: "profile.age") as? Int
        overrideIsMale = defaults.object(forKey: "profile.isMale") as? Bool
    }

    var effectiveProfile: BodyProfile {
        BodyProfile(
            weightKg: overrideWeightKg ?? healthWeightKg ?? BodyProfile.fallback.weightKg,
            heightCm: overrideHeightCm ?? healthHeightCm ?? BodyProfile.fallback.heightCm,
            age: overrideAge ?? healthAge ?? BodyProfile.fallback.age,
            isMale: overrideIsMale ?? healthIsMale ?? BodyProfile.fallback.isMale
        )
    }

    var usesAnyFallback: Bool {
        (overrideWeightKg ?? healthWeightKg) == nil
            || (overrideAge ?? healthAge) == nil
            || (overrideIsMale ?? healthIsMale) == nil
    }

    func clearOverrides() {
        overrideWeightKg = nil
        overrideHeightCm = nil
        overrideAge = nil
        overrideIsMale = nil
    }

    /// HealthKit-engedély kérése és a testadatok beolvasása.
    func refreshFromHealthKit() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            healthKitStatus = "Ezen az eszközön nem érhető el a HealthKit."
            return
        }
        let bodyMass = HKQuantityType(.bodyMass)
        let height = HKQuantityType(.height)
        let readTypes: Set<HKObjectType> = [
            bodyMass, height,
            HKCharacteristicType(.dateOfBirth),
            HKCharacteristicType(.biologicalSex),
        ]
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
        } catch {
            healthKitStatus = "A HealthKit-engedély kérése nem sikerült."
            return
        }

        if let birth = try? store.dateOfBirthComponents(),
           let birthDate = Calendar.current.date(from: birth) {
            healthAge = Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year
        }
        if let sex = try? store.biologicalSex().biologicalSex, sex != .notSet {
            healthIsMale = (sex == .male)
        }
        healthWeightKg = await latestQuantity(of: bodyMass, unit: .gramUnit(with: .kilo))
        healthHeightCm = await latestQuantity(of: height, unit: .meterUnit(with: .centi))
        healthKitStatus = (healthWeightKg == nil && healthAge == nil)
            ? "A HealthKitben nem található testadat — az app a beállított/alapértelmezett értékeket használja."
            : nil
    }

    private func latestQuantity(of type: HKQuantityType, unit: HKUnit) async -> Double? {
        await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let query = HKSampleQuery(sampleType: type, predicate: nil,
                                      limit: 1, sortDescriptors: [sort]) { _, samples, _ in
                let value = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }

    private func saveOverrides() {
        setOrRemove(overrideWeightKg, key: "profile.weight")
        setOrRemove(overrideHeightCm, key: "profile.height")
        setOrRemove(overrideAge, key: "profile.age")
        setOrRemove(overrideIsMale, key: "profile.isMale")
    }

    private func setOrRemove(_ value: Any?, key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
