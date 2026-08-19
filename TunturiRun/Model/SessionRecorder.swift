import Foundation
import SwiftData

/// Edzésrögzítő: a kliens állapotát figyelve automatikusan indít és zár
/// sessionöket, másodpercenként mintát vesz, és folyamatosan (5 mp-enként)
/// lemezre ment, hogy app-leállásnál se vesszen el adat.
@MainActor
final class SessionRecorder: ObservableObject {

    @Published private(set) var activeSession: WorkoutSessionRecord?
    /// A most lezárult edzés — az összefoglaló sheet erre nyílik rá.
    @Published var finishedSession: WorkoutSessionRecord?

    private weak var client: FitShowTreadmillClient?
    private weak var runner: ProgramRunner?
    private var context: ModelContext?
    private var timer: Timer?
    /// Az aktuális testadat-profil a kalóriaszámításhoz (a ProfileStore adja).
    var profileProvider: (@MainActor () -> BodyProfile)?
    /// Külső (Apple Watch) pulzusforrás; 0 = nincs — ilyenkor a pad értéke él.
    var externalHeartRateProvider: (@MainActor () -> Int)?

    private var speedSum = 0.0
    private var heartRateSum = 0
    private var heartRateCount = 0
    private var saveCounter = 0

    /// Legalább ennyi mozgásmásodperc kell, hogy a session megmaradjon —
    /// a félresikerült indítások nem szemetelik tele az előzményeket.
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

        // Ha a kapcsolat megszakadt (vagy bontottuk), a futó session lezárul.
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
            break // visszaszámlálás, leállás folyamatban stb.
        }
    }

    private func begin() {
        guard let context, let client else { return }
        let name: String = if case .ready(let deviceName) = client.phase { deviceName } else { "Futópad" }
        let session = WorkoutSessionRecord(
            startedAt: Date(),
            deviceName: name,
            programName: runner?.program?.name
        )
        context.insert(session)
        activeSession = session
        speedSum = 0
        heartRateSum = 0
        heartRateCount = 0
        saveCounter = 0
    }

    private func record(_ state: TreadmillState) {
        guard let session = activeSession, let context else { return }
        // Pulzus: a Watch élő adata elsőbbséget élvez a pad kéztartó-szenzorával szemben.
        let externalHeartRate = externalHeartRateProvider?() ?? 0
        let heartRate = externalHeartRate > 0 ? externalHeartRate : state.heartRate

        session.movingSeconds += 1
        session.distanceKm = max(session.distanceKm, state.distanceKm)
        session.padKcal = max(session.padKcal, state.kcal)
        session.computedKcal += CalorieEngine.kcalForSecond(
            speedKmh: state.speedKmh,
            inclinePercent: state.inclinePercent,
            heartRate: heartRate,
            profile: profileProvider?() ?? .fallback
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
        // Ha a program frissebb, mint az indulás pillanata (programos indítás),
        // pótoljuk a nevét.
        if session.programName == nil, let program = runner?.program {
            session.programName = program.name
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
