// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import Foundation

/// Workout program runner. Core safety rules:
/// - starting the belt is always preceded by an explicit user confirmation (for a
///   program started from a standing belt too: the start command is only sent after
///   a confirmation dialog and an app-side, cancellable countdown);
/// - segment targets are only sent to an actually running belt;
/// - if the user stops or pauses the machine on the console, the program is
///   suspended immediately.
@MainActor
final class ProgramRunner: ObservableObject {

    enum RunnerState: Equatable {
        case idle
        /// App-side countdown after the user's confirmation.
        case armed(remaining: Int)
        /// The start command has been sent; we wait for the belt to actually start
        /// (the console's own countdown falls in here too).
        case waitingForBelt(elapsed: Int)
        case running(segmentIndex: Int, remaining: TimeInterval)
        case suspended(segmentIndex: Int, remaining: TimeInterval)
        case finished
    }

    /// The length of the app-side countdown when starting from a standing belt.
    static let armCountdownSeconds = 5
    /// We give up after this many seconds if the belt does not start after the start command.
    private static let beltStartTimeout = 30

    @Published private(set) var program: WorkoutProgram?
    @Published private(set) var runnerState: RunnerState = .idle

    private weak var client: FitShowTreadmillClient?
    private var timer: Timer?
    // Some consoles report a "running" status with 0 speed even while paused — we
    // suspend after this many stationary seconds (#181).
    private var zeroSpeedSeconds = 0
    private static let zeroSpeedSuspendThreshold = 3

    var currentSegment: WorkoutSegment? {
        guard let program else { return nil }
        switch runnerState {
        case .running(let index, _), .suspended(let index, _):
            return program.segments.indices.contains(index) ? program.segments[index] : nil
        default:
            return nil
        }
    }

    /// The next segment, if there is one.
    var nextSegment: WorkoutSegment? {
        guard let program else { return nil }
        switch runnerState {
        case .running(let index, _), .suspended(let index, _):
            return Self.nextSegment(in: program, after: index)
        default:
            return nil
        }
    }

    /// The time remaining from the whole program, in seconds.
    var programRemainingSeconds: Int? {
        guard let program else { return nil }
        switch runnerState {
        case .running(let index, let remaining), .suspended(let index, let remaining):
            return Self.programRemainingSeconds(in: program, segmentIndex: index,
                                                segmentRemaining: remaining)
        default:
            return nil
        }
    }

    /// Progress through the whole program, 0–1.
    var programProgress: Double? {
        guard let program, program.totalDuration > 0,
              let remaining = programRemainingSeconds else { return nil }
        return min(1, max(0, 1 - Double(remaining) / program.totalDuration))
    }

    nonisolated static func programRemainingSeconds(in program: WorkoutProgram,
                                                    segmentIndex: Int,
                                                    segmentRemaining: TimeInterval) -> Int {
        let futureSeconds = program.segments.dropFirst(segmentIndex + 1)
            .reduce(0.0) { $0 + $1.duration }
        return max(0, Int(segmentRemaining.rounded()) + Int(futureSeconds))
    }

    nonisolated static func nextSegment(in program: WorkoutProgram,
                                        after index: Int) -> WorkoutSegment? {
        let next = index + 1
        return program.segments.indices.contains(next) ? program.segments[next] : nil
    }

    /// The name of the actually running/starting program — a program left in the
    /// .finished/.idle state must not label later manual workouts.
    var activeProgramName: String? {
        switch runnerState {
        case .armed, .waitingForBelt, .running, .suspended:
            return program?.name
        case .idle, .finished:
            return nil
        }
    }

    // MARK: - Start paths

    /// Starting a program on an already running belt: the first segment begins immediately.
    func start(_ program: WorkoutProgram, on client: FitShowTreadmillClient) {
        guard client.state.isRunning, let first = program.segments.first else { return }
        self.program = program
        self.client = client
        runnerState = .running(segmentIndex: 0, remaining: first.duration)
        apply(first)
        startTimer()
    }

    /// Arming a program on a standing belt — it is the caller's responsibility to
    /// call this only after a user confirmation. After the countdown the app starts
    /// the belt itself with the first segment's targets.
    func arm(_ program: WorkoutProgram, on client: FitShowTreadmillClient) {
        guard !client.state.isRunning, !program.segments.isEmpty else { return }
        self.program = program
        self.client = client
        runnerState = .armed(remaining: Self.armCountdownSeconds)
        startTimer()
    }

    /// Cancellation during the countdown or while waiting for the treadmill.
    func cancelArm() {
        switch runnerState {
        case .armed:
            stop() // the start command has not been sent yet — the belt will not start
        case .waitingForBelt:
            client?.requestStop() // the start has already been sent: stop it to be safe
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

    // MARK: - Timing

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
                stop() // the treadmill did not start — stop issuing commands
            } else {
                runnerState = .waitingForBelt(elapsed: elapsed + 1)
            }

        case .running(let index, let remaining):
            guard client.state.isRunning else {
                zeroSpeedSeconds = 0
                if client.state.status == .idle || client.state.status == .end {
                    // The belt stopped completely — the program is aborted and must
                    // not resume on its own at a later manual start.
                    stop()
                } else {
                    // Pause / stop in progress: suspend.
                    runnerState = .suspended(segmentIndex: index, remaining: remaining)
                }
                return
            }
            // A "running" status with 0 speed means it is actually paused (#181):
            // the segment counter must not advance.
            if client.state.speedKmh == 0 {
                zeroSpeedSeconds += 1
                if zeroSpeedSeconds >= Self.zeroSpeedSuspendThreshold {
                    zeroSpeedSeconds = 0
                    runnerState = .suspended(segmentIndex: index, remaining: remaining)
                }
                return
            }
            zeroSpeedSeconds = 0
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
            if client.state.isRunning && client.state.speedKmh > 0 {
                // We only resume on an actually moving belt (#181).
                runnerState = .running(segmentIndex: index, remaining: remaining)
                if let segment = currentSegment { apply(segment) }
            } else if client.state.status == .idle || client.state.status == .end {
                // It turned into a full stop rather than a pause: the program is aborted.
                stop()
            }

        case .idle, .finished:
            break
        }
    }

    private func apply(_ segment: WorkoutSegment) {
        client?.setTarget(speedKmh: segment.targetSpeedKmh, incline: segment.targetIncline)
    }
}
