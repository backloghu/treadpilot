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
/// - stale data is refused by the distance integral, and by every write that
///   would add load. A remembered speed must not be turned into metres and a
///   remembered *target* must not be stepped up — but a time goal needs no
///   trusted speed to know that a second passed, and a reduction measured
///   against the app's own last write is safe whatever the radio is doing;
/// - heart-rate control is the one feature that writes a target nobody asked
///   for, so its whole write surface is a single enum (`GovernorAction`) and
///   every path through it is enumerated on `steer(_:on:deltaSeconds:)`. Four
///   rules bound it: only the injected `GovernorHeartRateSource` may supply the
///   rate, only the session's frozen basis may set the band and the ceilings, a
///   change made on the console ends governing for the rest of the segment, and
///   the two ceilings' clocks belong to the workout rather than to the segment;
/// - the two ceilings have authority over *everything* this class writes once
///   they are armed, the segment boundaries included: the 97% stop is evaluated
///   at workout scope, above the run guard and the surrender guard, and a
///   boundary may not raise the load above `min(fact 1, fact 2)` while the 92%
///   tally is standing;
/// - what *arms* the ceilings is the opt-in, and nothing else. With heart-rate
///   control off there is no `GovernorSession` at all, so there is no clock for
///   a ceiling to fire on, no band, no stop and no boundary clamp — spec
///   section 4, "The ceilings belong to the opt-in" (finding 100);
/// - a stop the app asked for belongs to the client, whose lifetime is the
///   connection. Nothing here may cancel one, no program may start while one is
///   outstanding, and a running program ends rather than keeping its segments
///   marching over a belt the app has decided to stop.
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
        /// Consecutive measured seconds under a recovery goal's threshold, from
        /// the Watch feed alone. Measured for the same reason as the two above,
        /// and consecutive because one reading below a threshold is noise.
        var heartRateBelowSeconds: Double = 0
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
        /// `WatchHeartRateManager.freshHeartRate()`, 0 when there is none. The
        /// treadmill's handlebar byte must never arrive here: it drops to 0 the
        /// moment the user lets go, and this number ends segments.
        var heartRateBpm: Int = 0
        /// A recovery goal's threshold, 0 for every other goal. The number rather
        /// than the goal, so `accumulating` stays a function of plain values.
        var heartRateBelowThresholdBpm: Int = 0
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
    /// What heart-rate control is doing, nil for a segment that has no band.
    @Published private(set) var governorStatus: GovernorStatus?
    /// The band actually being held, nil whenever nothing is being steered. A
    /// view must not read the band off the segment: a segment can carry one while
    /// the opt-in is off, and then nothing is holding it — and even with the loop
    /// running the band being held is the *arbitrated* one, which the stored pair
    /// cannot answer on its own (`publishGovernedBand`).
    @Published private(set) var governedBandBpm: ClosedRange<Int>?
    /// Is the published band less than the segment asked for? The arbitration
    /// clamps a band whose upper edge reaches the force-down ceiling, and a
    /// dashboard that drew it silently would claim the loop is holding a target
    /// it has been forbidden to reach.
    @Published private(set) var governedBandIsReduced = false

    /// Why the governor stopped the belt, surviving `clearGoverning()` — the
    /// 97% ceiling ends the workout in the same tick that would otherwise be
    /// the only place to say so, `finish()` (through `clearGoverning()`) nils
    /// `governorStatus` and `isProgramActive` goes false with `runnerState`,
    /// and the dashboard's program panel is only drawn while a program is
    /// active. Without a fact that outlives both, the user is never told why
    /// their belt stopped (finding 116). Reset where a workout begins — from
    /// `beginWorkout()` for a program start, and from `forgetGovernorStopReason()`
    /// for the manual path that never calls it — never by `finish()` or `stop()`
    /// directly, so it is still there to read for as long as the finished
    /// workout is on screen.
    enum GovernorStopReason: Equatable, Sendable {
        case heartRateCeiling
    }
    @Published private(set) var governorStopReason: GovernorStopReason?

    /// Heart-rate control, default off (spec section 4). The setting lives here
    /// rather than in a screen's `@AppStorage` because the runner is the only
    /// thing that may act on it — a second copy could disagree with the one that
    /// steers the belt. A settings toggle binds to it, as it does to
    /// `HealthKitExporter.autoSave`.
    @Published var heartRateControlEnabled: Bool {
        didSet {
            UserDefaults.standard.set(heartRateControlEnabled,
                                      forKey: Self.heartRateControlDefaultsKey)
            guard !heartRateControlEnabled else { return }
            // Switching off takes effect at once and can only stop writes.
            // Switching on deliberately does not: starting a loop under a belt
            // that is already moving is a new automatic path to a target, and it
            // waits for the next segment instead.
            surrenderGoverning()
        }
    }

    /// The belt, behind the seam `TreadmillControlling` draws. A protocol and
    /// not the concrete client, for the same reason `GovernorHeartRateSource` is
    /// one: without it no test could construct a runner and drive its `tick`, so
    /// every safety property that lives in this class's statement order — the
    /// stop asked above the surrender guard, the hand-back latched before the
    /// ladder is consulted, the boundary clamp — was only ever tested against a
    /// hand-rolled copy of that order living in a test file (finding 103).
    private weak var client: (any TreadmillControlling)?
    /// The developer-toggled event log. **Observation only**: nothing this class
    /// decides may depend on it, every call site is a `record`/`note` and the
    /// governor itself is not instrumented at all. Settable rather than `let` so
    /// a test can point it at a temporary directory; the default is the one
    /// instance the app has, which keeps the composition root out of it (see
    /// `DiagnosticLog`).
    var diagnostics: DiagnosticLog = .shared
    private var timer: Timer?
    /// The workout's governor state, including the current segment's own. `tick()`
    /// reaches the loop through this and nothing else.
    private var governorSession: GovernorSession?
    /// The only heart rate the loop may see. A protocol with two named
    /// implementations rather than a `() -> Int` provider: a closure would accept
    /// `client.state.heartRate` — the handlebar byte phase 2 disqualified — at any
    /// call site, and this is the one input where a wrong source accelerates a
    /// belt. `FitShowTreadmillClient` deliberately does not conform.
    private weak var heartRateSource: (any GovernorHeartRateSource)?
    /// The frozen zone basis, typed for the same reason: `SessionRecorder`
    /// snapshots the pair when the session begins, while `ProfileStore` holds the
    /// live one, which a profile edit moves mid-workout.
    private weak var basisSource: SessionRecorder?

    init() {
        heartRateControlEnabled = Self.isHeartRateControlEnabled(in: .standard)
    }

    /// Wired once, at the composition root. Neither argument is reachable from a
    /// screen, and neither can be a closure over the handlebar sensor.
    func bindHeartRateControl(source: any GovernorHeartRateSource, basis: SessionRecorder) {
        heartRateSource = source
        basisSource = basis
    }
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
        // The recovery goal's own tally. A missing reading holds the count rather
        // than resetting it — silence is not evidence that a heart rate came down,
        // and a held count simply never reaches the threshold, which is the
        // required behaviour of a failed sensor.
        if input.heartRateBelowThresholdBpm > 0, input.heartRateBpm > 0 {
            next.heartRateBelowSeconds =
                input.heartRateBpm < input.heartRateBelowThresholdBpm
                ? next.heartRateBelowSeconds + delta : 0
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
            // Whichever comes first. The hold window is what keeps a single low
            // reading from ending the segment; with no feed at all the tally
            // stays at zero and the cap is the only condition, which is the
            // required behaviour of a failed sensor.
            return progress.heartRateBelowSeconds
                >= Double(WorkoutSegment.recoveryHeartRateHoldSeconds)
                || progress.elapsedSeconds >= Double(maxSeconds)
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

    // MARK: - Heart-rate control

    /// What the loop is doing, for the dashboard. A published enum rather than a
    /// view-side computation: whether a belt is being steered is this class's
    /// answer, and two screens deriving it could disagree.
    enum GovernorStatus: Equatable, Sendable {
        /// Inside the band, settling after a change, or at a bound it may not pass.
        case holding
        case adjusting
        /// 92% of the frozen maximum: the load comes down whatever the band says.
        case ceiling
        /// At the segment's upper bound, still below the band, past the stall
        /// window — the band is not reachable and the loop stopped pushing.
        case targetNotReached
        case frozen
        case fallback
        /// The user changed speed or incline: control is theirs for the rest of
        /// the segment.
        case handedBack
        /// The stop ceiling fired. The belt is stopping and the program is over.
        case stopping
        /// The opt-in is off, so the segment runs fixed at its start command.
        case controlOff
        /// No frozen basis: the band and both ceilings would be percentages of
        /// nothing, so nothing is steered.
        case noBasis
        /// The stored band or bounds cannot be steered with — the segment runs fixed.
        case targetNotUsable
        /// The band's lower edge is at or above the force-down ceiling derived
        /// from the same frozen basis. There is no load at which it could be
        /// held, so the segment runs fixed at its start command and says so —
        /// the app does not steer anyone into zone 5.
        case bandNotSteerable
        /// The treadmill link is stale, so the app's picture of the console's
        /// target is a remembered number and the dial may have been turned
        /// unseen. Nothing that adds load may be written from it.
        case linkStale
    }

    /// Whether a segment may be governed, and why not when it may not.
    /// `gate(for:isControlEnabled:entryCommand:)` is the only producer and
    /// `begin(_:at:)` the only caller, so a segment the gate refuses carries no
    /// governor state at all for a later edit of `tick()` to find.
    enum Gate: Equatable, Sendable {
        case notHeartRateDriven
        case controlOff
        case targetNotUsable
        case governed(GovernorRun)

        var run: GovernorRun? {
            if case .governed(let run) = self { return run }
            return nil
        }

        /// What the dashboard shows before the first evaluation. nil for a fixed
        /// segment: there is nothing to say about a loop that does not exist.
        var initialStatus: GovernorStatus? {
            switch self {
            case .notHeartRateDriven: return nil
            case .controlOff: return .controlOff
            case .targetNotUsable: return .targetNotUsable
            case .governed: return .holding
            }
        }
    }

    /// One governed segment's state between ticks: the clocks the governor's
    /// per-segment rules are stated in, the app's own last write, the load that was
    /// last observed, and the two latches. Everything a segment boundary may *not*
    /// reset lives one level up, in `GovernorSession`.
    struct GovernorRun: Equatable, Sendable {
        let target: HeartRateTarget
        var lastAppliedChange: HeartRateGovernor.Change
        var secondsSinceSegmentStart: Double = 0
        /// Since the app's own last write — the brake's rate limiter, which nothing
        /// a person does may postpone.
        var secondsSinceLastCommand: Double = 0
        /// Since the load last changed, whoever changed it: the settle window's own
        /// clock. See `observing(_:)`.
        var secondsSinceLoadChange: Double = 0
        /// The hand-back, latched for the rest of the segment. Re-detecting it at
        /// every evaluation would not be enough: a forced reduction rewrites the
        /// app's own last command, after which the user's value looks like ours.
        var isHandedBack = false
        /// The opt-in was switched off during this segment. The run is kept and
        /// made inert rather than thrown away — see `surrenderGoverning()`.
        var isSurrendered = false
        /// The observed load — fact 2 — that the settle window was last armed at.
        /// It starts at the app's own entry command, which is the load the segment
        /// asked for and the only number there is before a frame arrives.
        var observedLoad: HeartRateGovernor.Command

        init(target: HeartRateTarget, lastAppliedChange: HeartRateGovernor.Change) {
            self.target = target
            self.lastAppliedChange = lastAppliedChange
            observedLoad = lastAppliedChange.to
        }

        /// A write of the app's own: the settle window restarts, and the load it is
        /// measured from becomes the value just commanded — so the belt's journey to
        /// a command of ours is not read as a change of load somebody else made.
        mutating func commandApplied(_ change: HeartRateGovernor.Change) {
            lastAppliedChange = change
            secondsSinceLastCommand = 0
            secondsSinceLoadChange = 0
            observedLoad = change.to
        }

        /// One observation of the belt folded in. **Any observed change of load
        /// re-arms the settle window, not only the app's own** (finding 137): the
        /// window exists so the loop does not read a heart rate that still describes
        /// the load before the last change, and whose hand made that change has
        /// nothing to do with it. Armed only by the loop's own writes, the first step
        /// after a manual reduction went out ten seconds later from a reading that
        /// predated it — the loop pushing back up on a person who had just chosen to
        /// go slower.
        ///
        /// It re-arms *this* clock and never `secondsSinceLastCommand`, which is also
        /// the floor under two successive forced reductions: a dial may not postpone
        /// a brake. `HeartRateGovernor.isLoadChanged(from:to:)` is the threshold, and
        /// the reason this is not simply "the measurement moved".
        mutating func observing(_ load: HeartRateGovernor.Command) {
            guard HeartRateGovernor.isLoadChanged(from: observedLoad, to: load) else { return }
            secondsSinceLoadChange = 0
            observedLoad = load
        }
    }

    /// What belongs to the *workout* rather than to one of its segments: the
    /// frozen basis, the clocks the two ceilings and the lost feed are stated in,
    /// and the phase of the evaluation grid.
    ///
    /// The split is finding 64. The ceilings are properties of the person on the
    /// belt, and holding all of this per segment threw their evidence away at
    /// every boundary: the 97% stop needs 15 s of breach *and* an evaluation to
    /// act on it, evaluations sit on a 10 s grid, and the editor's shortest
    /// segment is 15 s — so a HIIT program of 15 s segments could hold a user
    /// above 97% of their frozen maximum indefinitely and never reach
    /// `requestStop()`, while even 60 s segments delayed the stop by up to 35 s.
    struct GovernorSession: Equatable, Sendable {
        /// Is heart-rate control still on? A session exists at all only where
        /// the opt-in was on when a segment began, and this goes false — never
        /// back to true — when the opt-in is switched off during one.
        ///
        /// It is what makes the two ceilings stop with the switch. Spec section
        /// 4, "The ceilings belong to the opt-in": the ceilings exist to protect
        /// a user *from the governor*, so an app that has just been told to stop
        /// steering may not go on intervening on a `220 - age` estimate — and it
        /// cannot matter whether the user switched the feature off before the
        /// workout or during it, or the brakes would depend on the timing of a
        /// settings tap.
        ///
        /// The session is kept rather than dropped only because
        /// `resumeCommand(for:run:)` needs the run: dropping it turns a later
        /// resume from "the loop's own last command" into "the segment's
        /// programmed start speed" and puts back a reduction the loop made for
        /// the user's safety (finding 68).
        private(set) var isControlOn = true
        /// Adopted the first time one is offered and never replaced.
        /// `SessionRecorder` freezes it when the session begins; this second
        /// latch is what makes it harmless that the session and the first segment
        /// start on the same second, in either order.
        private(set) var basis: HeartRateBasis?
        /// The person's clocks. Three of the fields inside are the exception and
        /// are cleared at every boundary — see `carriedOver(_:)`.
        var tallies = HeartRateGovernor.Tallies()
        /// The phase of the 10 s evaluation grid, measured from the workout's
        /// start and not the segment's: a grid re-anchored at every boundary
        /// pushes the first evaluation of a short segment past its own end.
        var secondsSinceEvaluation: Double = 0
        /// The current segment's state, nil for a segment the gate refused.
        var run: GovernorRun?

        /// Adopts a basis exactly once — see `basis`.
        mutating func adopt(_ offered: HeartRateBasis?) {
            guard basis == nil, let offered else { return }
            basis = offered
        }

        /// Entering a segment: the band-scoped tallies go, the person's stay.
        mutating func beginSegment(_ run: GovernorRun?) {
            self.run = run
            tallies = Self.carriedOver(tallies)
        }

        /// The opt-in, switched off during this segment. Everything about heart
        /// rate stops here — the run is made inert *and* the person's clocks are
        /// dropped, because a tally left standing is a ceiling still waiting to
        /// clamp the next segment boundary.
        mutating func surrender() {
            isControlOn = false
            tallies = HeartRateGovernor.Tallies()
            run?.isSurrendered = true
        }

        /// The session a new segment continues, or a fresh one.
        ///
        /// A session the opt-in was switched off during is never continued:
        /// `isControlOn` never goes back to true, so switching control on again
        /// is a *new* session that begins at a segment boundary — which is where
        /// `heartRateControlEnabled`'s setter says the loop may resume, and it is
        /// also what stops the switched-off session's dead clocks from being
        /// inherited by a workout that is being steered again.
        static func continuing(_ session: GovernorSession?) -> GovernorSession {
            guard let session, session.isControlOn else { return GovernorSession() }
            return session
        }

        /// The tallies a segment boundary may keep. The two ceilings and the feed
        /// belong to the person; "at the upper bound below the band" and the
        /// force-down signature belong to a *band*, which the next segment
        /// re-states — carrying those across would let one segment's unholdable
        /// band stop the next segment's reachable one from ever climbing.
        static func carriedOver(_ tallies: HeartRateGovernor.Tallies)
            -> HeartRateGovernor.Tallies {
            var next = tallies
            next.secondsAtUpperBoundBelowBand = 0
            next.didForceDown = false
            next.secondsBelowBandAfterForceDown = 0
            return next
        }
    }

    /// What the runner may do about a decision. The entire write surface of
    /// heart-rate control is this enum: `.write` and `.stop`.
    enum GovernorAction: Equatable, Sendable {
        case none
        case write(HeartRateGovernor.Command)
        case stop
        /// Latch the hand-back.
        case handBack
    }

    /// The opt-in's stored key. Off is the *absence* of the key, so no default
    /// has to be registered anywhere for the feature to ship switched off.
    nonisolated static let heartRateControlDefaultsKey = "heartRateControl.enabled"

    nonisolated static func isHeartRateControlEnabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: heartRateControlDefaultsKey)
    }

    /// Does this program ever ask for heart-rate control?
    ///
    /// The question is the *program's* and not the segment's, because a governor
    /// session is a workout's: a mixed program's fixed segments have to keep the
    /// person's clocks running (finding 64), while a program with no heart-rate
    /// segment anywhere has no governor for a ceiling to protect anybody from.
    /// That is the second half of the ruling's own complaint — the 92% and 97%
    /// rules armed "on programs containing no heart-rate segment" — and the same
    /// reasoning answers it as answers the opt-in: when the app is not steering,
    /// the user is, and it must not stop their belt on a `220 - age` estimate.
    nonisolated static func isHeartRateDriven(_ program: WorkoutProgram) -> Bool {
        program.segments.contains { $0.heartRateTarget != nil }
    }

    /// Whether this *segment* may be governed. The opt-in is checked here and in
    /// `startGoverning`, and the two questions are different ones: this is "may
    /// the loop steer this segment", that is "may this workout hold heart-rate
    /// state at all". With the setting off both refuse, no session and no run
    /// exist, and `steer` has nothing to evaluate — the segment runs fixed at its
    /// start command, which is what `apply(_:)` already sent.
    nonisolated static func gate(for segment: WorkoutSegment,
                                 isControlEnabled: Bool,
                                 entry: HeartRateGovernor.Change) -> Gate {
        guard let target = segment.heartRateTarget else { return .notHeartRateDriven }
        // The switch first: with control off, nothing about the payload matters.
        guard isControlEnabled else { return .controlOff }
        guard target.isUsable else { return .targetNotUsable }
        return .governed(GovernorRun(target: target, lastAppliedChange: entry))
    }

    /// The band handed to the tallies for a segment nothing is steering. The
    /// person's clocks — the two ceilings and the lost feed — must keep running
    /// across a fixed segment: they belong to the person, so a boundary may
    /// neither reset them (finding 64) nor freeze them, or a breach that ended
    /// during a fixed segment would still be standing at the next governed
    /// segment's first evaluation and stop a belt for nothing.
    /// `HeartRateGovernor.Tallies.advanced` is the one implementation of those
    /// clocks, and a band no reading can fall below, with no bound to sit at,
    /// leaves its three band-scoped fields exactly where the boundary put them.
    nonisolated private static let ungovernedBand = 0...0

    /// One tick folded into the workout's governor state. Clamped to
    /// `maxTickSeconds` for the same reason the segment tally is — a tick is not a
    /// second — and the under-credit is the safe direction: every settle window
    /// lasts longer, and a ceiling the app was not running to act on fires when
    /// it is.
    nonisolated static func advancing(_ session: GovernorSession,
                                      bySeconds deltaSeconds: Double,
                                      heartRate: Int, basis: HeartRateBasis?,
                                      command: HeartRateGovernor.Command,
                                      belt: HeartRateGovernor.BeltFacts,
                                      limits: TreadmillLimits) -> GovernorSession {
        guard deltaSeconds.isFinite, deltaSeconds > 0 else { return session }
        // The opt-in went off during this segment: nothing about heart rate may
        // touch the belt from here on, and a clock that kept running would be a
        // ceiling that fires fifteen seconds later. `surrender()` has already
        // zeroed the tallies; this is what keeps them zero.
        guard session.isControlOn else { return session }
        var next = session
        next.adopt(basis)
        let delta = min(deltaSeconds, maxTickSeconds)
        next.secondsSinceEvaluation += delta
        if var run = next.run {
            run.secondsSinceSegmentStart += delta
            run.secondsSinceLastCommand += delta
            run.secondsSinceLoadChange += delta
            // Fact 2, this tick: an observed change of load re-arms the settle
            // window whoever made it — see `GovernorRun.observing(_:)` (finding
            // 137). Nothing is observed while the link is stale, so a remembered
            // measurement re-arms nothing.
            if let measured = belt.measured { run.observing(measured) }
            next.run = run
        }
        // No basis, no ceilings: there is nothing to count a reading against
        // until the session's frozen pair exists.
        guard let basis = next.basis else { return next }
        let ceilings = HeartRateGovernor.ceilings(for: basis)
        guard let run = next.run else {
            next.tallies = next.tallies.advanced(bySeconds: delta, heartRate: heartRate,
                                                 ceilings: ceilings, band: ungovernedBand,
                                                 isAtUpperBound: false)
            return next
        }
        // The bound test is the governor's own predicate, so the tally counted here
        // and the ladder's `stalledAtUpperBound` rung cannot disagree about being
        // at the bound. It is asked of two things: fact 1 — the app's own last
        // write, which no incoming frame may move — and the reference the ladder
        // measures from, `min(fact 1, fact 2)` per axis with facts 2 and 3 folded
        // in, which only has to be within one step of the bound. An exact test
        // against the reference alone zeroed the tally on any tick the belt
        // reported a tenth short, so a console with a persistent one-tenth bias
        // never filled the 120 s window and the give-up rule never fired.
        let reference = HeartRateGovernor.reference(command: command,
                                                    lastAppliedChange: run.lastAppliedChange,
                                                    belt: belt)
        next.tallies = next.tallies.advanced(
            bySeconds: delta, heartRate: heartRate, ceilings: ceilings,
            band: HeartRateGovernor.band(for: run.target),
            isAtUpperBound: HeartRateGovernor.isAtUpperBound(
                reference: reference, appCommand: run.lastAppliedChange.to,
                target: run.target, limits: limits))
        return next
    }

    nonisolated static func isEvaluationDue(_ session: GovernorSession) -> Bool {
        session.secondsSinceEvaluation >= HeartRateGovernor.evaluationIntervalSeconds
    }

    // MARK: - The two ceilings, at workout scope

    /// Has the stop ceiling's hold window been reached? The tally and nothing
    /// else — no run, no band, no bounds, no opt-in.
    ///
    /// This is the rung `HeartRateGovernor` states as `.stopCeiling`, asked at
    /// workout scope because that is the scope the thing it protects has: the
    /// ceiling is a property of the person on the belt. Read only inside the
    /// ladder it was skippable three ways (finding 81) — a segment the gate
    /// refused evaluates no rung at all, a surrendered run evaluated nothing
    /// either, and a segment boundary landing between two evaluations wrote the
    /// next segment's entry command into the gap while the tally stood one second
    /// short of its window.
    ///
    /// Asked every tick rather than on the 10 s evaluation grid, too. That grid
    /// exists so the loop does not chase the transients its own changes cause,
    /// which is a statement about *steering*; the stop already has a 15 s hold
    /// window of its own and does not need a second one on top.
    ///
    /// What it is *not* above is the opt-in. A session exists only where
    /// heart-rate control was on, and `isControlOn` is what takes the stop away
    /// again when the switch goes off mid-workout — spec section 4, "The ceilings
    /// belong to the opt-in" (finding 100). Before that ruling this rung was read
    /// from the tally alone on every program workout, so a user who had never
    /// switched heart-rate control on, and to whom the app had never disclosed
    /// that it acts on heart rate, could have their belt stopped mid-run on a
    /// `220 - age` estimate.
    nonisolated static func isStopCeilingReached(_ session: GovernorSession) -> Bool {
        session.isControlOn
            && session.tallies.secondsAboveStopCeiling >= HeartRateGovernor.stopHoldSeconds
    }

    /// Is the person above the force-down ceiling now, or have they been during
    /// the segment that is ending? From the tallies alone, for the same reason:
    /// a segment with no governor run still runs the person's clocks, and the
    /// write this gates is a write such a segment makes.
    ///
    /// Either half is enough. A standing tally is the person above the line this
    /// second; the latch is the ceiling having already had to pull the load back,
    /// which is evidence about a load the next segment is about to raise. Both
    /// are cleared where they should be — the tally by a reading below the
    /// ceiling, the latch by the next segment boundary.
    /// nil, and a session the opt-in was switched off during, both read as "no
    /// ceiling": with heart-rate control off there is no ceiling to stand, so
    /// nothing clamps a boundary either (finding 100).
    nonisolated static func isForceDownCeilingStanding(_ session: GovernorSession?) -> Bool {
        guard let session, session.isControlOn else { return false }
        return session.tallies.secondsAboveForceDownCeiling > 0 || session.tallies.didForceDown
    }

    /// A programmed command with the force-down ceiling's authority over it.
    ///
    /// A segment boundary writes the next segment's entry command
    /// unconditionally, and that write is the one load-adding path in this class
    /// the governor's ladder never sees. Entering a 12.0 km/h segment from a
    /// 6.0 km/h recovery while the person stands at 94% of their frozen maximum
    /// is a 6 km/h acceleration into somebody already above the line, which the
    /// force-down rule then unwinds at 0.2 km/h every 10 s (finding 82).
    ///
    /// So while the ceiling stands, the entry is clamped: a boundary may restate
    /// the load, never add to it. *What* it is clamped to is the caller's, and
    /// the two callers pass different references on purpose — see
    /// `ceilingReference(appCommand:belt:)` for the boundary's and
    /// `reapplyOnResume` for the resume's.
    nonisolated static func boundedByCeiling(_ command: HeartRateGovernor.Command,
                                             notAbove bound: HeartRateGovernor.Command,
                                             isCeilingStanding: Bool)
        -> HeartRateGovernor.Command {
        guard isCeilingStanding else { return command }
        // Tenths, like every other comparison of two speeds: one quantum is
        // 0.09999999999999964 as a `Double`.
        let units = min(HeartRateGovernor.speedUnits(command.speedKmh),
                        HeartRateGovernor.speedUnits(bound.speedKmh))
        return HeartRateGovernor.Command(speedKmh: HeartRateGovernor.speedKmh(units: units),
                                         incline: min(command.incline, bound.incline))
    }

    /// What a **segment boundary** may be clamped to while a ceiling stands:
    /// `min(fact 1, fact 2)` per axis, the same reference the governor's ladder
    /// measures every one of its steps from.
    ///
    /// Fact 1 alone was finding 101, and the reproduction is a hand-back: after a
    /// console change nothing ever lowers the app's own command — that is the
    /// whole point of fact 1 — so it diverges upward from the belt and stays
    /// there. Segment 1 is governed with an entry write of 10.0; at 0:40 the user
    /// dials the console to 6.0 and the hand-back latches; at 2:55 the heart rate
    /// crosses the force-down ceiling; and the boundary into segment 2 then wrote
    /// the app's own 10.0 — four km/h added to a belt whose user is above the very
    /// line the dashboard was reporting the app as holding them under.
    ///
    /// The cost of this direction is a fixed segment entered while the belt is
    /// mid-ramp running below its programmed value for the rest of the segment,
    /// with no loop there to climb back off it. That is the safe error, and it can
    /// only happen while somebody is above 92% of their frozen maximum — the one
    /// moment when a belt running slower than the plan is the right answer.
    ///
    /// A measured **0** is excluded on the speed axis, as it is in the client's
    /// own `boundedByStop`: 0 km/h is a belt that has stopped, not a target the
    /// machine can be set to. A measured 0% incline is a legitimate setting and is
    /// folded in.
    nonisolated static func ceilingReference(appCommand: HeartRateGovernor.Command,
                                             belt: HeartRateGovernor.BeltFacts)
        -> HeartRateGovernor.Command {
        guard let measured = belt.measured else { return appCommand }
        let appUnits = HeartRateGovernor.speedUnits(appCommand.speedKmh)
        let measuredUnits = HeartRateGovernor.speedUnits(measured.speedKmh)
        let units = measuredUnits > 0 ? min(appUnits, measuredUnits) : appUnits
        return HeartRateGovernor.Command(speedKmh: HeartRateGovernor.speedKmh(units: units),
                                         incline: min(appCommand.incline, measured.incline))
    }

    /// The governor's input: the segment's run and the workout's tallies, plus
    /// the values that must be read live — the client's own target, the heart
    /// rate from the injected source, and the belt's own facts.
    ///
    /// `belt` carries facts 2 and 3 (`FitShowTreadmillClient.beltFacts`) and has
    /// no default here on purpose. `HeartRateGovernor.Input.belt` has one, and
    /// while this function did not pass it the mandatory hand-back could not fire
    /// in production at all: the governor infers a person from fact 3 and nothing
    /// else, so a fact silently defaulting to `.unobserved` is the whole feature
    /// missing. A required argument is what makes that undroppable.
    ///
    /// `appCommand` is required for the same reason. It is **fact 1 live** —
    /// `FitShowTreadmillClient.commandedSpeedKmh` / `commandedIncline`, which no
    /// incoming frame may move — and it is what the axis the segment does *not*
    /// steer is passed through from. `HeartRateGovernor.Input.appCommand` defaults
    /// to nil, and nil degrades the pass-through to `min(the client's target, the
    /// app's last recorded write)`: exact inside the client's 10 s hold-off and
    /// following the belt afterwards, so a hills segment programmed at 8% whose
    /// motor is still travelling through 2% would come out of a fallback at 2%
    /// (finding 99).
    nonisolated static func governorInput(_ session: GovernorSession, run: GovernorRun,
                                          basis: HeartRateBasis, heartRate: Int,
                                          command: HeartRateGovernor.Command,
                                          appCommand: HeartRateGovernor.Command,
                                          belt: HeartRateGovernor.BeltFacts,
                                          limits: TreadmillLimits) -> HeartRateGovernor.Input {
        HeartRateGovernor.Input(
            target: run.target, basis: basis, limits: limits, heartRate: heartRate,
            command: command, lastAppliedChange: run.lastAppliedChange,
            appCommand: appCommand,
            secondsSinceSegmentStart: run.secondsSinceSegmentStart,
            secondsSinceLastCommand: run.secondsSinceLastCommand,
            secondsSinceLoadChange: run.secondsSinceLoadChange, tallies: session.tallies,
            belt: belt)
    }

    /// Which decisions a stale treadmill link refuses: **every target write the
    /// governor produces**. Only the emergency stop survives.
    ///
    /// While `staleData` is set no frame has arrived for longer than the client's
    /// freshness horizon, so a console the user has turned down by hand still reads
    /// as the app's own last write and the manual test sees nothing. Writes still
    /// *succeed* in that state — losing notifications is not losing the write
    /// characteristic — so anything computed from that picture is delivered to a
    /// belt nobody can see (finding 66).
    ///
    /// This used to refuse `.belowBand` alone, on the reasoning that every other
    /// write is a reduction against the app's own last write by construction. The
    /// reasoning is true and it is the wrong invariant (finding 136): while the link
    /// is stale the measured speed, the client's target and the app's command are
    /// *all* remembered numbers, so a force-down, a fallback or an above-band step
    /// can write a value well above the speed the user has just dialled down unseen.
    /// The belt then accelerates back toward the app's own command while the
    /// dashboard reports a reduction.
    ///
    /// The emergency stop stays, because it needs no trustworthy picture of
    /// anything: it writes no target, it can only end the workout, and the radio gap
    /// that lets a heart rate sit unobserved at 97% of the frozen maximum is exactly
    /// the gap that would otherwise silence it.
    ///
    /// **Staleness has produced four findings in this release and three different
    /// correct answers, which is not an inconsistency**: the question each time is
    /// *which* number the silence made a memory. Phase 1 had to stop the distance
    /// integral and not the segment clock — there the untrusted number was the
    /// belt's measured speed, while a second is a second whatever the radio does.
    /// Here everything that describes the belt is remembered while the heart rate
    /// arrives on an independent feed that is genuinely fresh, so the tallies keep
    /// advancing, both ceilings keep counting, and only the load may not move.
    nonisolated static func isRefusedWhileStale(_ decision: HeartRateGovernor.Decision) -> Bool {
        switch decision {
        case .adjust, .fallback: return true
        // A hand-back writes nothing and only ever takes authority away from the
        // loop, so latching one from remembered evidence is the safe direction.
        case .emergencyStop, .hold, .frozen, .manualControl: return false
        }
    }

    /// Three decisions may still write once control has been handed back, and
    /// every one of them can only restate or lower the load: the 92% force-down,
    /// the 97% stop, and the feed-loss fallback. The user who nudged the dial
    /// keeps the gentle step-down and the dead-feed answer instead of only the
    /// belt stop.
    ///
    /// The fallback used to be refused here, which meant a *falsely* inferred
    /// person silently disabled the one rule that answers a dead feed — spec
    /// section 4, "The fallback survives a hand-back, for the same reason the
    /// ceilings do" (finding 98). The governor's own ladder already says so: the
    /// `feedLostFallback` rung sits above `manualControl`, so refusing it here
    /// was this function disagreeing with the law it acts on.
    nonisolated static func action(for decision: HeartRateGovernor.Decision,
                                  isHandedBack: Bool,
                                  isLinkStale: Bool = false) -> GovernorAction {
        if isLinkStale, isRefusedWhileStale(decision) { return .none }
        switch decision {
        case .emergencyStop:
            return .stop
        case .adjust(let command, .ceilingForceDown):
            return .write(command)
        case .fallback(let command):
            return .write(command)
        case .adjust(let command, _):
            return isHandedBack ? .none : .write(command)
        case .manualControl:
            return .handBack
        case .hold, .frozen:
            return .none
        }
    }

    /// The decision as the dashboard reads it.
    nonisolated static func status(for decision: HeartRateGovernor.Decision,
                                  isHandedBack: Bool,
                                  isLinkStale: Bool = false) -> GovernorStatus {
        // What the stale link refused has to read as the stale link and not as
        // the decision it swallowed: "adjusting" while nothing was sent is the
        // one thing the dashboard must not say.
        if isLinkStale, isRefusedWhileStale(decision) { return .linkStale }
        switch decision {
        case .emergencyStop:
            return .stopping
        case .adjust(_, .ceilingForceDown), .hold(.ceilingForceDown):
            // The ceilings outrank the hand-back, so they outrank its label too.
            return .ceiling
        case .fallback:
            // And so does the fallback, for exactly the same reason: it writes
            // under a hand-back now, and "control is yours" while the app is
            // lowering the belt is the one thing the dashboard must not say
            // (finding 98). `.frozen` deliberately stays *below* the hand-back
            // instead: the governor's ladder puts `feedLostFallback` above
            // `manualControl` and `feedLostFreeze` below it, this function
            // mirrors that order, and a freeze writes nothing — so the hand-back
            // is both the truthful label and the more useful one.
            return .fallback
        case .manualControl:
            return .handedBack
        case _ where isHandedBack:
            return .handedBack
        case .frozen:
            return .frozen
        case .hold(.targetUnreachable):
            return .targetNotReached
        case .hold(.bandNotSteerable):
            return .bandNotSteerable
        case .adjust:
            return .adjusting
        case .hold:
            return .holding
        }
    }

    /// What a resume re-writes, and the one place that knows a governed segment
    /// does not resume at its start speed: a segment the loop has already reduced
    /// must not climb back to the programmed value on a pause, and a segment the
    /// user has taken over must not be written at all.
    ///
    /// This is why switching the opt-in off mid-segment keeps the run and makes
    /// it inert instead of dropping it (`surrenderGoverning()`). A run that is
    /// gone reads here as a plain fixed segment, and the resume then writes the
    /// segment's *programmed* start — 10.0 km/h on a segment the loop had already
    /// forced down to 7.0 because the user hit 92% of their maximum, which is
    /// exactly the reaction "stop steering my belt" would earn (finding 68).
    ///
    /// What it deliberately does not do is test the client's *target* for a change
    /// made during the suspension. A console restart ramps the belt from zero and
    /// the client adopts that ramp as its target, so the test would fire on almost
    /// every resume and quietly disable the loop for the segment. The write stays
    /// bounded by the segment's own bounds either way. The change a resume *does*
    /// have to see is fact 3, the dial verdict, and it arrives through the latch —
    /// see `resuming(_:belt:)`.
    nonisolated static func resumeCommand(for segment: WorkoutSegment,
                                          run: GovernorRun?)
        -> HeartRateGovernor.Command? {
        guard let run else {
            return HeartRateGovernor.Command(speedKmh: segment.nominalSpeedKmh,
                                             incline: segment.nominalIncline)
        }
        return run.isHandedBack ? nil : run.lastAppliedChange.to
    }

    /// The run a resume decides from: the hand-back latch **refreshed from the
    /// evidence** before anything works out what to write.
    ///
    /// The latch is otherwise mutated in exactly one place — `steer`, on the
    /// evaluation grid — and `steer` does not run while the program is suspended. So
    /// at a resume it is stale by exactly the amount that matters (finding 135): a
    /// user who pauses on the console, dials the speed down and restarts got the
    /// loop's remembered command written straight back over the value they had just
    /// chosen, because `resumeCommand` read a latch that still said nobody had
    /// touched anything.
    ///
    /// The evidence was there to be read the whole time. Fact 3 is the client's, it
    /// is inferred at frame cadence from the measured values, and the client's
    /// lifetime is the connection rather than this program's `.running` state.
    nonisolated static func resuming(_ run: GovernorRun,
                                     belt: HeartRateGovernor.BeltFacts) -> GovernorRun {
        var next = run
        next.isHandedBack = next.isHandedBack || belt.isSetByHand
        return next
    }

    // MARK: - A stop belongs to the client, not to the program

    /// The two statuses that mean the belt has *stopped* rather than paused —
    /// this class's only reading of "no longer running", and the same distinction
    /// `FitShowTreadmillClient.isObservedStopped(status:frameAge:)` makes.
    ///
    /// A console winding the belt down reports `paused`, and so does a console
    /// the user can resume from, so reading either as a confirmed stop is one of
    /// the three ways a stop got abandoned (finding 84): the runner's own
    /// insistence took a single `paused` frame arriving between two running
    /// frames as the belt having obeyed, and stopped asking. The insistence is
    /// the client's now; this predicate is what is left, and it decides suspend
    /// versus abort and nothing about a stop.
    nonisolated static func isBeltStopped(_ status: FitShow.Status) -> Bool {
        status == .idle || status == .end
    }

    /// May a program run on this belt at all — start, arm, or keep going?
    ///
    /// A stop the app asked for outlives the program that asked (spec section 4),
    /// and the two start paths are exactly how a program could cancel one: `arm`
    /// ends in `client.startBelt`, the one call that clears an outstanding stop,
    /// and `start` writes the first segment's target onto a belt the app has just
    /// decided to stop. Neither is the explicit, present-tense user action that
    /// earns the right to cancel a stop — that is the dashboard's own start
    /// button, on a belt the user is looking at.
    ///
    /// **Both halves of the client's fact**, because each covers exactly what the
    /// other cannot (finding 102). `stopNotObeyed` is the durable half: it is set
    /// once the belt has had `FitShowTreadmillClient.stopFailureSeconds(fromSpeedKmh:)`
    /// to obey and it survives the insistence giving up — but it is false for the
    /// whole of that window and for the whole of a disconnect, which is where a
    /// program could be armed and started, cancelling the app's own stop.
    /// `isStopOutstanding` is true from the first attempt onward and covers both.
    ///
    /// A *running* program asks the same question, for the same reason: the client
    /// clamps every write down while a stop stands, so the belt cannot be
    /// accelerated, but a runner that kept ticking would still cross segment
    /// boundaries and still publish a governor status claiming it was steering
    /// (finding 94).
    nonisolated static func isRefusedByOutstandingStop(isStopOutstanding: Bool,
                                                       stopNotObeyed: Bool) -> Bool {
        isStopOutstanding || stopNotObeyed
    }

    /// What an outstanding stop does to a program in a given state. A function
    /// rather than a branch inside `tick()`, so "no state may write a target onto
    /// a belt the app has decided to stop" is a property something tests.
    enum StopOutcome: Equatable, Sendable {
        /// Terminal states: there is nothing left to take away.
        case nothingToDo
        /// A workout that was running ends. It does **not** ask the belt to stop
        /// again: the client's insistence is already running and its lifetime is
        /// the connection, not this program's.
        case finish
        /// Nothing ran yet — the countdown and the wait for the belt both end in
        /// a write or in `startBelt` — so the program goes rather than the stop.
        case abandon
    }

    nonisolated static func outcome(whileStopOutstanding isRefused: Bool,
                                   in state: RunnerState) -> StopOutcome {
        guard isRefused else { return .nothingToDo }
        switch state {
        case .idle, .finished: return .nothingToDo
        case .armed, .waitingForBelt: return .abandon
        case .running, .suspended: return .finish
        }
    }

    /// A recovery goal's threshold, 0 for a goal that has none.
    nonisolated static func heartRateBelowThresholdBpm(_ goal: SegmentGoal) -> Int {
        if case .untilHeartRateBelow(let bpm, _) = goal { return bpm }
        return 0
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
    func start(_ program: WorkoutProgram, on client: any TreadmillControlling) {
        guard client.state.isRunning, let first = program.segments.first else { return }
        // A stop of the app's own is still outstanding: this belt is one the app
        // has decided to stop, and a program writing segment targets onto it is
        // the opposite of that decision.
        guard !Self.isRefusedByOutstandingStop(isStopOutstanding: client.isStopOutstanding,
                                               stopNotObeyed: client.stopNotObeyed)
        else { return }
        self.program = program
        self.client = client
        // A workout's scope starts here, so what belongs to a workout is dropped
        // here: the previous run's ceiling clocks are not evidence about this one,
        // and its outstanding stop is not this program's problem.
        beginWorkout()
        begin(first, at: 0)
        startTimer()
    }

    /// Arming a program on a standing belt — it is the caller's responsibility to
    /// call this only after a user confirmation. After the countdown the app starts
    /// the belt itself with the first segment's targets.
    func arm(_ program: WorkoutProgram, on client: any TreadmillControlling) {
        guard !client.state.isRunning, !program.segments.isEmpty else { return }
        // The countdown ends in `client.startBelt`, which cancels an outstanding
        // stop — so arming a program while one is outstanding is a way for the
        // app to overrule its own stop five seconds later.
        guard !Self.isRefusedByOutstandingStop(isStopOutstanding: client.isStopOutstanding,
                                               stopNotObeyed: client.stopNotObeyed)
        else { return }
        self.program = program
        self.client = client
        beginWorkout()
        runnerState = .armed(remaining: Self.armCountdownSeconds)
        startTimer()
    }

    /// The workout's own scope, opened. See `GovernorSession`: the two ceilings
    /// belong to the person and are reset where a workout begins and ends, never
    /// where a segment does.
    ///
    /// It deliberately clears nothing about a stop. A stop the app asked for is
    /// not this workout's to forget, and the two start paths above have already
    /// refused to run while one is outstanding.
    private func beginWorkout() {
        clearGoverning()
        // A new workout's scope starts here, so the previous one's stop reason
        // is not evidence about this one — see `governorStopReason`.
        governorStopReason = nil
        // …and so does the diagnostic log's file, for the same reason: the frame
        // every later line is read against — the opt-in, the frozen basis, the
        // device's limits — is this workout's and not the last one's.
        guard let program, let client else { return }
        diagnostics.beginWorkout(
            DiagnosticLog.workoutFields(program: program,
                                        isHeartRateDriven: Self.isHeartRateDriven(program),
                                        isControlEnabled: heartRateControlEnabled,
                                        isDemo: diagnostics.demoMode,
                                        basis: basisSource?.heartRateBasis,
                                        limits: client.limits))
    }

    /// The other place a workout begins. `beginWorkout()` only runs on the
    /// program paths (`start(_:on:)`, `arm(_:on:)`); a manual start goes through
    /// neither, so it never clears `governorStopReason` on its own. Without this,
    /// a program that stopped itself on the 97% ceiling would leave the reason
    /// standing for whatever workout the recorder starts next — including a
    /// plain manual one — and `SessionRecorder`'s latch would promote it onto
    /// that later recording. `SessionRecorder.begin()` calls this once its own
    /// new session exists, so the next tick's latch has nothing stale left to
    /// read.
    func forgetGovernorStopReason() {
        governorStopReason = nil
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

    /// The program, taken down. It is reached from an ordinary navigation to the
    /// home screen and from the dashboard's × button, so it must be safe to call
    /// on a belt that is still moving above the stop ceiling — which is why it no
    /// longer touches a stop at all.
    ///
    /// It used to drop the runner's own outstanding stop *and* invalidate the
    /// timer that re-issued it (finding 83): navigating home was enough to make
    /// the app forget it had asked a belt to stop. The insistence lives in the
    /// client now, whose lifetime is the connection, and there is nothing here
    /// left for a teardown to cancel.
    func stop() {
        // Only a program that was still live has an end to report: this method is
        // reached from an ordinary navigation home too, and `finish()` has
        // already written the line for a workout that ended on its own.
        switch runnerState {
        case .armed, .waitingForBelt, .running, .suspended: logWorkoutEnded(.tornDown)
        case .idle, .finished: break
        }
        timer?.invalidate()
        timer = nil
        program = nil
        runnerState = .idle
        segmentProgress = SegmentProgress()
        clearGoverning()
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

    /// The timer's tick. The anchor is read here and only here, so the injected
    /// path below cannot touch a wall clock.
    private func tick() {
        // Read once per tick, whatever the state: the anchor has to move even on
        // the branches that integrate nothing.
        tick(bySeconds: measuredTickSeconds())
    }

    /// One tick, with the measured delta handed in.
    ///
    /// Internal and delta-taking so a test can drive a real runner over a
    /// scripted trace instead of waiting on a 1 Hz timer — the injected-clock
    /// rule of `Fable/en/swiftui-ios.md` applied to the one class in this feature
    /// that had no seam for it. Every safety property that lives in the statement
    /// order below and nowhere else was untested against shipped code until this
    /// existed (finding 103).
    func tick(bySeconds deltaSeconds: Double) {
        guard let program, let client else { return }
        // A stop of the app's own, above everything: every state below either
        // writes a target onto the belt or advances toward doing so, and this
        // belt is one the app has decided to stop. See
        // `isRefusedByOutstandingStop` for why both halves of the client's fact
        // are read (findings 94, 102).
        switch Self.outcome(whileStopOutstanding:
                                Self.isRefusedByOutstandingStop(
                                    isStopOutstanding: client.isStopOutstanding,
                                    stopNotObeyed: client.stopNotObeyed),
                            in: runnerState) {
        case .nothingToDo:
            break
        case .finish:
            return finish(reason: .stopOutstanding)
        case .abandon:
            return stop()
        }

        switch runnerState {
        case .armed(let remaining):
            let next = remaining - 1
            if next > 0 {
                runnerState = .armed(remaining: next)
            } else if let first = program.segments.first {
                // `startBelt` is the one call in this class that cancels an
                // outstanding stop. What keeps a stop that appeared during the
                // countdown from being cancelled here is the guard at the top of
                // this method, which abandons an armed program on the tick the
                // stop shows up rather than five seconds later.
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
                if Self.isBeltStopped(client.state.status) {
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
            // Read once per tick, from the injected source and nowhere else. A
            // missing source reads as no reading, which freezes the loop and then
            // falls back — it can never accelerate anything.
            let heartRate = heartRateSource?.governorHeartRateBpm() ?? 0
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
                                isDataStale: client.staleData,
                                heartRateBpm: heartRate,
                                heartRateBelowThresholdBpm:
                                    Self.heartRateBelowThresholdBpm(segment.goal)))
            // The feed's own edges and a recovery goal's crossings, logged from
            // the one place that has both the reading and the measured delta.
            // Both are transition-only: the level is in every evaluation line
            // already, and a line per second would bury the decisions.
            diagnostics.noteHeartRateFeed(bpm: heartRate, deltaSeconds: deltaSeconds)
            diagnostics.noteRecovery(
                thresholdBpm: Self.heartRateBelowThresholdBpm(segment.goal),
                heartRateBpm: heartRate,
                holdSeconds: segmentProgress.heartRateBelowSeconds,
                requiredSeconds: Double(WorkoutSegment.recoveryHeartRateHoldSeconds))
            // Before the completion check on purpose: a stop ceiling that fires on
            // the tick a segment ends has to stop the belt, not hand over to the
            // next segment and write its target.
            guard steer(segment, on: client, deltaSeconds: deltaSeconds,
                        heartRate: heartRate) else { return }
            guard Self.isComplete(goal: segment.goal, progress: segmentProgress) else {
                runnerState = .running(segmentIndex: index,
                                       remaining: Self.remainingInterval(for: segment,
                                                                         progress: segmentProgress))
                return
            }
            diagnostics.record(.segmentEnded,
                               [.int("index", index),
                                .text("reason", "goalReached"),
                                .seconds("elapsedSeconds", segmentProgress.elapsedSeconds),
                                .km("distanceKm", segmentProgress.distanceKm),
                                .seconds("heartRateBelowSeconds",
                                         segmentProgress.heartRateBelowSeconds)])
            let nextIndex = index + 1
            if program.segments.indices.contains(nextIndex) {
                begin(program.segments[nextIndex], at: nextIndex)
            } else {
                finishAndStop(client, reason: .programComplete)
            }

        case .suspended(let index, let remaining):
            if client.state.isRunning && client.state.speedKmh > 0 {
                // We only resume on an actually moving belt (#181). A staleness
                // check here would only delay this: every route into `.suspended`
                // has seen the belt not running or standing still, and a stale
                // frame is the remembered copy of exactly that frame.
                runnerState = .running(segmentIndex: index, remaining: remaining)
                if let segment = currentSegment { reapplyOnResume(segment, on: client) }
            } else if Self.isBeltStopped(client.state.status) {
                // It turned into a full stop rather than a pause: the program is aborted.
                stop()
            }

        case .finished, .idle:
            // Terminal. `finishAndStop` has already handed the stop to the client,
            // which re-issues it on its own 200 ms poll until the belt is observed
            // idle or ended — so there is nothing here for a program to insist on,
            // and nothing a torn-down timer could take with it (finding 83).
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
        // The entry write and the run's idea of it are one thing: what the loop
        // starts from has to be the write the runner actually made. Hence the
        // write happens first and hands its own change over — together with
        // whether the ceiling clamped it, which is the one thing the entry knows
        // and the gate cannot work out for itself.
        let entry = apply(segment)
        // Retires the console-dial verdict and the pending departure from
        // whatever segment just ended, while the travel bookkeeping and the
        // observation history stay — spec section 4, "Governing resumes at
        // the next segment" (finding 114). `apply`'s write alone does not do
        // this: `commanded` only releases on an exact match, and an entry
        // ramp rarely lands on one, so a hand-back latched near the end of
        // the previous segment would otherwise still read as "set by hand"
        // through this segment's first evaluation. Order relative to
        // `apply(segment)` does not matter: a control-loop write never sets
        // the verdict, only a boundary or an exact-match observation clears it.
        client?.segmentBegan()
        startGoverning(segment, entry: entry.change,
                       isEntryClampedByCeiling: entry.isClampedByCeiling)
        // After `startGoverning`, so the line carries the arbitration and the
        // status the gate actually produced rather than what this method hoped
        // for. The arbitration is recomputed from the same pure function
        // `publishGovernedBand` uses; it decides nothing here.
        diagnostics.record(.segmentStarted, DiagnosticLog.segmentFields(
            index: index, segment: segment, entry: entry.change.to,
            isEntryClampedByCeiling: entry.isClampedByCeiling,
            arbitration: arbitrationForLog(), status: governorStatus))
    }

    /// The arbitration a `segmentStarted` line reports, or nil when nothing is
    /// steering this segment. Log-only, and it computes nothing the loop does not
    /// already compute for itself in `publishGovernedBand`.
    private func arbitrationForLog() -> HeartRateGovernor.BandArbitration? {
        guard let run = governorSession?.run, let basis = governorSession?.basis,
              !run.isSurrendered else { return nil }
        return HeartRateGovernor.arbitration(for: run.target, basis: basis)
    }

    /// The segment's own command, reported as the change it made. Deliberately
    /// not `@discardableResult`: dropping this change on the floor is finding 67.
    ///
    /// The entry command passes through `boundedByCeiling` first, and it is read
    /// *before* `GovernorSession.beginSegment` clears the band-scoped tallies —
    /// the boundary's write is a statement about the person the segment just
    /// ended on, not about the one the next segment hopes for (finding 82).
    private func apply(_ segment: WorkoutSegment)
        -> (change: HeartRateGovernor.Change, isClampedByCeiling: Bool) {
        let programmed = HeartRateGovernor.Command(speedKmh: segment.nominalSpeedKmh,
                                                   incline: segment.nominalIncline)
        guard let client else { return (.settled(at: programmed), false) }
        let entry = Self.boundedByCeiling(
            programmed,
            notAbove: Self.ceilingReference(appCommand: Self.appCommand(of: client),
                                            belt: client.beltFacts),
            isCeilingStanding: Self.isForceDownCeilingStanding(governorSession))
        return (write(entry, to: client, origin: .segmentEntry),
                !HeartRateGovernor.isSameCommand(entry, programmed))
    }

    /// The end of the workout, from either cause: the last segment completing or
    /// the stop ceiling.
    ///
    /// The stop is handed to the client and never held here. `requestStop()` only
    /// enqueues a command and the queue drops it after three attempts — about
    /// 600 ms — so somebody has to keep asking; that somebody used to be this
    /// class, and it was the wrong one. The program that asks for the ceiling stop
    /// is torn down in the same breath, and reviews found three ways the
    /// insistence went with it: this method's own timer being invalidated, an
    /// ordinary navigation home calling `stop()`, and a `paused` frame read as a
    /// confirmed stop (findings 83, 84). The client's lifetime is the connection
    /// and its poll runs at 200 ms, so the insistence is its.
    ///
    /// The timer therefore goes: `.finished` is terminal, the client is doing the
    /// asking, and a 1 Hz timer with nothing to do is a timer a later edit finds
    /// a use for.
    private func finishAndStop(_ client: any TreadmillControlling,
                               reason: DiagnosticReason) {
        // Logged before the ask, so a stop the belt never answers still has the
        // line that says who asked for it and at what speed.
        diagnostics.record(.stop, [.text("phase", "requested"),
                                   .text("by", reason.rawValue),
                                   .speed("beltSpeedKmh", client.state.speedKmh),
                                   .speed("commandedSpeedKmh", client.commandedSpeedKmh)])
        client.requestStop()
        finish(reason: reason)
    }

    /// Why a workout ended, for the log and for nothing else. A named type
    /// rather than a string at each call site: these are the labels an analyst
    /// sorts a session by, and a typo in one of them is a run they cannot find.
    enum DiagnosticReason: String, Sendable {
        /// The 97% ceiling.
        case heartRateCeiling
        /// The last segment's goal was reached.
        case programComplete
        /// A stop of the app's own was outstanding, so the program ended.
        case stopOutstanding
        /// `stop()`: an ordinary teardown — the × button, a navigation home, the
        /// belt having stopped, the start timing out.
        case tornDown
    }

    /// The program, over, without asking the belt for anything.
    ///
    /// The one caller that must not ask is the outstanding-stop guard in
    /// `tick(bySeconds:)`: the client is already insisting on a stop of the app's
    /// own, on its own 200 ms poll, and a program ending is not a reason to
    /// re-issue it — nor is it this class's stop to touch at all (spec section 4,
    /// "A stop the app asked for outlives the program that asked").
    private func finish(reason: DiagnosticReason) {
        logWorkoutEnded(reason)
        runnerState = .finished
        clearGoverning()
        timer?.invalidate()
        timer = nil
    }

    /// The workout's last line, and the flush that gets it onto disk. Only when
    /// a file is actually open: a teardown of something that was never logged —
    /// `stop()` reached from an ordinary navigation with no program running —
    /// says nothing.
    private func logWorkoutEnded(_ reason: DiagnosticReason) {
        guard diagnostics.isWorkoutOpen else { return }
        diagnostics.endWorkout([
            .text("reason", reason.rawValue),
            .text("state", DiagnosticLog.name(of: runnerState)),
            .text("governorStopReason",
                  governorStopReason == .heartRateCeiling ? "heartRateCeiling" : nil),
            .text("governorStatus", governorStatus.map { DiagnosticLog.name(of: $0) }),
        ])
    }

    // MARK: - Heart-rate control, live

    /// One tick of heart-rate control, and the whole of it. Returns false when the
    /// loop ended the workout, so the caller stops touching the segment.
    ///
    /// Every path from here that can write a target, and why none can fire on data
    /// the app has decided not to trust:
    /// - `.belowBand` — the only increase in the feature. Needs a fresh reading
    ///   *from the Watch* below the band, both settle windows expired, no ceiling
    ///   tally standing and no hand-back; one 0.2 km/h step (or one incline level),
    ///   inside the segment's own bounds intersected with the device's.
    /// - `.aboveBand`, `.outOfBounds`, `.ceilingForceDown` — reductions, same feed.
    /// - `.fallback` — 30 s with no reading, to `min(current, declared)`: a missing
    ///   reading can only ever lower the command.
    /// - `.emergencyStop` — not a target write at all: `client.requestStop()`,
    ///   which the client then insists on until the belt is observed idle or
    ///   ended. The stop ceiling is asked *above* the ladder as well, at workout
    ///   scope, so it cannot be skipped by there being nothing to evaluate.
    /// The handlebar byte reaches none of them: `heartRate` comes from
    /// `heartRateSource`, a protocol `FitShowTreadmillClient` does not conform to.
    private func steer(_ segment: WorkoutSegment, on client: any TreadmillControlling,
                       deltaSeconds: Double, heartRate: Int) -> Bool {
        guard var session = governorSession else { return true }
        // The published band follows every path out of here: the arbitration only
        // becomes knowable once the frozen basis is adopted, and it stops being
        // anybody's band the moment control is handed back.
        defer { publishGovernedBand() }
        // The person's clocks advance first and unconditionally — above the
        // surrender guard, because switching the opt-in off may not freeze the
        // ceilings, and above the evaluation grid, because the tallies are what
        // the ceilings fire on.
        session = Self.advancing(session, bySeconds: deltaSeconds, heartRate: heartRate,
                                 basis: basisSource?.heartRateBasis,
                                 command: Self.command(of: client), belt: client.beltFacts,
                                 limits: client.limits)
        governorSession = session
        // The 97% stop, at workout scope: above the run guard, above the surrender
        // guard, above the opt-in, and off the evaluation grid. See
        // `isStopCeilingReached` — read inside the ladder it was skippable by a
        // segment the gate refused, by the opt-in being off, and by a segment
        // boundary landing between two evaluations (finding 81). `tick` calls this
        // before its own completion check, so a stop that becomes due on the tick
        // a segment ends stops the belt instead of writing the next segment's
        // entry command.
        if Self.isStopCeilingReached(session) {
            governorStopReason = .heartRateCeiling
            diagnostics.record(.stop, [
                .text("phase", "ceilingReached"),
                .int("heartRateBpm", heartRate),
                .seconds("secondsAboveStopCeiling",
                         session.tallies.secondsAboveStopCeiling),
                .seconds("stopHoldSeconds", HeartRateGovernor.stopHoldSeconds)])
            finishAndStop(client, reason: .heartRateCeiling)
            governorStatus = .stopping
            return false
        }
        // A surrendered run is inert: the opt-in went off mid-segment, so nothing
        // is evaluated and nothing is written, but the run stays for `resumeCommand`.
        guard session.run?.isSurrendered != true else { return true }
        guard Self.isEvaluationDue(session) else { return true }
        // The grid's phase belongs to the workout, so it is re-anchored here
        // whether or not this segment has anything to evaluate: a boundary may
        // not push the next evaluation past the end of a short segment.
        session.secondsSinceEvaluation = 0
        governorSession = session
        guard var run = session.run else { return true }
        guard let basis = session.basis else {
            // A nil frozen basis is no basis: the band and both ceilings would be
            // percentages of nothing, so the segment holds what it was given.
            governorStatus = .noBasis
            return true
        }
        // The command is read from the client at evaluation time, never from a
        // copy: the two diverge exactly when the user turns a dial. It is an
        // observation and not a record, which is why the governor measures every
        // step from `reference(command:lastAppliedChange:)` instead.
        let command = Self.command(of: client)
        // Facts 2 and 3 come straight off the client, which infers the dial from
        // the measured values at frame cadence. This is the wire the seam packet
        // left open: without it `Input.belt` defaults to `.unobserved`, the
        // governor infers a person from fact 3 and nothing else, and the mandatory
        // hand-back could not fire in production at all.
        let input = Self.governorInput(session, run: run, basis: basis, heartRate: heartRate,
                                       command: command,
                                       appCommand: Self.appCommand(of: client),
                                       belt: client.beltFacts, limits: client.limits)
        // The hand-back is latched from the *evidence*, before the ladder is
        // consulted and whatever it decides. The force-down ceiling outranks the
        // manual-control rung and rewrites the record of the app's last command,
        // so a ceiling step-down in the same evaluation used to consume the
        // evidence for good — and the loop then re-accelerated past the speed the
        // user had set by hand (finding 65).
        let wasHandedBack = run.isHandedBack
        run.isHandedBack = run.isHandedBack || HeartRateGovernor.isManualIntervention(input)
        if run.isHandedBack, !wasHandedBack {
            diagnostics.record(.manualIntervention, [
                .text("phase", "handBackLatched"),
                .text("noticedAt", "evaluation"),
                .flag("isSpeedSetByHand", input.belt.isSpeedSetByHand),
                .flag("isInclineSetByHand", input.belt.isInclineSetByHand),
                .speed("appCommandSpeedKmh", input.appCommand?.speedKmh),
                .speed("measuredSpeedKmh", input.belt.measured?.speedKmh),
                .int("appCommandIncline", input.appCommand?.incline),
                .int("measuredIncline", input.belt.measured?.incline)])
        }
        let decision = HeartRateGovernor.decide(input)
        // See `isRefusedWhileStale`: while the link is stale no target write of the
        // governor's may reach the belt, because every number it was computed from
        // is a remembered one. Only the emergency stop passes, and this is a
        // different answer again from phase 1's staleness rule.
        let isLinkStale = client.staleData
        let status = Self.status(for: decision, isHandedBack: run.isHandedBack,
                                isLinkStale: isLinkStale)
        governorStatus = status
        let action = Self.action(for: decision, isHandedBack: run.isHandedBack,
                                isLinkStale: isLinkStale)
        // Every evaluation, not only the ones that changed something: a segment
        // that held for four minutes is a claim about four minutes of readings,
        // and "nothing happened" is only checkable against the input that
        // produced it.
        diagnostics.record(.governorEvaluated, DiagnosticLog.governorFields(
            input: input, decision: decision, action: action, status: status,
            isHandedBack: run.isHandedBack, isLinkStale: isLinkStale))
        switch action {
        case .none:
            break
        case .handBack:
            run.isHandedBack = true
        case .write(let next):
            run.commandApplied(write(next, to: client, origin: Self.origin(of: decision)))
        case .stop:
            // Reached only if the ladder ever grows a second reason to stop: the
            // stop ceiling itself has already been asked at workout scope above,
            // on the same tally this rung reads. Kept because the ladder is the
            // law and this is the runner's one way to act on it.
            governorStopReason = .heartRateCeiling
            finishAndStop(client, reason: .heartRateCeiling)
            governorStatus = .stopping
            return false
        }
        session.run = run
        governorSession = session
        return true
    }

    /// Called from `begin(_:at:)` only, with the entry write's own change. A gate
    /// refusal leaves no run behind, so nothing downstream has to remember the
    /// setting — but the session survives the boundary, because the two ceilings'
    /// clocks are the person's and not the segment's.
    private func startGoverning(_ segment: WorkoutSegment,
                                entry: HeartRateGovernor.Change,
                                isEntryClampedByCeiling: Bool) {
        guard client != nil else { return clearGoverning() }
        let gate = Self.gate(for: segment, isControlEnabled: heartRateControlEnabled,
                             entry: entry)
        // The opt-in gates the **session**, not merely this segment's run: a
        // session is the only thing that keeps the clocks the two ceilings fire
        // on, so with heart-rate control off there is no ceiling, no stop, no
        // band and no boundary clamp — nothing about heart rate touches the belt
        // (spec section 4, "The ceilings belong to the opt-in"). A program with
        // no heart-rate segment anywhere is refused for the same reason: there is
        // no governor there to protect anybody from (finding 100).
        guard heartRateControlEnabled, let program, Self.isHeartRateDriven(program) else {
            clearGoverning()
            governorStatus = gate.initialStatus
            return
        }
        var session = GovernorSession.continuing(governorSession)
        session.adopt(basisSource?.heartRateBasis)
        session.beginSegment(gate.run)
        governorSession = session
        // A clamped entry says the ceiling, whatever the gate would have said —
        // including for a segment the gate refused, which has no status of its own
        // at all. A belt that did not speed up at a boundary has a reason, and the
        // dashboard has to be able to give it (finding 82).
        governorStatus = isEntryClampedByCeiling ? .ceiling : gate.initialStatus
        publishGovernedBand()
    }

    /// The band the loop may actually hold, and whether it is less than the
    /// segment asked for. Published from the *arbitration* and never from
    /// `band(for:)`: a band whose upper edge reaches the force-down ceiling is
    /// clamped under it and one whose lower edge is at or above it is not
    /// steerable at all, so drawing the stored pair would draw a band the loop is
    /// forbidden to chase. Recomputed on every tick because the arbitration needs
    /// the frozen basis, which the gate may not have yet when the first segment
    /// and the session begin on the same second.
    private func publishGovernedBand() {
        let arbitration = governorSession.flatMap {
            session -> HeartRateGovernor.BandArbitration? in
            guard let run = session.run, !run.isSurrendered, !run.isHandedBack,
                  let basis = session.basis else { return nil }
            return HeartRateGovernor.arbitration(for: run.target, basis: basis)
        }
        let band = arbitration?.band
        let isReduced = arbitration?.isReduced ?? false
        // Assigned only on a change: an `@Published` re-assigned every second
        // would redraw the dashboard every second for no new information.
        if governedBandBpm != band { governedBandBpm = band }
        if governedBandIsReduced != isReduced { governedBandIsReduced = isReduced }
    }

    /// The workout's governor state, gone. Called where a workout starts or ends
    /// and nowhere else — a segment boundary goes through `beginSegment`.
    private func clearGoverning() {
        governorSession = nil
        governorStatus = nil
        governedBandBpm = nil
        governedBandIsReduced = false
    }

    /// Switching the opt-in off mid-segment. The run is kept and made inert
    /// rather than dropped, for the reason `resumeCommand(for:run:)` gives: a run
    /// that is gone turns a later resume from "the loop's own last command" into
    /// "the segment's programmed start speed", which can put back a reduction the
    /// loop made for the user's safety. Inert also keeps the switch one-way for
    /// the rest of the segment, which is the rule the setter states — switching
    /// back on may not start a loop under a belt that is already moving.
    /// It takes the two ceilings with it, which is the whole of finding 100's
    /// second half: `GovernorSession.surrender()` zeroes the person's clocks and
    /// latches `isControlOn` false, so the 92% force-down and the 97% stop stop
    /// where the switch does. The alternative was brakes whose existence depended
    /// on whether the user had switched the feature off before the workout or
    /// during it.
    ///
    /// It runs whether or not this segment has a run: a fixed segment inside a
    /// governed workout carries none, and its clocks are exactly the ones that
    /// would otherwise keep counting.
    private func surrenderGoverning() {
        governedBandBpm = nil
        governedBandIsReduced = false
        guard var session = governorSession else { return }
        session.surrender()
        governorSession = session
        governorStatus = .controlOff
    }

    /// The resume write. `resumeCommand` decides what — for a governed segment the
    /// loop's own last command, for one the user took over nothing at all.
    private func reapplyOnResume(_ segment: WorkoutSegment,
                                 on client: any TreadmillControlling) {
        // The latch first, from the evidence the client kept collecting all through
        // the suspension — `steer` is the only other place that touches it and it
        // does not run while suspended, so without this the resume writes the loop's
        // remembered command over a speed the user set by hand (finding 135).
        if var session = governorSession, let run = session.run {
            let resumed = Self.resuming(run, belt: client.beltFacts)
            session.run = resumed
            governorSession = session
            if resumed.isHandedBack, !run.isHandedBack {
                // The dashboard has to say so on the same tick the resume decides
                // it: control is the user's for the rest of the segment, and a band
                // still drawn behind the chart would claim the loop is holding it.
                governorStatus = .handedBack
                publishGovernedBand()
                diagnostics.record(.manualIntervention, [
                    .text("phase", "handBackLatched"),
                    .text("noticedAt", "resume"),
                    .flag("isSpeedSetByHand", client.beltFacts.isSpeedSetByHand),
                    .flag("isInclineSetByHand", client.beltFacts.isInclineSetByHand),
                    .speed("appCommandSpeedKmh", client.commandedSpeedKmh),
                    .speed("measuredSpeedKmh", client.state.speedKmh),
                    .int("appCommandIncline", client.commandedIncline),
                    .int("measuredIncline", client.state.inclinePercent)])
            }
        }
        guard let command = Self.resumeCommand(for: segment, run: governorSession?.run)
        else { return }
        // The same authority the boundary write is under, for the same reason: for
        // a segment with no run this is the programmed value again, and a resume
        // must not put back a load the ceiling has already had to take off. For a
        // governed run it is a no-op — `resumeCommand` returns the loop's own last
        // command, which is fact 1.
        //
        // **Fact 1 alone**, and deliberately not the boundary's
        // `min(fact 1, fact 2)` reference. A resume happens on a belt that was
        // standing still, so its measured value is a wind-down or the first
        // second of a console's restart ramp and is evidence about nothing the
        // user chose: clamping to it would command 0.8 km/h and leave a fixed
        // segment crawling there for the rest of its length. A boundary, by
        // contrast, only ever lands on a moving belt.
        let bounded = Self.boundedByCeiling(
            command, notAbove: Self.appCommand(of: client),
            isCeilingStanding: Self.isForceDownCeilingStanding(governorSession))
        let change = write(bounded, to: client, origin: .resume)
        guard var session = governorSession, var run = session.run else { return }
        run.commandApplied(change)
        session.run = run
        governorSession = session
    }

    /// Sends a command and reports the write as **fact 1** on both ends: the
    /// app's own record of what it asked for, before and after.
    ///
    /// `to` is fact 1 read back from the client, because the client clamps to its
    /// limits and bounds a stale write by the last measured value — a value it
    /// refused was never commanded. It is read from `commandedSpeedKmh` and not
    /// from the client's target, which is an observation the reconcile rule may
    /// rewrite from the next frame onward.
    ///
    /// `from` is the *previous command*, and its only reader is the hysteresis,
    /// which needs the direction of the last change. It used to be where the belt
    /// was, which made a resume that restarts a belt from zero look like a large
    /// upward change and earned the next reduction a reversal margin it had not
    /// earned; a write that restates the standing command now correctly has no
    /// direction at all.
    private func write(_ command: HeartRateGovernor.Command,
                       to client: any TreadmillControlling,
                       origin: DiagnosticWriteOrigin) -> HeartRateGovernor.Change {
        let previous = Self.appCommand(of: client)
        client.setTarget(speedKmh: command.speedKmh, incline: command.incline)
        let change = HeartRateGovernor.Change(from: previous, to: Self.appCommand(of: client))
        // Requested against accepted, at the one place that holds both: the
        // client clamps to its limits, bounds a stale write by the last measured
        // value and refuses anything above what is already happening while a
        // stop stands, and a rule reporting itself as acting while its value was
        // refused is what this line exists to catch. The client logs the writes
        // this method does not make — a person's ± tiles, a start, the stop aid.
        diagnostics.record(.clientWrite,
                           DiagnosticLog.writeFields(origin: origin, requested: command,
                                                     clamped: change.to, previous: previous))
        return change
    }

    /// Which write a decision is, for the log. A brake and a step of the band law
    /// reach the belt as the same call, and telling them apart afterwards is the
    /// first thing anyone reading a run wants to do.
    nonisolated static func origin(of decision: HeartRateGovernor.Decision)
        -> DiagnosticWriteOrigin {
        switch decision {
        case .adjust(_, .ceilingForceDown): return .brake
        case .fallback: return .fallback
        // The remaining cases write nothing (`action(for:…)` turns them into
        // `.none`, `.handBack` or `.stop`), so only `.adjust` is really reachable
        // here; naming it the band law is the honest answer for the one that is.
        case .adjust, .hold, .frozen, .emergencyStop, .manualControl: return .governor
        }
    }

    /// The client's current target — **an observation**, folded into the
    /// governor's reference the one way an observation may be: downward only.
    /// Contract, not convenience: see `steer`.
    private static func command(of client: any TreadmillControlling)
        -> HeartRateGovernor.Command {
        HeartRateGovernor.Command(speedKmh: client.targetSpeedKmh,
                                  incline: client.targetIncline)
    }

    /// **Fact 1**: what the app itself last commanded, as the client records it.
    /// No incoming frame may move it, which is what makes it the one number a
    /// write may be measured against.
    private static func appCommand(of client: any TreadmillControlling)
        -> HeartRateGovernor.Command {
        HeartRateGovernor.Command(speedKmh: client.commandedSpeedKmh,
                                  incline: client.commandedIncline)
    }
}

// MARK: - The belt, as the runner uses it

/// Everything `ProgramRunner` reads from and writes to a treadmill, and nothing
/// more. `FitShowTreadmillClient` is the only production conformer, and the
/// conformance is declared here — as an empty extension over members it already
/// has — so that drawing this seam costs the client file nothing.
///
/// It exists for the reason `GovernorHeartRateSource` exists: to make something
/// testable that had no seam at all. `ProgramRunner.tick(bySeconds:)` is where
/// half of this feature's safety rules live — the 97% stop asked above the
/// surrender guard and off the evaluation grid, the hand-back latched from the
/// evidence before the ladder is consulted, the boundary clamp read before the
/// band-scoped tallies are cleared — and none of them could be tested against
/// shipped code while the runner took a concrete Bluetooth client. What the
/// runner-level suite tested instead was a hand-rolled copy of that statement
/// order living in a test file, which is the same class of gap that let phase 1's
/// regression through (finding 103).
///
/// Every member is read-only except the three writes, which is the point: the
/// runner may command a target, start the belt after a confirmed countdown, and
/// ask for a stop. A test double may model the belt however it likes, but it must
/// answer these from the client's *own* pure rules — `reconciled`,
/// `boundedByStop`, `bounded`, `ConsoleDialDetector` — or it models a client
/// production does not have (finding 80).
@MainActor
protocol TreadmillControlling: AnyObject {
    var state: TreadmillState { get }
    var limits: TreadmillLimits { get }
    /// No frame for longer than the client's freshness horizon: the app's picture
    /// of the console is a remembered number.
    var staleData: Bool { get }
    /// **Fact 1**: what the app itself last commanded. No frame may move it.
    var commandedSpeedKmh: Double { get }
    var commandedIncline: Int { get }
    /// The client's target — an *observation*, reconciled with the belt.
    var targetSpeedKmh: Double { get }
    var targetIncline: Int { get }
    /// **Facts 2 and 3**: the belt's measured values, and whether a dial has been
    /// turned by hand.
    var beltFacts: HeartRateGovernor.BeltFacts { get }
    /// A stop of the app's own is outstanding now, from the first attempt onward.
    var isStopOutstanding: Bool { get }
    /// …and the durable half of the same fact, which survives the insistence
    /// giving up. See `ProgramRunner.isRefusedByOutstandingStop`.
    var stopNotObeyed: Bool { get }

    func setTarget(speedKmh: Double, incline: Int)
    func startBelt(speedKmh: Double, incline: Int)
    func requestStop()
    /// A new segment has begun: retire the console-dial verdict. See
    /// `FitShowTreadmillClient.segmentBegan()` and `ProgramRunner.begin(_:at:)`
    /// (finding 114).
    func segmentBegan()
}

extension FitShowTreadmillClient: TreadmillControlling {}

// MARK: - The one heart-rate feed heart-rate control may read

/// The governor's heart-rate seam. A protocol with named implementations rather
/// than a `() -> Int` provider, because the wrong source here accelerates a belt:
/// `client.state.heartRate` is the handlebar byte (`payload[12]`), it drops to 0
/// the moment the user lets go, and a 0 read as "low heart rate" makes the loop
/// add load. A closure would accept it at any call site; a protocol makes the set
/// of possible sources something a reader can enumerate.
///
/// Conformers: `WatchHeartRateManager` below, and — wired at the composition root
/// — demo mode's synthetic plant. `FitShowTreadmillClient` deliberately does not
/// conform, which is what makes the handlebar sensor structurally unreachable
/// from here.
@MainActor
protocol GovernorHeartRateSource: AnyObject {
    /// The heart rate the loop may act on, or 0 when there is no fresh reading.
    func governorHeartRateBpm() -> Int
}

extension WatchHeartRateManager: GovernorHeartRateSource {
    /// The Watch feed with its own freshness window applied — after the Watch
    /// goes quiet the last value must not be pinned forever.
    func governorHeartRateBpm() -> Int { freshHeartRate() }
}
