import Foundation
import HealthKit

/// Kész edzés mentése az Apple Healthbe HKWorkoutBuilderrel.
@MainActor
final class HealthKitExporter: ObservableObject {

    enum ExportState: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    @Published private(set) var state: ExportState = .idle
    /// Automatikus mentés minden edzés végén.
    @Published var autoSave: Bool {
        didSet { UserDefaults.standard.set(autoSave, forKey: "health.autosave") }
    }

    private let store = HKHealthStore()

    init() {
        autoSave = UserDefaults.standard.object(forKey: "health.autosave") as? Bool ?? true
    }

    func resetState() {
        state = .idle
    }

    /// A session mentése. Duplikáció-védelem: már szinkronizált session nem
    /// kerül be még egyszer. (A jövőbeli Watch-kísérőapp saját workout-mentését
    /// szintén ez a jelző hangolja majd össze — lásd #165.)
    func export(_ session: WorkoutSessionRecord) async {
        guard HKHealthStore.isHealthDataAvailable() else {
            state = .failed("Ezen az eszközön nem érhető el a HealthKit.")
            return
        }
        guard !session.healthKitSynced else {
            state = .saved
            return
        }
        state = .saving

        let workoutType = HKObjectType.workoutType()
        let energyType = HKQuantityType(.activeEnergyBurned)
        let distanceType = HKQuantityType(.distanceWalkingRunning)
        let heartRateType = HKQuantityType(.heartRate)
        do {
            try await store.requestAuthorization(
                toShare: [workoutType, energyType, distanceType, heartRateType],
                read: []
            )
        } catch {
            state = .failed("A HealthKit-engedély kérése nem sikerült.")
            return
        }
        guard store.authorizationStatus(for: workoutType) == .sharingAuthorized else {
            state = .failed("A Health-írás nincs engedélyezve — a Beállítások → Egészség alatt adható meg.")
            return
        }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = session.avgSpeedKmh >= 6.5 ? .running : .walking
        configuration.locationType = .indoor

        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        let start = session.startedAt
        let end = session.endedAt ?? start.addingTimeInterval(TimeInterval(max(session.totalSeconds, 1)))

        do {
            try await builder.beginCollection(at: start)

            var samples: [HKSample] = []
            if session.distanceKm > 0 {
                samples.append(HKQuantitySample(
                    type: distanceType,
                    quantity: HKQuantity(unit: .meterUnit(with: .kilo), doubleValue: session.distanceKm),
                    start: start, end: end
                ))
            }
            let kcal = session.computedKcal > 0 ? session.computedKcal : Double(session.padKcal)
            if kcal > 0 {
                samples.append(HKQuantitySample(
                    type: energyType,
                    quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal),
                    start: start, end: end
                ))
            }
            // Pulzusminták ritkítva (15 mp-enként), hogy ne árasszuk el a Healtht.
            let bpmUnit = HKUnit.count().unitDivided(by: .minute())
            for sample in session.sortedSamples
            where sample.heartRate > 0 && sample.offsetSeconds % 15 == 0 {
                let timestamp = start.addingTimeInterval(TimeInterval(sample.offsetSeconds))
                guard timestamp <= end else { break }
                samples.append(HKQuantitySample(
                    type: heartRateType,
                    quantity: HKQuantity(unit: bpmUnit, doubleValue: Double(sample.heartRate)),
                    start: timestamp, end: timestamp
                ))
            }
            if !samples.isEmpty {
                try await builder.addSamples(samples)
            }
            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
            session.healthKitSynced = true
            state = .saved
        } catch {
            state = .failed("A mentés nem sikerült: \(error.localizedDescription)")
        }
    }
}
