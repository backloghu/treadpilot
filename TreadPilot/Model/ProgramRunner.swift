// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import Foundation

/// Workout program runner. Core safety rules:
/// - starting the belt is always preceded by an explicit user confirmation (for a
///   program started from a standing belt too: the start command is only sent after
///   a confirmation dialog and an app-side, cancellable countdown);
/// - segment targets are only sent to an actually running belt;
/// - only the user's own intervention suspends a program — a pause or a stop on
///   the console, both of which leave the belt standing. Nothing the radio does may
///   suspend it: resuming re-writes the segment's target, so a suspension the user
///   did not cause could accelerate a belt they had just slowed down by hand;
/// - stale data is refused by the distance integral and by nothing else. A
///   remembered speed must not be turned into metres, but a time goal needs no
///   trusted speed to know that a second passed.
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

    /// How far the current segment has got. It is the runner's own tally, not the
    /// console's: a distance goal is decided on this.
    struct SegmentProgress: Equatable {
        /// Seconds of *moving belt*, measured rather than counted in ticks, and
        /// fractional for the same reason: the 1 Hz timer loses fires (a
        /// backgrounded app is not woken for them and iOS never replays them), so
        /// a tick count silently stretches every long segment past its goal.
        ///
        /// One tick credits at most `maxTickSeconds`, so the *short* gaps a busy
        /// main thread produces are recovered in full while a long one (a whole
        /// background window) is not: after a five-minute gap the segment still
        /// ends about five minutes late. Crediting the whole gap would mean
        /// believing a single frame for minutes on end, so the under-credit is
        /// deliberate — the segment runs long, never short.
        var elapsedSeconds: Double = 0
        var distanceKm: Double = 0
        /// Arrives with heart-rate control, for `.untilHeartRateBelow`.
        var heartRateBelowSeconds: Int = 0
    }

    /// Everything one tick contributes to the tally, as plain values. The guards
    /// live in `accumulating(_:tick:)` rather than in `tick()`'s statement order so
    /// that phase 1's third acceptance criterion — nothing accumulates while the
    /// program is suspended or the belt stands still, and no *distance* accumulates
    /// on a frame the app no longer trusts — is a property of a tested function
    /// instead of a line number.
    struct TickInput: Equatable {
        /// Measured on a monotonic clock, never assumed to be 1.000 s.
        var deltaSeconds: Double
        /// The belt's measured speed, so ramp-up is accounted for.
        var speedKmh: Double
        var isBeltRunning: Bool
        /// `FitShowTreadmillClient.staleData`: no frame for longer than the
        /// client's freshness horizon while the status still says running, so
        /// `speedKmh` is a remembered number. It gates the distance integral and
        /// nothing else — see `accumulating(_:tick:)`.
        var isDataStale: Bool
    }

    /// The length of the app-side countdown when starting from a standing belt.
    static let armCountdownSeconds = 5
    /// We give up after this many seconds if the belt does not start after the start command.
    private static let beltStartTimeout = 30
    /// The largest measured gap a single tick may credit — to the elapsed time and
    /// to the stationary tally alike. It is the client's own freshness horizon, and
    /// reads it rather than restating it: past that horizon the frame carrying this
    /// speed is stale by definition, so a longer gap (a background window, a wedged
    /// main thread) must not be credited as if the belt had held the speed
    /// throughout. Erring low only lengthens a segment, which is the safe direction.
    nonisolated static let maxTickSeconds = FitShowTreadmillClient.freshnessHorizonSeconds

    @Published private(set) var program: WorkoutProgram?
    @Published private(set) var runnerState: RunnerState = .idle
    /// Published rather than recomputed in a view: the distance readout is an
    /// integral, so it exists exactly once, here.
    @Published private(set) var segmentProgress = SegmentProgress()

    private weak var client: FitShowTreadmillClient?
    private var timer: Timer?
    // Some consoles report a "running" status with 0 speed even while paused — we
    // suspend after this much stationary time (#181). Measured seconds, because a
    // single tick may cover up to `maxTickSeconds`: counted in fires, "3 s
    // standing" could mean nine.
    private var zeroSpeedSeconds = 0.0
    nonisolated static let zeroSpeedSuspendSeconds = 3.0
    /// Anchor of the measured tick delta. Monotonic, so a wall-clock change cannot
    /// inject distance into a running segment.
    private var lastTickAt = ContinuousClock.now

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
        guard let program else { return nil }
        switch runnerState {
        case .running(let index, let remaining), .suspended(let index, let remaining):
            return Self.programProgress(in: program, segmentIndex: index,
                                        segmentRemaining: remaining)
        default:
            return nil
        }
    }

    nonisolated static func programRemainingSeconds(in program: WorkoutProgram,
                                                    segmentIndex: Int,
                                                    segmentRemaining: TimeInterval) -> Int {
        let futureSeconds = program.segments.dropFirst(segmentIndex + 1)
            .reduce(0.0) { $0 + $1.plannedDuration }
        return max(0, Int(segmentRemaining.rounded()) + Int(futureSeconds))
    }

    /// Static and pure, because the bug it replaces was a composition: a live ETA
    /// capped at 24 h divided by an uncapped plan showed the bar 55% full at second
    /// zero. Both sides now pass through `WorkoutSegment.maxEstimateSeconds`, and
    /// this function is what a test can hold them to.
    nonisolated static func programProgress(in program: WorkoutProgram,
                                            segmentIndex: Int,
                                            segmentRemaining: TimeInterval) -> Double? {
        let total = program.totalDuration
        guard total > 0 else { return nil }
        let remaining = programRemainingSeconds(in: program, segmentIndex: segmentIndex,
                                                segmentRemaining: segmentRemaining)
        return min(1, max(0, 1 - Double(remaining) / total))
    }

    nonisolated static func nextSegment(in program: WorkoutProgram,
                                        after index: Int) -> WorkoutSegment? {
        let next = index + 1
        return program.segments.indices.contains(next) ? program.segments[next] : nil
    }

    /// One tick folded into the segment tally. Pure, nonisolated and total: an
    /// input that fails a guard leaves the tally untouched and a stale one advances
    /// the clock alone, so neither rule can be lost to a later edit that reorders
    /// `tick()`.
    nonisolated static func accumulating(_ progress: SegmentProgress,
                                         tick input: TickInput) -> SegmentProgress {
        // A belt that is not running and a belt standing still on a "running"
        // status (#181) contribute nothing at all: a time goal means seconds of
        // running, not seconds of waiting.
        guard input.isBeltRunning,
              input.speedKmh.isFinite, input.speedKmh > 0,
              input.deltaSeconds.isFinite, input.deltaSeconds > 0 else { return progress }
        let delta = min(input.deltaSeconds, maxTickSeconds)
        var next = progress
        next.elapsedSeconds += delta
        // Staleness gates this one line. The speed is a remembered number, so
        // integrating it would fabricate metres and let a distance goal complete on
        // them; the clock above needs no trusted speed to know the delta passed,
        // and a time segment shortened or lengthened by a radio gap would be a
        // regression against every program that shipped before distance goals.
        if !input.isDataStale {
            next.distanceKm += input.speedKmh * delta / 3600
        }
        return next
    }

    /// The #181 stationary tally after one tick, in measured seconds. Pure for the
    /// same reason as `accumulating`: "3 s standing" has to mean three seconds on
    /// the same clock the tally is kept on, and that is a property a test can hold.
    nonisolated static func stationarySeconds(_ tally: Double,
                                              tick deltaSeconds: Double) -> Double {
        guard deltaSeconds.isFinite, deltaSeconds > 0 else { return tally }
        return tally + min(deltaSeconds, maxTickSeconds)
    }

    /// Has the segment's goal been reached? Pure and nonisolated, so segment
    /// advancement is testable without Bluetooth and without a MainActor hop.
    nonisolated static func isComplete(goal: SegmentGoal, progress: SegmentProgress) -> Bool {
        switch goal {
        case .time(let seconds):
            return progress.elapsedSeconds >= Double(seconds)
        case .distance(let km):
            return progress.distanceKm >= km
                || progress.elapsedSeconds >= distanceGoalCapSeconds(km: km)
        case .untilHeartRateBelow(_, let maxSeconds):
            // Until the runner has a heart-rate feed the time cap is the only
            // condition — which is also the required behaviour of a failed sensor.
            return progress.elapsedSeconds >= Double(maxSeconds)
        }
    }

    /// The time backstop of a distance goal, in seconds of moving belt. Without it
    /// a distance goal has no upper bound at all: a console that under-reports its
    /// speed (2 km/h while the belt does 8) keeps the segment alive forever, so the
    /// runner re-issues its target and never reaches `requestStop()`.
    ///
    /// The bound is the time the goal needs at the slowest speed a treadmill runs
    /// at all, so it cannot cut short even a walk at the machine's minimum — and it
    /// counts moving seconds only, so pauses do not eat into it. A goal that is not
    /// a positive number returns 0: nonsense must end the segment, not outlive it.
    nonisolated static func distanceGoalCapSeconds(km: Double) -> Double {
        guard km.isFinite, km > 0 else { return 0 }
        return min(km / WorkoutSegment.minEstimateSpeedKmh * 3600,
                   Double(WorkoutSegment.maxEstimateSeconds))
    }

    /// The seconds left from the segment. For a distance goal it is an ETA from
    /// the *commanded* speed: the measured speed would make the countdown jitter
    /// on every belt ramp. The divisor is floored and the result capped, so no
    /// speed can produce a division by zero or an absurd number.
    nonisolated static func estimatedRemainingSeconds(goal: SegmentGoal,
                                                      progress: SegmentProgress,
                                                      commandedSpeedKmh: Double) -> Int {
        switch goal {
        case .time(let seconds):
            return clampedSeconds(Double(seconds) - progress.elapsedSeconds)
        case .distance(let km):
            let remainingKm = km - progress.distanceKm
            guard remainingKm.isFinite, remainingKm > 0 else { return 0 }
            let speed = commandedSpeedKmh.isFinite
                && commandedSpeedKmh > WorkoutSegment.minEstimateSpeedKmh
                ? commandedSpeedKmh : WorkoutSegment.minEstimateSpeedKmh
            return clampedSeconds(remainingKm / speed * 3600)
        case .untilHeartRateBelow(_, let maxSeconds):
            return clampedSeconds(Double(maxSeconds) - progress.elapsedSeconds)
        }
    }

    /// 0 … 24 h, and never NaN — the value goes straight into a countdown label.
    /// The ceiling is `WorkoutSegment.cappedDuration`, the one the plan is bounded
    /// by, so the plan and the live ETA cannot be read on two different scales.
    nonisolated private static func clampedSeconds(_ seconds: Double) -> Int {
        // A NaN remainder is the one case the shared ceiling cannot express: it has
        // to read as the implausible bound, not as "0 s left, advance the segment".
        guard seconds.isFinite else { return WorkoutSegment.maxEstimateSeconds }
        return Int(WorkoutSegment.cappedDuration(seconds).rounded())
    }

    nonisolated private static func remainingInterval(for segment: WorkoutSegment,
                                                      progress: SegmentProgress) -> TimeInterval {
        TimeInterval(estimatedRemainingSeconds(goal: segment.goal, progress: progress,
                                               commandedSpeedKmh: segment.nominalSpeedKmh))
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
        begin(first, at: 0)
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
        segmentProgress = SegmentProgress()
        // The stationary tally belongs to the run that just ended: a leftover
        // count would shorten the #181 threshold for the next program started on
        // the same standing-but-"running" belt.
        resetTickCounters()
    }

    // MARK: - Timing

    private func startTimer() {
        timer?.invalidate()
        resetTickCounters()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Zeroes the per-run tally and re-anchors the tick clock. Called whenever a
    /// run or a segment starts or ends, so nothing carries over.
    private func resetTickCounters() {
        zeroSpeedSeconds = 0
        lastTickAt = ContinuousClock.now
    }

    /// Seconds since the previous tick, measured. The anchor advances on every
    /// tick, including the ones that accumulate nothing, so the seconds spent
    /// standing still or suspended cannot be credited when running resumes.
    private func measuredTickSeconds() -> Double {
        let now = ContinuousClock.now
        let elapsed = Self.seconds(lastTickAt.duration(to: now))
        lastTickAt = now
        return elapsed
    }

    nonisolated private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
    }

    private func tick() {
        guard let program, let client else { return }
        // Read once per tick, whatever the state: the anchor has to move even on
        // the branches that integrate nothing.
        let deltaSeconds = measuredTickSeconds()

        switch runnerState {
        case .armed(let remaining):
            let next = remaining - 1
            if next > 0 {
                runnerState = .armed(remaining: next)
            } else if let first = program.segments.first {
                client.startBelt(speedKmh: first.nominalSpeedKmh, incline: first.nominalIncline)
                runnerState = .waitingForBelt(elapsed: 0)
            } else {
                stop()
            }

        case .waitingForBelt(let elapsed):
            if client.state.isRunning, let first = program.segments.first {
                begin(first, at: 0)
            } else if elapsed >= Self.beltStartTimeout {
                stop() // the treadmill did not start — stop issuing commands
            } else {
                runnerState = .waitingForBelt(elapsed: elapsed + 1)
            }

        case .running(let index, let remaining):
            guard client.state.isRunning else {
                resetTickCounters()
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
            // the segment tally must not advance, and after `zeroSpeedSuspendSeconds`
            // of standing the program is suspended. This is a user's own pause too,
            // only reported as "running at 0" — and the belt is standing on it,
            // which is what makes re-writing the target on resume harmless.
            if client.state.speedKmh == 0 {
                zeroSpeedSeconds = Self.stationarySeconds(zeroSpeedSeconds, tick: deltaSeconds)
                if zeroSpeedSeconds >= Self.zeroSpeedSuspendSeconds {
                    resetTickCounters()
                    runnerState = .suspended(segmentIndex: index, remaining: remaining)
                }
                return
            }
            zeroSpeedSeconds = 0
            guard program.segments.indices.contains(index) else {
                stop()
                return
            }
            let segment = program.segments[index]
            // The distance is integrated from the *measured* speed over the
            // *measured* time, so the belt's ramp-up is accounted for and a lost
            // timer fire does not lose the running it covered. The console's own
            // counter must not drive advancement: it is quantised to 100 m and it
            // resets when a console workout restarts. A stale frame is passed in as
            // such and stops the distance integral inside `accumulating`; the
            // segment clock keeps running, so a radio gap cannot lengthen a time
            // segment or park a running user in `.suspended`.
            segmentProgress = Self.accumulating(
                segmentProgress,
                tick: TickInput(deltaSeconds: deltaSeconds,
                                speedKmh: client.state.speedKmh,
                                isBeltRunning: client.state.isRunning,
                                isDataStale: client.staleData))
            guard Self.isComplete(goal: segment.goal, progress: segmentProgress) else {
                runnerState = .running(segmentIndex: index,
                                       remaining: Self.remainingInterval(for: segment,
                                                                         progress: segmentProgress))
                return
            }
            let nextIndex = index + 1
            if program.segments.indices.contains(nextIndex) {
                begin(program.segments[nextIndex], at: nextIndex)
            } else {
                runnerState = .finished
                timer?.invalidate()
                timer = nil
                client.requestStop()
            }

        case .suspended(let index, let remaining):
            if client.state.isRunning && client.state.speedKmh > 0 {
                // We only resume on an actually moving belt (#181). A staleness
                // check here would only delay this: every route into `.suspended`
                // has seen the belt not running or standing still, and a stale
                // frame is the remembered copy of exactly that frame.
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

    /// Entering a segment: the tally restarts from zero and the targets go out.
    private func begin(_ segment: WorkoutSegment, at index: Int) {
        segmentProgress = SegmentProgress()
        resetTickCounters()
        runnerState = .running(segmentIndex: index,
                               remaining: Self.remainingInterval(for: segment,
                                                                 progress: segmentProgress))
        apply(segment)
    }

    private func apply(_ segment: WorkoutSegment) {
        client?.setTarget(speedKmh: segment.nominalSpeedKmh, incline: segment.nominalIncline)
    }
}
