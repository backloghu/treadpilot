import Foundation
import HealthKit

/// Watch-oldali edzésmenedzser: HKWorkoutSession + élő pulzus, a sessiont az
/// iPhone-appba tükrözve (startMirroringToCompanionDevice). A pulzusmintákat
/// JSON-üzenetként küldi a telefonnak; a telefon "end" parancsára lezár.
@MainActor
final class WatchWorkoutManager: NSObject, ObservableObject {

    /// Közös példány — az app UI-ja és a WKApplicationDelegate ugyanazt éri el.
    static let shared = WatchWorkoutManager()

    @Published private(set) var heartRate = 0
    @Published private(set) var isActive = false
    @Published private(set) var statusText: String?

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let read: Set<HKObjectType> = [HKQuantityType(.heartRate)]
        let share: Set<HKSampleType> = [
            HKObjectType.workoutType(),
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
        ]
        try? await store.requestAuthorization(toShare: share, read: read)
    }

    func start() {
        guard session == nil else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .running
        configuration.locationType = .indoor
        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store,
                                                         workoutConfiguration: configuration)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder

            let start = Date()
            session.startActivity(with: start)
            builder.beginCollection(withStart: start) { [weak self] success, error in
                guard !success, let message = error?.localizedDescription else { return }
                Task { @MainActor in self?.statusText = "Gyűjtés-hiba: \(message)" }
            }
            session.startMirroringToCompanionDevice { [weak self] success, error in
                guard !success, let message = error?.localizedDescription else { return }
                Task { @MainActor in self?.statusText = "Tükrözés-hiba: \(message)" }
            }
            isActive = true
            statusText = nil
        } catch {
            statusText = "Nem sikerült elindítani az edzést."
        }
    }

    func end() {
        session?.end()
    }

    private func updateHeartRate(_ bpm: Int) {
        heartRate = bpm
        guard let session else { return }
        if let payload = try? JSONSerialization.data(withJSONObject: ["hr": bpm]) {
            session.sendToRemoteWorkoutSession(data: payload) { _, _ in }
        }
    }

    private func finishBuilder() {
        guard let builder else { return }
        Task { @MainActor in
            try? await builder.endCollection(at: Date())
            _ = try? await builder.finishWorkout()
            self.session = nil
            self.builder = nil
            self.isActive = false
            self.heartRate = 0
        }
    }
}

extension WatchWorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState,
                                    date: Date) {
        let ended = (toState == .ended)
        Task { @MainActor in
            if ended { self.finishBuilder() }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.statusText = "Edzés-hiba: \(message)"
            self.isActive = false
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        // Az iPhone "end" parancsa zárja a Watch-oldali sessiont.
        let shouldEnd = data.contains { item in
            (try? JSONSerialization.jsonObject(with: item) as? [String: Any])
                .flatMap { $0["cmd"] as? String } == "end"
        }
        guard shouldEnd else { return }
        Task { @MainActor in self.end() }
    }
}

extension WatchWorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                                    didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let heartRateType = HKQuantityType(.heartRate)
        guard collectedTypes.contains(heartRateType) else { return }
        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        guard let value = workoutBuilder.statistics(for: heartRateType)?
            .mostRecentQuantity()?.doubleValue(for: bpmUnit) else { return }
        let bpm = Int(value.rounded())
        Task { @MainActor in self.updateHeartRate(bpm) }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
