// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import Foundation
import HealthKit

/// The iPhone-side receiver for the Watch companion app's mirrored workout
/// session: live heart rate from the Watch. Without a Watch or a session,
/// everything else works unchanged (the treadmill's handlebar sensor remains
/// the fallback).
@MainActor
final class WatchHeartRateManager: NSObject, ObservableObject {

    /// Shared instance: mirroring hand-off has to be registered at app launch
    /// (including a background launch), not only when the first screen appears.
    static let shared = WatchHeartRateManager()

    @Published private(set) var heartRate = 0
    @Published private(set) var sessionActive = false
    /// The last Watch start's error message — for diagnostics on the dashboard.
    @Published private(set) var startError: String?

    private let store = HKHealthStore()
    private var mirroredSession: HKWorkoutSession?
    private var lastHeartRateAt: Date = .distantPast
    private var handlerInstalled = false

    /// Only reports a heart rate while it counts as fresh — after the Watch goes
    /// quiet (taken off, link lost) the old value must not be pinned forever.
    func freshHeartRate(maxAge: TimeInterval = 10) -> Int {
        guard sessionActive, heartRate > 0,
              Date().timeIntervalSince(lastHeartRateAt) <= maxAge else { return 0 }
        return heartRate
    }

    /// To be called at app launch: takes over mirrored sessions started by the
    /// Watch (or at our request) — including when the app wakes from the background.
    func activate() {
        guard HKHealthStore.isHealthDataAvailable(), !handlerInstalled else { return }
        handlerInstalled = true
        store.workoutSessionMirroringStartHandler = { [weak self] session in
            Task { @MainActor in self?.adopt(session) }
        }
    }

    /// When the treadmill workout starts, try to launch the Watch app.
    /// The error is not swallowed: the dashboard shows it so it can be diagnosed.
    func startWatchWorkout() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .running
        configuration.locationType = .indoor
        do {
            // Launching the Watch also needs HealthKit permission on the iPhone side.
            try await store.requestAuthorization(
                toShare: [HKObjectType.workoutType()],
                read: [HKQuantityType(.heartRate)]
            )
            try await store.startWatchApp(toHandle: configuration)
            startError = nil
        } catch {
            startError = String(localized: "Couldn't start the Watch app: \(error.localizedDescription)")
        }
    }

    /// End of workout: tell the Watch to close its own session.
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
        Task { @MainActor in
            self.heartRate = latest
            self.lastHeartRateAt = Date()
        }
    }
}
