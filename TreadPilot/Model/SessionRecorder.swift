// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import Foundation
import SwiftData

/// Workout recorder: watching the client's state it starts and closes sessions
/// automatically, takes a sample every second, and saves to disk continuously
/// (every 5 s) so no data is lost if the app is terminated.
@MainActor
final class SessionRecorder: ObservableObject {

    @Published private(set) var activeSession: WorkoutSessionRecord?
    /// The workout that just closed — the summary sheet presents this one.
    @Published var finishedSession: WorkoutSessionRecord?

    /// The current body-data profile for the calorie calculation (supplied by ProfileStore).
    var profileProvider: (@MainActor () -> BodyProfile)?
    /// External (Apple Watch) heart-rate source; 0 = none — the treadmill's value applies then.
    var externalHeartRateProvider: (@MainActor () -> Int)?
    /// Runs on every workout close — including short, discarded sessions
    /// (for example to close the Watch workout).
    var onWorkoutEnded: (@MainActor () -> Void)?

    private weak var client: FitShowTreadmillClient?
    private weak var runner: ProgramRunner?
    private var context: ModelContext?
    private var timer: Timer?

    private var speedSum = 0.0
    private var heartRateSum = 0
    private var heartRateCount = 0
    private var saveCounter = 0
    // The baseline of the treadmill's cumulative counters at the start of the
    // session — after a reconnect the previous session's distance must not be
    // counted again.
    private var distanceBaselineKm = 0.0
    private var padKcalBaseline = 0
    private var lastRawDistanceKm = 0.0
    private var lastRawPadKcal = 0

    /// The session is only kept above this many moving seconds — so botched
    /// starts do not litter the history.
    private let minimumKeptSeconds = 5

    func bind(client: FitShowTreadmillClient, runner: ProgramRunner, context: ModelContext) {
        guard self.client == nil else { return }
        self.client = client
        self.runner = runner
        self.context = context
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let client else { return }

        // If the session's model has been deleted in the meantime (for example from
        // the history), it must not be touched — writing an invalid model would crash.
        if let session = activeSession, session.isDeleted {
            activeSession = nil
            onWorkoutEnded?()
        }

        // If the connection dropped (or we disconnected), the running session closes.
        let connected = if case .ready = client.phase { true } else { false }
        if !connected {
            if activeSession != nil { finish() }
            return
        }

        switch client.state.status {
        case .running:
            if activeSession == nil { begin() }
            record(client.state)
        case .paused:
            activeSession?.pausedSeconds += 1
            saveSoon()
        case .idle, .end:
            if activeSession != nil { finish() }
        default:
            break // counting down, stopping in progress, etc.
        }
    }

    private func begin() {
        guard let context, let client else { return }
        let name: String = if case .ready(let deviceName) = client.phase { deviceName } else { String(localized: "Treadmill") }
        let session = WorkoutSessionRecord(
            startedAt: Date(),
            deviceName: name,
            programName: runner?.activeProgramName
        )
        session.isDemo = client.demoMode
        context.insert(session)
        activeSession = session
        speedSum = 0
        heartRateSum = 0
        heartRateCount = 0
        saveCounter = 0
        // On a reconnect the treadmill's counters kept running — whatever has
        // accumulated on them so far does not belong to this session.
        distanceBaselineKm = client.state.distanceKm
        padKcalBaseline = client.state.kcal
        lastRawDistanceKm = client.state.distanceKm
        lastRawPadKcal = client.state.kcal
    }

    private func record(_ state: TreadmillState) {
        guard let session = activeSession, let context, !session.isDeleted else { return }
        // Heart rate: the Watch's live data takes precedence over the treadmill's handlebar sensor.
        let externalHeartRate = externalHeartRateProvider?() ?? 0
        let heartRate = externalHeartRate > 0 ? externalHeartRate : state.heartRate
        if externalHeartRate > 0 { session.watchProvidedHeartRate = true }

        // If the treadmill's counter reset (a new console workout), take a new baseline.
        if state.distanceKm < lastRawDistanceKm { distanceBaselineKm = -session.distanceKm }
        if state.kcal < lastRawPadKcal { padKcalBaseline = -session.padKcal }
        lastRawDistanceKm = state.distanceKm
        lastRawPadKcal = state.kcal

        session.movingSeconds += 1
        session.distanceKm = max(session.distanceKm, state.distanceKm - distanceBaselineKm)
        session.padKcal = max(session.padKcal, state.kcal - padKcalBaseline)
        session.computedKcal += CalorieEngine.kcalForSecond(
            speedKmh: state.speedKmh,
            inclinePercent: state.inclinePercent,
            heartRate: heartRate,
            profile: profileProvider?() ?? .fallback
        )
        session.elevationGainM += ElevationMath.gainPerSecond(
            speedKmh: state.speedKmh,
            inclinePercent: state.inclinePercent
        )
        session.maxSpeedKmh = max(session.maxSpeedKmh, state.speedKmh)
        speedSum += state.speedKmh
        session.avgSpeedKmh = speedSum / Double(session.movingSeconds)
        if heartRate > 0 {
            heartRateSum += heartRate
            heartRateCount += 1
            session.avgHeartRate = heartRateSum / heartRateCount
            session.maxHeartRate = max(session.maxHeartRate, heartRate)
        }
        // For a program-driven start the program name can still be filled in after
        // the start — but only from an actually running program.
        if session.programName == nil, let programName = runner?.activeProgramName {
            session.programName = programName
        }

        let sample = WorkoutSampleRecord(
            offsetSeconds: session.movingSeconds,
            speedKmh: state.speedKmh,
            inclinePercent: state.inclinePercent,
            heartRate: heartRate,
            distanceKm: state.distanceKm
        )
        sample.session = session
        context.insert(sample)
        saveSoon()
    }

    private func saveSoon() {
        saveCounter += 1
        if saveCounter % 5 == 0 { try? context?.save() }
    }

    private func finish() {
        guard let session = activeSession, let context else { return }
        activeSession = nil
        defer { onWorkoutEnded?() }
        if session.isDeleted { return }
        if session.movingSeconds < minimumKeptSeconds {
            context.delete(session)
            try? context.save()
            return
        }
        session.endedAt = Date()
        try? context.save()
        finishedSession = session
    }
}
