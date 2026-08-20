// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import Foundation
import HealthKit

/// Watch-side workout manager: HKWorkoutSession + live heart rate, with the
/// session mirrored to the iPhone app (startMirroringToCompanionDevice). It sends
/// heart-rate samples to the phone as JSON messages, and closes on the phone's
/// "end" command.
@MainActor
final class WatchWorkoutManager: NSObject, ObservableObject {

    /// Shared instance — the app UI and the WKApplicationDelegate reach the same one.
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
                Task { @MainActor in self?.statusText = String(localized: "Couldn't collect workout data: \(message)") }
            }
            session.startMirroringToCompanionDevice { [weak self] success, error in
                guard !success, let message = error?.localizedDescription else { return }
                Task { @MainActor in self?.statusText = String(localized: "Couldn't mirror the workout to your iPhone: \(message)") }
            }
            isActive = true
            statusText = nil
        } catch {
            statusText = String(localized: "Could not start the workout.")
        }
    }

    func end() {
        session?.end()
    }

    #if DEBUG
    /// Demo state for screenshots (via the `-seedSampleData` launch flag): shows a
    /// live heart rate without a real HealthKit session, because the simulator has
    /// no sensor. Not compiled into a release build.
    @discardableResult
    func startSampleState() -> Bool {
        guard CommandLine.arguments.contains("-seedSampleData"), session == nil else { return false }
        isActive = true
        heartRate = 148
        var rising = true
        Timer.scheduledTimer(withTimeInterval: 1.4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.session == nil else { return }
                if self.heartRate >= 164 { rising = false }
                if self.heartRate <= 139 { rising = true }
                self.heartRate += rising ? Int.random(in: 2...5) : -Int.random(in: 2...5)
            }
        }
        return true
    }
    #endif

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
            // The Watch is only a heart-rate sensor here: the iPhone ALWAYS
            // saves to Health (with richer data, reliably) — the Watch discards its
            // own instance, so duplication is impossible (#182).
            builder.discardWorkout()
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
            self.statusText = String(localized: "The workout stopped because of an error: \(message)")
            self.isActive = false
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        // The iPhone's "end" command closes the Watch-side session.
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
