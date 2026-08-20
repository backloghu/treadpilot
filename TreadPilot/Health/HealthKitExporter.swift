// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import Foundation
import HealthKit
import SwiftData

/// Saving a finished workout to Apple Health with HKWorkoutBuilder.
@MainActor
final class HealthKitExporter: ObservableObject {

    enum ExportState: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    @Published private(set) var state: ExportState = .idle
    /// Which session the state above belongs to — with retroactive sync several
    /// views can show a Health box, and they must not see each other's save.
    @Published private(set) var currentSessionID: PersistentIdentifier?
    /// Automatic saving at the end of every workout.
    @Published var autoSave: Bool {
        didSet { UserDefaults.standard.set(autoSave, forKey: "health.autosave") }
    }

    private let store = HKHealthStore()
    private var isExporting = false

    init() {
        autoSave = UserDefaults.standard.object(forKey: "health.autosave") as? Bool ?? true
    }

    /// Clearing stale state (belonging to a previous workout) — does not
    /// interrupt a save in progress.
    func resetState() {
        guard !isExporting else { return }
        state = .idle
        currentSessionID = nil
    }

    /// Saving the session. Duplication guard: an already synced session is not
    /// written a second time.
    func export(_ session: WorkoutSessionRecord) async {
        guard HKHealthStore.isHealthDataAvailable() else {
            currentSessionID = session.persistentModelID
            state = .failed(String(localized: "Health is not available on this device."))
            return
        }
        guard !session.healthKitSynced else {
            currentSessionID = session.persistentModelID
            state = .saved
            return
        }
        // A demo (simulated) workout must not pollute real Health data.
        guard !session.isDemo else {
            state = .idle
            return
        }
        // The iPhone saves even when the Watch is used: the Watch discards its own
        // workout instance (WatchWorkoutManager.finishBuilder), so there is no risk
        // of duplication here (#182).
        // Guard against a concurrent save (automatic + manual button): only one at a time.
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }
        currentSessionID = session.persistentModelID
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
            state = .failed(String(localized: "Health permission request failed."))
            return
        }
        guard store.authorizationStatus(for: workoutType) == .sharingAuthorized else {
            state = .failed(String(localized: "Writing to Health is turned off — enable it in Settings → Health."))
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

            // Only write the sample types the user granted permission for — one
            // denied type must not fail the whole save.
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
            // Heart-rate samples thinned out (every 15 s), with wall-clock
            // timestamps — the moving-time offset would drift from the wall clock
            // after pauses.
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
            state = .failed(String(localized: "Save failed: \(error.localizedDescription)"))
        }
    }
}
