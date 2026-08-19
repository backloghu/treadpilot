import Foundation

/// Edzésprogram-futtató. Biztonsági alapszabályok:
/// - a szalag indítását mindig explicit felhasználói megerősítés előzi meg
///   (álló szalagról indított programnál is: megerősítő dialógus + app-oldali,
///   megszakítható visszaszámlálás után megy csak ki a start parancs);
/// - a szegmens-célértékek csak ténylegesen futó szalagra mennek ki;
/// - ha a felhasználó a konzolon megállítja vagy szünetelteti a gépet,
///   a program azonnal felfüggesztődik.
@MainActor
final class ProgramRunner: ObservableObject {

    enum RunnerState: Equatable {
        case idle
        /// App-oldali visszaszámlálás a felhasználói megerősítés után.
        case armed(remaining: Int)
        /// A start parancs kiment, várjuk, hogy a szalag ténylegesen elinduljon
        /// (a konzol saját visszaszámlálása is ide esik).
        case waitingForBelt(elapsed: Int)
        case running(segmentIndex: Int, remaining: TimeInterval)
        case suspended(segmentIndex: Int, remaining: TimeInterval)
        case finished
    }

    /// Az app-oldali visszaszámlálás hossza álló szalagról indításnál.
    static let armCountdownSeconds = 5
    /// Ennyi másodperc után adjuk fel, ha a szalag a start parancs után sem indul el.
    private static let beltStartTimeout = 30

    @Published private(set) var program: WorkoutProgram?
    @Published private(set) var runnerState: RunnerState = .idle

    private weak var client: FitShowTreadmillClient?
    private var timer: Timer?

    var currentSegment: WorkoutSegment? {
        guard let program else { return nil }
        switch runnerState {
        case .running(let index, _), .suspended(let index, _):
            return program.segments.indices.contains(index) ? program.segments[index] : nil
        default:
            return nil
        }
    }

    // MARK: - Indítási utak

    /// Program indítása már futó szalagon: azonnal kezdődik az első szegmens.
    func start(_ program: WorkoutProgram, on client: FitShowTreadmillClient) {
        guard client.state.isRunning, let first = program.segments.first else { return }
        self.program = program
        self.client = client
        runnerState = .running(segmentIndex: 0, remaining: first.duration)
        apply(first)
        startTimer()
    }

    /// Program élesítése álló szalagon — a hívó felelőssége, hogy ezt csak
    /// felhasználói megerősítés után hívja. Visszaszámlálás után az app maga
    /// indítja a szalagot az első szegmens célértékeivel.
    func arm(_ program: WorkoutProgram, on client: FitShowTreadmillClient) {
        guard !client.state.isRunning, !program.segments.isEmpty else { return }
        self.program = program
        self.client = client
        runnerState = .armed(remaining: Self.armCountdownSeconds)
        startTimer()
    }

    /// Megszakítás a visszaszámlálás vagy a padra várás alatt.
    func cancelArm() {
        switch runnerState {
        case .armed:
            stop() // start parancs még nem ment ki — a szalag nem indul el
        case .waitingForBelt:
            client?.requestStop() // a start már kiment: biztos, ami biztos, leállítjuk
            stop()
        default:
            break
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        program = nil
        runnerState = .idle
    }

    // MARK: - Időzítés

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let program, let client else { return }

        switch runnerState {
        case .armed(let remaining):
            let next = remaining - 1
            if next > 0 {
                runnerState = .armed(remaining: next)
            } else if let first = program.segments.first {
                client.startBelt(speedKmh: first.targetSpeedKmh, incline: first.targetIncline)
                runnerState = .waitingForBelt(elapsed: 0)
            } else {
                stop()
            }

        case .waitingForBelt(let elapsed):
            if client.state.isRunning, let first = program.segments.first {
                runnerState = .running(segmentIndex: 0, remaining: first.duration)
                apply(first)
            } else if elapsed >= Self.beltStartTimeout {
                stop() // a pad nem indult el — nem parancsolgatunk tovább
            } else {
                runnerState = .waitingForBelt(elapsed: elapsed + 1)
            }

        case .running(let index, let remaining):
            // Konzolos stop/pause/biztonsági kulcs: felfüggesztés.
            guard client.state.isRunning else {
                runnerState = .suspended(segmentIndex: index, remaining: remaining)
                return
            }
            let newRemaining = remaining - 1
            if newRemaining > 0 {
                runnerState = .running(segmentIndex: index, remaining: newRemaining)
                return
            }
            let nextIndex = index + 1
            if program.segments.indices.contains(nextIndex) {
                let next = program.segments[nextIndex]
                runnerState = .running(segmentIndex: nextIndex, remaining: next.duration)
                apply(next)
            } else {
                runnerState = .finished
                timer?.invalidate()
                timer = nil
                client.requestStop()
            }

        case .suspended(let index, let remaining):
            if client.state.isRunning {
                runnerState = .running(segmentIndex: index, remaining: remaining)
                if let segment = currentSegment { apply(segment) }
            }

        case .idle, .finished:
            break
        }
    }

    private func apply(_ segment: WorkoutSegment) {
        client?.setTarget(speedKmh: segment.targetSpeedKmh, incline: segment.targetIncline)
    }
}
