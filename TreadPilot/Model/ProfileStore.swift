// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import Foundation
import HealthKit

/// Body-data profile: read from HealthKit, with an in-app override.
/// Overrides are stored in UserDefaults; the effective profile resolves
/// per field: override → HealthKit value → default.
@MainActor
final class ProfileStore: ObservableObject {

    @Published private(set) var healthWeightKg: Double?
    @Published private(set) var healthHeightCm: Double?
    @Published private(set) var healthAge: Int?
    @Published private(set) var healthIsMale: Bool?
    @Published private(set) var healthKitStatus: String?
    /// The latest resting heart rate Health has (Apple Watch writes one per day).
    @Published private(set) var healthRestingHeartRate: Int?
    /// The highest heart rate Health has seen on at least
    /// `HeartRateZones.corroboratingDaysRequired` separate days, our own exported
    /// samples excluded — reported whenever it is plausible, including when it
    /// is *lower* than the formula. `HeartRateZones.resolvedMax` decides
    /// separately what may be concluded from it.
    @Published private(set) var healthMaxHeartRate: Int?

    @Published var overrideWeightKg: Double? { didSet { saveOverrides() } }
    @Published var overrideHeightCm: Double? { didSet { saveOverrides() } }
    @Published var overrideAge: Int? { didSet { saveOverrides() } }
    @Published var overrideIsMale: Bool? { didSet { saveOverrides() } }
    @Published var overrideMaxHeartRate: Int? { didSet { saveOverrides() } }
    @Published var overrideRestingHeartRate: Int? { didSet { saveOverrides() } }

    private let store = HKHealthStore()
    private let defaults = UserDefaults.standard
    /// How far back the observed maximum heart rate is taken from. A year
    /// covers a full training season; without a window a single artefact — or a
    /// maximum from a fitness level two years gone — would stay authoritative
    /// forever.
    private let maxHeartRateLookbackMonths = 12
    // didSet also runs during init — writing back while loading is forbidden,
    // otherwise the first field loaded would wipe the other saved overrides.
    private var isLoading = true

    init() {
        overrideWeightKg = defaults.object(forKey: "profile.weight") as? Double
        overrideHeightCm = defaults.object(forKey: "profile.height") as? Double
        overrideAge = defaults.object(forKey: "profile.age") as? Int
        overrideIsMale = defaults.object(forKey: "profile.isMale") as? Bool
        overrideMaxHeartRate = defaults.object(forKey: "profile.maxHeartRate") as? Int
        overrideRestingHeartRate = defaults.object(forKey: "profile.restingHeartRate") as? Int
        isLoading = false
        // The Health values a cold launch needs to zone against the known truth
        // instead of the fallbacks. Health itself is not read here: its
        // permission sheet may not appear ahead of the disclaimer.
        healthAge = defaults.object(forKey: "health.age") as? Int
        healthRestingHeartRate = defaults.object(forKey: "health.restingHeartRate") as? Int
        healthMaxHeartRate = defaults.object(forKey: "health.maxHeartRate") as? Int
        // Body data an earlier build mirrored into the app container with no
        // reader; it belongs in Health, so it does not linger in a device backup.
        for retired in ["health.weight", "health.height", "health.isMale"] {
            defaults.removeObject(forKey: retired)
        }
    }

    var effectiveProfile: BodyProfile {
        BodyProfile(
            weightKg: overrideWeightKg ?? healthWeightKg ?? BodyProfile.fallback.weightKg,
            heightCm: overrideHeightCm ?? healthHeightCm ?? BodyProfile.fallback.heightCm,
            age: overrideAge ?? healthAge ?? BodyProfile.fallback.age,
            isMale: overrideIsMale ?? healthIsMale ?? BodyProfile.fallback.isMale
        )
    }

    /// Maximum heart rate: override → the corroborated maximum seen in Health →
    /// `220 − age`, with the branch that won. The policy lives in `HeartRateZones`
    /// so it is testable without a HealthKit store; the branch is returned so the
    /// profile screen names the source instead of inferring it from equal numbers.
    var resolvedMaxHeartRate: (bpm: Int, source: HeartRateZones.MaxSource) {
        HeartRateZones.resolvedMax(age: effectiveProfile.age,
                                   overrideBpm: overrideMaxHeartRate,
                                   healthObservedBpm: healthMaxHeartRate)
    }

    var effectiveMaxHeartRate: Int { resolvedMaxHeartRate.bpm }

    /// Resting heart rate: override → Health → the documented fallback.
    var resolvedRestingHeartRate: (bpm: Int, source: HeartRateZones.RestingSource) {
        HeartRateZones.resolvedResting(overrideBpm: overrideRestingHeartRate,
                                       healthBpm: healthRestingHeartRate)
    }

    var effectiveRestingHeartRate: Int { resolvedRestingHeartRate.bpm }

    /// A plausible maximum Health has seen that sits *below* the formula's
    /// estimate: the never-lower rule refused it, so the profile shows it as
    /// contradicting evidence and prompts for an override instead of leaving the
    /// user unaware their own data disagrees (spec section 4). An override is a
    /// decision, not an estimate, so nothing is contradicted once one exists.
    var healthMaxHeartRateContradictingEstimate: Int? {
        let resolved = resolvedMaxHeartRate
        guard resolved.source == .ageFormula,
              let observed = healthMaxHeartRate, observed < resolved.bpm else { return nil }
        return observed
    }

