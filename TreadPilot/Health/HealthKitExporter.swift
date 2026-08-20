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
    private var isExporting = false

    init() {
        autoSave = UserDefaults.standard.object(forKey: "health.autosave") as? Bool ?? true
    }

    /// Elavult (előző edzéshez tartozó) állapot törlése — folyamatban lévő
    /// mentést nem szakít meg.
    func resetState() {
        guard !isExporting else { return }
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
        // Demó (szimulált) edzés nem szennyezheti a valódi Health-adatokat.
        guard !session.isDemo else {
            state = .idle
            return
        }
        // Ha a Watch-session rögzítette a pulzust, a Watch menti a saját
        // workoutját a Healthbe — az iPhone-oldali mentés duplikálna.
        guard !session.watchProvidedHeartRate else {
            state = .idle
            return
        }
        // Egyidejű mentés (automatikus + kézi gomb) ellen: egyszerre csak egy.
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }
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

            // Csak azokat a mintatípusokat írjuk, amikre a felhasználó engedélyt
            // adott — egy letiltott típus ne buktassa el az egész mentést.
            var samples: [HKSample] = []
            if session.distanceKm > 0,
               store.authorizationStatus(for: distanceType) == .sharingAuthorized {
                samples.append(HKQuantitySample(
                    type: distanceType,
                    quantity: HKQuantity(unit: .meterUnit(with: .kilo), doubleValue: session.distanceKm),
                    start: start, end: end
                ))
            }
            let kcal = session.computedKcal > 0 ? session.computedKcal : Double(session.padKcal)
            if kcal > 0, store.authorizationStatus(for: energyType) == .sharingAuthorized {
                samples.append(HKQuantitySample(
                    type: energyType,
                    quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal),
                    start: start, end: end
                ))
            }
            // Pulzusminták ritkítva (15 mp-enként), valós időbélyeggel — a
            // mozgásidő-offset szünetek után elcsúszna a fali órától.
            if store.authorizationStatus(for: heartRateType) == .sharingAuthorized {
                let bpmUnit = HKUnit.count().unitDivided(by: .minute())
                for sample in session.sortedSamples
                where sample.heartRate > 0 && sample.offsetSeconds % 15 == 0 {
                    let timestamp = sample.timestamp > start
                        ? sample.timestamp
                        : start.addingTimeInterval(TimeInterval(sample.offsetSeconds))
                    guard timestamp <= end else { continue }
                    samples.append(HKQuantitySample(
                        type: heartRateType,
                        quantity: HKQuantity(unit: bpmUnit, doubleValue: Double(sample.heartRate)),
                        start: timestamp, end: timestamp
                    ))
                }
            }
            if !samples.isEmpty {
                try await builder.addSamples(samples)
            }
            if session.elevationGainM > 0 {
                try await builder.addMetadata([
                    HKMetadataKeyElevationAscended:
                        HKQuantity(unit: .meter(), doubleValue: session.elevationGainM)
                ])
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
