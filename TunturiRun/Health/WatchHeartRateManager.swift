import Foundation
import HealthKit

/// A Watch-kísérőapp tükrözött edzés-sessionjének iPhone-oldali fogadása:
/// élő pulzus a Watchról. Ha nincs Watch vagy session, minden más változatlanul
/// működik (a pad kéztartó-szenzora marad a tartalék).
@MainActor
final class WatchHeartRateManager: NSObject, ObservableObject {

    @Published private(set) var heartRate = 0
    @Published private(set) var sessionActive = false

    private let store = HKHealthStore()
    private var mirroredSession: HKWorkoutSession?

    /// App-induláskor hívandó: átveszi a Watch által (vagy kérésünkre) indított
    /// tükrözött sessionöket — akkor is, ha az app a háttérből éled újra.
    func activate() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        store.workoutSessionMirroringStartHandler = { [weak self] session in
            Task { @MainActor in self?.adopt(session) }
        }
    }

    /// A pad edzésének indulásakor megpróbáljuk elindítani a Watch-appot.
    /// Watch nélkül csendben nem történik semmi.
    func startWatchWorkout() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .running
        configuration.locationType = .indoor
        try? await store.startWatchApp(toHandle: configuration)
    }

    /// Edzés vége: szólunk a Watchnak, hogy zárja le a saját sessionjét.
    func endWatchWorkout() {
        guard let session = mirroredSession else { return }
        if let payload = try? JSONSerialization.data(withJSONObject: ["cmd": "end"]) {
            session.sendToRemoteWorkoutSession(data: payload) { _, _ in }
        }
    }

    private func adopt(_ session: HKWorkoutSession) {
        mirroredSession = session
        session.delegate = self
        sessionActive = true
    }

    private func sessionEnded() {
        mirroredSession = nil
        sessionActive = false
        heartRate = 0
    }
}

extension WatchHeartRateManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState,
                                    date: Date) {
        let ended = (toState == .ended || toState == .stopped)
        guard ended else { return }
        Task { @MainActor in self.sessionEnded() }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didFailWithError error: Error) {
        Task { @MainActor in self.sessionEnded() }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        var latest: Int?
        for item in data {
            if let dict = try? JSONSerialization.jsonObject(with: item) as? [String: Any],
               let bpm = dict["hr"] as? Int {
                latest = bpm
            }
        }
        guard let latest else { return }
        Task { @MainActor in self.heartRate = latest }
    }
}