    /// The live basis. `SessionRecorder` snapshots this when a workout begins;
    /// during a workout the readers use that snapshot, not this.
    var heartRateBasis: HeartRateBasis {
        HeartRateBasis(restingBpm: effectiveRestingHeartRate, maxBpm: effectiveMaxHeartRate)
    }

    /// The zones the profile screen draws. nil when the resolved pair leaves no
    /// usable reserve — two hand-entered overrides can do that, and there is no
    /// honest zone set to draw then.
    var heartRateZones: HeartRateZones? { heartRateBasis.zones }

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
        overrideMaxHeartRate = nil
        overrideRestingHeartRate = nil
    }

    /// Requesting HealthKit permission and reading the body data.
    func refreshFromHealthKit() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            healthKitStatus = String(localized: "Health is not available on this device.")
            return
        }
        let bodyMass = HKQuantityType(.bodyMass)
        let height = HKQuantityType(.height)
        let restingHeartRate = HKQuantityType(.restingHeartRate)
        // The zone bounds need the reserve, so the heart-rate samples are read
        // for their maximum. The same read is already requested by
        // WatchHeartRateManager, so this adds no new kind of data to the sheet.
        let heartRate = HKQuantityType(.heartRate)
        let readTypes: Set<HKObjectType> = [
            bodyMass, height, restingHeartRate, heartRate,
            HKCharacteristicType(.dateOfBirth),
            HKCharacteristicType(.biologicalSex),
        ]
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
        } catch {
            healthKitStatus = String(localized: "Health permission request failed.")
            return
        }

        // Every read below assigns unconditionally, the two characteristics
        // included: a read that fails has to clear the field, or a value Health
        // no longer has would be re-persisted on every refresh.
        healthAge = (try? store.dateOfBirthComponents())
            .flatMap { Calendar.current.date(from: $0) }
            .flatMap { Calendar.current.dateComponents([.year], from: $0, to: Date()).year }
        switch try? store.biologicalSex().biologicalSex {
        case .male?: healthIsMale = true
        case .female?: healthIsMale = false
        default: healthIsMale = nil
        }
        healthWeightKg = await latestQuantity(of: bodyMass, unit: .gramUnit(with: .kilo))
        healthHeightCm = await latestQuantity(of: height, unit: .meterUnit(with: .centi))
        let bpm = HKUnit.count().unitDivided(by: .minute())
        healthRestingHeartRate = (await latestQuantity(of: restingHeartRate, unit: bpm))
            .map { Int($0.rounded()) }
        let lookbackStart = Calendar.current.date(byAdding: .month,
                                                 value: -maxHeartRateLookbackMonths,
                                                 to: Date()) ?? .distantPast
        healthMaxHeartRate = HeartRateZones.corroboratedObservedMaxBpm(
            dailyMaxima: await dailyMaximaBpm(of: heartRate, unit: bpm, since: lookbackStart)
        )
        saveHealthSnapshot()
        healthKitStatus = (healthWeightKg == nil && healthAge == nil)
            ? String(localized: "No body data found in Health — the app uses your configured or default values.")
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

    /// One maximum per day over the window, from every source except this app.
    /// Per day, because a rate reached on a single day is indistinguishable from
    /// an artefact; not our own samples, because TreadPilot exports the handlebar
    /// reading into Health and evidence about the user may not be what we wrote.
    private func dailyMaximaBpm(of type: HKQuantityType, unit: HKUnit, since: Date) async -> [Int] {
        await withCheckedContinuation { continuation in
            let window = HKQuery.predicateForSamples(withStart: since, end: nil,
                                                     options: .strictStartDate)
            let ourOwnSamples = HKQuery.predicateForObjects(from: [HKSource.default()])
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                window, NSCompoundPredicate(notPredicateWithSubpredicate: ourOwnSamples),
            ])
            var oneDay = DateComponents()
            oneDay.day = 1
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .discreteMax,
                anchorDate: Calendar.current.startOfDay(for: since),
                intervalComponents: oneDay
            )
            query.initialResultsHandler = { _, collection, _ in
                let maxima = (collection?.statistics() ?? []).compactMap {
                    $0.maximumQuantity()?.doubleValue(for: unit)
                }
                continuation.resume(returning: maxima.map { Int($0.rounded()) })
            }
            store.execute(query)
        }
    }

    private func saveOverrides() {
        guard !isLoading else { return }
        setOrRemove(overrideWeightKg, key: "profile.weight")
        setOrRemove(overrideHeightCm, key: "profile.height")
        setOrRemove(overrideAge, key: "profile.age")
        setOrRemove(overrideIsMale, key: "profile.isMale")
        setOrRemove(overrideMaxHeartRate, key: "profile.maxHeartRate")
        setOrRemove(overrideRestingHeartRate, key: "profile.restingHeartRate")
    }

    /// Only what a cold launch zones against: the heart-rate pair and the age
    /// the formula needs. Weight, height and sex stay in Health, where a device
    /// backup does not carry them. Overwritten in full on every refresh, so a
    /// value Health no longer has does not survive as one it does.
    private func saveHealthSnapshot() {
        setOrRemove(healthAge, key: "health.age")
        setOrRemove(healthRestingHeartRate, key: "health.restingHeartRate")
        setOrRemove(healthMaxHeartRate, key: "health.maxHeartRate")
    }

    private func setOrRemove(_ value: Any?, key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
