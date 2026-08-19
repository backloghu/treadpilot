import Foundation

/// Edzésprogram-futtató. Biztonsági alapszabály: a futtató soha nem indítja el
/// a szalagot — programot csak már futó szalagon lehet elindítani, és ha a
/// felhasználó a konzolon megállítja vagy szünetelteti a gépet, a program
/// azonnal felfüggesztődik.
@MainActor
final class ProgramRunner: ObservableObject {

    enum RunnerState: Equatable {
        case idle
        case running(segmentIndex: Int, remaining: TimeInterval)
        case suspended(segmentIndex: Int, remaining: TimeInterval)
        case finished
    }

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

    /// Program indítása. Csak futó szalagon engedélyezett.
    func start(_ program: WorkoutProgram, on client: FitShowTreadmillClient) {
        guard client.state.isRunning, let first = program.segments.first else { return }
        self.program = program
        self.client = client
        runnerState = .running(segmentIndex: 0, remaining: first.duration)
        apply(first)
        startTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        program = nil
        runnerState = .idle
    }

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

        // Ha a gép nem fut (konzolos stop/pause, biztonsági kulcs), felfüggesztünk.
        if case .running(let index, let remaining) = runnerState, !client.state.isRunning {
            runnerState = .suspended(segmentIndex: index, remaining: remaining)
            return
        }
        // Folytatás, ha a szalag újra fut.
        if case .suspended(let index, let remaining) = runnerState {
            if client.state.isRunning {
                runnerState = .running(segmentIndex: index, remaining: remaining)
                if let segment = currentSegment { apply(segment) }
            }
            return
        }
        guard case .running(let index, let remaining) = runnerState else { return }

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
    }

    private func apply(_ segment: WorkoutSegment) {
        client?.setTarget(speedKmh: segment.targetSpeedKmh, incline: segment.targetIncline)
    }
}
