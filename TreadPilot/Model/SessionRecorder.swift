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

    /// The zone basis this workout runs on, snapshotted at `begin()` and dropped
    /// when the session closes. nil means no workout is being recorded. Same
    /// reason as the cumulative-counter baselines below: the inputs move
    /// underneath us — a Health refresh or an override edit — and the band and
    /// ceilings a running workout is judged by may not move with them.
    @Published private(set) var heartRateBasis: HeartRateBasis?

    /// The current body-data profile for the calorie calculation (supplied by ProfileStore).
    var profileProvider: (@MainActor () -> BodyProfile)?
    /// The live zone basis, read once per workout (supplied by ProfileStore).
    var heartRateBasisProvider: (@MainActor () -> HeartRateBasis?)?
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
            releaseHeartRateBasis()
            onWorkoutEnded?()
        }

        latchStopFacts(client: client)

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
        freezeHeartRateBasis()
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
        // A manual start never goes through `ProgramRunner.beginWorkout()`, so
        // this is the boundary where a previous workout's heart-rate-ceiling
        // stop reason — otherwise still standing on the runner — must stop being
        // readable. See `latchStopFacts` below for why the fresh `activeSession`
        // above does not already guarantee that on its own.
        runner?.forgetGovernorStopReason()
    }

    /// The durable half of findings 138/139/142, plus the boundary that makes it
    /// actually hold. `ProgramRunner.governorStopReason` and
    /// `FitShowTreadmillClient.stopNotObeyed` are both live-only: the second is a
    /// fact about the client, not about any one recording, and the first used to
    /// be reset only by a program start — so a manual workout run right after a
    /// governed one inherited its predecessor's reason on the very next tick.
    /// A fresh `activeSession` every `begin()` does not fix that by itself: this
    /// method runs on every tick (unconditionally, above), so it would keep
    /// re-reading the runner's stale field and re-promoting it onto the new
    /// session regardless of how fresh that session's own record started out.
    /// `begin()` closes the actual gap, by clearing the runner's field once its
    /// new session exists; latching both facts onto `activeSession` then does
    /// the rest: the durable fact gets a renderer that survives past the live
    /// dashboard (the summary sheet, the history detail), correctly scoped to
    /// the workout that produced it.
    private func latchStopFacts(client: FitShowTreadmillClient) {
        guard let session = activeSession, !session.isDeleted else { return }
        let next = Self.latchedStopFacts(
            current: (session.stopReason, session.beltDidNotStop),
            governorStopReason: runner?.governorStopReason,
            clientStopNotObeyed: client.stopNotObeyed)
        session.stopReason = next.reason
        session.beltDidNotStop = next.beltDidNotStop
    }

    /// The latch rule as a pure function, so it is tested directly rather than
    /// only through a live `FitShowTreadmillClient`/`ProgramRunner` pair. Both
    /// halves are monotonic for the life of one recording: once set, a reason or
    /// a failure stays, even once `stopNotObeyed` itself is later retired on
    /// evidence — a stop this workout failed to obey stays a fact about this
    /// workout. A governor stop reason that is not the heart-rate ceiling (there
    /// is only the one case today) changes nothing, the same tolerance
    /// `WorkoutSessionRecord.stopReason` gives an unrecognized stored value.
    nonisolated static func latchedStopFacts(
        current: (reason: WorkoutStopReason, beltDidNotStop: Bool),
        governorStopReason: ProgramRunner.GovernorStopReason?,
        clientStopNotObeyed: Bool
    ) -> (reason: WorkoutStopReason, beltDidNotStop: Bool) {
        let reason: WorkoutStopReason = governorStopReason == .heartRateCeiling
            ? .heartRateCeiling : current.reason
        return (reason, current.beltDidNotStop || clientStopNotObeyed)
    }

    /// The zones every reader outside the profile screen shows or steers by: the
    /// running workout's frozen basis, the live one when nothing is recording.
    var activeHeartRateZones: HeartRateZones? {
        if let heartRateBasis { return heartRateBasis.zones }
        return heartRateBasisProvider?()?.zones
    }

    /// Freezing and releasing are called from `begin()` / `finish()`; they are
    /// not private so the freeze can be tested without a Bluetooth session.
    func freezeHeartRateBasis() { heartRateBasis = heartRateBasisProvider.flatMap { $0() } }

    func releaseHeartRateBasis() { heartRateBasis = nil }

    /// Which reading a recorded second gets, and whether the Watch supplied it.
    /// The Watch wins; both sources spell "no reading" 0, the handlebar one also
    /// once its frame goes stale. Pure, so the rule that coverage counts the
    /// Watch and not the merged value is testable without Bluetooth or a store.
    nonisolated static func resolveHeartRate(watchBpm: Int,
                                             handlebarBpm: Int) -> (bpm: Int, fromWatch: Bool) {
        watchBpm > 0 ? (watchBpm, true) : (handlebarBpm, false)
    }

    /// The band a sample gets, from the runner's *arbitrated* band
    /// (`ProgramRunner.governedBandBpm`) and never from a segment's stored
    /// request — the arbitration may have clamped it, and a chart showing a
    /// band the app was never actually holding would be worse than no chart
    /// (spec section 4, "Recording and review"). nil — nothing governing this
    /// second — reads as 0/0, the same default a migrated row carries. Pure,
    /// so the choice is testable without a treadmill or a store.
    nonisolated static func targetBand(for governedBandBpm: ClosedRange<Int>?) -> (low: Int, high: Int) {
        guard let governedBandBpm else { return (0, 0) }
        return (governedBandBpm.lowerBound, governedBandBpm.upperBound)
    }

    private func record(_ state: TreadmillState) {
        guard let session = activeSession, let context, !session.isDeleted else { return }
        let resolved = Self.resolveHeartRate(watchBpm: externalHeartRateProvider?() ?? 0,
                                             handlebarBpm: state.heartRate)
        let heartRate = resolved.bpm
        if resolved.fromWatch {
            session.watchProvidedHeartRate = true
            // Counted per source: a handlebar-only workout would otherwise report
            // the Watch feed as reliable when the governor it will feed would have
            // had no input at all.
            session.watchHeartRateSeconds = (session.watchHeartRateSeconds ?? 0) + 1
        }

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

        let band = Self.targetBand(for: runner?.governedBandBpm)
        let sample = WorkoutSampleRecord(
            offsetSeconds: session.movingSeconds,
            speedKmh: state.speedKmh,
            inclinePercent: state.inclinePercent,
            heartRate: heartRate,
            distanceKm: state.distanceKm,
            targetHrLow: band.low,
            targetHrHigh: band.high
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
        releaseHeartRateBasis()
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
