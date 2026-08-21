// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import Foundation

// `HeartRateActuator` and `HeartRateTarget` live in `WorkoutProgram.swift`, next
// to `SegmentGoal` and `SegmentTarget`: they are the model the editor edits and
// storage round-trips, and their editable ranges belong with the other segment
// bounds. This file is only the control law that reads them.

/// Decides, every evaluation, what a heart-rate segment should command. It sends
/// nothing: the runner acts on the decision.
///
/// Pure by construction — no `Date()`, no HealthKit, no BLE, no MainActor. Every
/// elapsed time arrives as a counter the caller measured, which is the injected-clock
/// rule in `Fable/en/swiftui-ios.md` and the lesson of phase 1: control logic living
/// inside a `Timer` callback next to a concrete Bluetooth client cannot be tested at
/// all, which is how a regression that accelerated a moving belt got in.
///
/// Two contracts the caller owns, both load-bearing:
/// - `Input.heartRate` may only come from `WatchHeartRateManager.freshHeartRate()`.
///   `client.state.heartRate` is the handlebar byte: it drops to 0 the moment the
///   user lets go, and a 0 read as "low heart rate" makes the belt accelerate.
/// - The three facts of spec section 4 arrive as three separate things and are
///   never substituted for one another: **fact 1**, the app's own last command, in
///   `Input.lastAppliedChange`; **fact 2**, the belt's measured values, and
///   **fact 3**, whether a dial has been turned by hand, both in `Input.belt`.
///   Every number this file computes from is `reference(command:lastAppliedChange:
///   appCommand:belt:)`, the lower of facts 1 and 2 per axis — on both axes and
///   with no exception — and a person is only ever inferred from fact 3, which the
///   client infers from a *decisive* change and not from a detectable one. Three
///   review rounds of blockers came out of doing any of this from the client's
///   target field instead, and three more out of the exceptions that followed.
///
/// A decision carries a whole command because `setTarget` writes both axes. The
/// segment's own actuator is the one the band law ever *chooses*; the other axis is
/// restated at the reference, which is `min(fact 1, fact 2)` there as everywhere
/// else — so a write can neither re-command load the app has cancelled
/// (finding 74) nor accelerate the axis it is not steering while reporting a
/// reduction (finding 111). A brake may go further and *reduce* that other axis,
/// when the actuated one has run out of room at the machine's own bound
/// (finding 112).
extension HeartRateActuator {
    /// The axis a segment does *not* steer. It lives here rather than next to the
    /// enum because only the control law has any use for it: a brake that has run
    /// out of room on the segment's own axis takes the load off this one instead
    /// (spec section 4, "A brake is not bounded by the segment's corridor";
    /// finding 112).
    var other: HeartRateActuator { self == .speed ? .incline : .speed }
}

struct HeartRateGovernor {

    // MARK: - Constants

    /// The caller's cadence. Heart rate lags load by 20–40 s, so a faster loop
    /// only chases its own transients; it also floors the interval between two
    /// forced reductions, so a caller ticking at 1 Hz cannot walk the belt down
    /// ten times faster than this file says it can.
    static let evaluationIntervalSeconds: Double = 10

    /// No band-following change within this long of the previous one: the reading
    /// in hand still describes the load before that change.
    static let settleAfterChangeSeconds: Double = 45

    /// One incline level is a bigger metabolic step than one speed step — at
    /// 8 km/h the ACSM equations put 1% at ~1.8× a 0.2 km/h step, at walking pace
    /// nearer 4× — and the motor itself takes seconds to travel, so the transient
    /// both starts later and is larger.
    static let inclineSettleAfterChangeSeconds: Double = 60

    /// The step limit, per evaluation and per axis. Small enough that a step taken
    /// on a wrong reading is harmless on its own. It caps the step's *magnitude*,
    /// not merely its result — see `stepped(from:direction:magnitude:bounds:)`.
    static let maxSpeedStepKmh = 0.2
    static let maxInclineStep = 1

    /// The protocol's speed resolution: `FitShowCommands.setTarget` sends whole
    /// 0.1 km/h units. Every command this type emits sits on that grid, so the
    /// client's own rounding is the identity and a target that comes back
    /// different is evidence of a person rather than of arithmetic. Speeds are
    /// built as `units / speedUnitsPerKmh` for the same reason
    /// `TreadmillLimits.minSpeedKmh` is: 82 × 0.1 and 8.2 are not the same Double,
    /// and one bit of drift reads as somebody having turned a dial.
    static let speedUnitsPerKmh: Double = 10
    static let speedQuantumKmh = 1 / speedUnitsPerKmh

    /// A speed on the protocol's grid, as the integer the wire carries. Every
    /// comparison of two speeds in this file goes through it: one quantum is
    /// 0.09999999999999964 in binary floating point, so a `>= 0.1` test is false
    /// for 114 of the 193 speeds this device offers and a single console press was
    /// invisible at every one of them (finding 76). Integers do not have that
    /// failure mode.
    static func speedUnits(_ speedKmh: Double) -> Int {
        guard speedKmh.isFinite else { return 0 }
        return Int((speedKmh * speedUnitsPerKmh).rounded())
    }

    static func speedKmh(units: Int) -> Double {
        Double(units) / speedUnitsPerKmh
    }

    /// Proportional gain. With a 0.1 km/h grid and a 0.2 km/h cap the law has
    /// exactly three outputs — nothing, one quantum, two — so this constant only
    /// picks where one step becomes two: at 7.5 bpm of error.
    static let speedGainKmhPerBpm = 0.02

    /// Reversing the previous change needs more than this much error. Hysteresis
    /// on the *direction of the last change* rather than a widened dead band,
    /// because a dead band would park the heart rate just outside the band the
    /// segment asked for instead of inside it.
    static let reversalMarginBpm = 2

    /// No fresh reading for this long: leave the band alone and go to the
    /// segment's fallback. Under it the command is frozen.
    static let feedLossFallbackSeconds: Double = 30

    /// Above this share of the maximum, held this long, the load comes down
    /// whatever the band says.
    static let forceDownCeilingFraction = 0.92
    static let forceDownHoldSeconds: Double = 10

    /// Above this share of the maximum, held this long, the workout ends. The
    /// hold windows exist so a single artefact frame cannot fire either ceiling.
    static let stopCeilingFraction = 0.97
    static let stopHoldSeconds: Double = 15

    /// Time below the band, either at the segment's upper bound or after the
    /// force-down ceiling has already had to pull the load back, before the
    /// governor stops escalating. An estimated maximum can be far too high, and a
    /// Karvonen band can sit above the ceiling derived from that same maximum
    /// (spec section 4); in both cases the band is a number the loop is not
    /// allowed to reach. Holding at a bound the user set is safe, pushing at it
    /// forever is not.
    static let stallWindowSeconds: Double = 120

    // MARK: - Values

    /// One treadmill command. Both axes travel together because the client's
    /// `setTarget` writes both: handing the caller half a command invites it to
    /// invent the other half.
    struct Command: Equatable, Sendable {
        var speedKmh: Double
        var incline: Int
    }

    /// **Fact 1** of the spec's "Three facts, kept apart": the app's own last
    /// write. A record the app itself owns, which no incoming frame may
    /// overwrite — `FitShowTreadmillClient.commandedSpeedKmh` is the client's
    /// copy of the same fact.
    struct Change: Equatable, Sendable {
        /// The value the write moved *from*. Its only remaining reader is the
        /// hysteresis, which needs the direction of the last change.
        var from: Command
        /// The value the write moved *to*, read back from the client, because the
        /// client clamps to its limits and bounds a stale write by the last
        /// measured value — and a value it refused to accept was never commanded.
        var to: Command

        /// No change in flight: the command is both ends, so the last change has
        /// no direction and the hysteresis has nothing to hold back.
        static func settled(at command: Command) -> Change {
            Change(from: command, to: command)
        }
    }

    /// **Facts 2 and 3**: what the belt is measured to be doing, and whether a
    /// dial has been turned by hand. Both come from
    /// `FitShowTreadmillClient.beltFacts`, which infers fact 3 from fact 2 at
    /// frame cadence — never from the client's target field, so no reconciliation
    /// policy, dead band or float comparison can blind it.
    ///
    /// This type replaces the ramp corridor and the arrival latch that used to
    /// live in `Change`. They were an attempt to make the client's target field
    /// mean both "what the app asked for" and "where the belt is", and each round
    /// of machinery produced the next round's blockers: a corridor cannot close
    /// while a person is holding the belt away from the command, which is exactly
    /// when it matters (findings 74–77).
    ///
    /// `unobserved` is what a caller that has not been wired to the client's facts
    /// yet supplies. It is the conservative reading: with no measurement the
    /// reference is the app's own record and nothing is inferred about a person.
    ///
    /// It no longer carries "is this axis still travelling". That flag existed to
    /// let the reference take fact 1 alone on an axis mid-journey, and the spec now
    /// forbids the exception outright: any exception is a window in which a *brake*
    /// re-commands the app's own remembered value, and a person holding the belt
    /// away from that value is exactly what keeps the window open (finding 124).
    struct BeltFacts: Equatable, Sendable {
        /// Fact 2, or nil when nothing has been measured.
        var measured: Command?
        var isSpeedSetByHand = false
        var isInclineSetByHand = false

        static let unobserved = BeltFacts()

        var isSetByHand: Bool { isSpeedSetByHand || isInclineSetByHand }
    }

    /// The two thresholds derived from the frozen basis. Named because they are
    /// two different actions, and because a percentage of a possibly wrong
    /// maximum deserves to be visible at every call site.
    struct Ceilings: Equatable, Sendable {
        let forceDownBpm: Int
        let stopBpm: Int
    }

    /// What a segment may actually be asked to hold, once the frozen basis is
    /// known. The band is bpm on the heart-rate *reserve* (Karvonen) while the
    /// ceilings are a share of the *maximum*, and the two collide at the top of
    /// the range: with resting 60 / max 180 zone 5 is 168–180 while the
    /// force-down ceiling sits at 166. Asking the loop to hold that band asks it
    /// to drive the heart rate to a value another rule is obliged to pull back
    /// from, and it sawtooths at 92% of maximum for the whole segment while the
    /// give-up rule stays silent because the band is never reached.
    ///
    /// Spec section 4, "A band above the force-down ceiling is not a band the
    /// governor may chase": the app will not steer anyone into zone 5.
    enum BandArbitration: Equatable, Sendable {
        /// Entirely below the force-down ceiling: hold it as asked.
        case steerable(ClosedRange<Int>)
        /// The upper edge reached the ceiling and has been brought under it. The
        /// segment holds a reduced target and has to say so.
        case clamped(ClosedRange<Int>)
        /// The lower edge is at or above the ceiling: there is no load at which
        /// this band could be held, so the segment runs fixed at its start
        /// command.
        case notSteerable

        /// The band the loop may hold, nil when there is none.
        var band: ClosedRange<Int>? {
            switch self {
            case .steerable(let band), .clamped(let band): return band
            case .notSteerable: return nil
            }
        }

        /// Is the segment holding less than the user asked for?
        var isReduced: Bool {
            if case .clamped = self { return true }
            return false
        }
    }

    /// The durations the rules are stated in, kept by the caller as measured
    /// seconds. Measured, not counted in timer fires: iOS does not replay missed
    /// fires, so a tick is not a second — the mistake phase 1 made in four places.
    struct Tallies: Equatable, Sendable {
        var secondsWithoutHeartRate: Double = 0
        var secondsAboveForceDownCeiling: Double = 0
        var secondsAboveStopCeiling: Double = 0
        /// Consecutive seconds with the loop out of room at the top of the
        /// segment while the heart rate is still under the band. It resets on any
        /// tick that is not both, so the flag the caller passes must come from
        /// `isAtUpperBound(reference:appCommand:target:limits:)` and never from a
        /// hand-rolled comparison: one that read the measured speed exactly was
        /// false on every tick against a console biased by a single tenth, and
        /// this counter never left zero.
        var secondsAtUpperBoundBelowBand: Double = 0
        /// Has the force-down ceiling fired in this segment? Latched, because it
        /// is evidence about the band rather than about this second.
        var didForceDown = false
        /// Time below the band *after* the ceiling has already had to pull the
        /// load back once. Climbing again would only re-trigger it, so this
        /// counts toward the give-up window exactly like time at the upper bound
        /// does — and unlike that tally it never resets, because a sawtooth is
        /// made of excursions and resetting on each one would count nothing.
        var secondsBelowBandAfterForceDown: Double = 0

        /// One tick folded in. A missing reading holds the ceiling tallies rather
        /// than resetting them: losing the feed is not evidence that the heart
        /// rate came back down, and the counters are what the two ceilings fire on
        /// when it does not come back at all.
        func advanced(bySeconds delta: Double, heartRate: Int, ceilings: Ceilings,
                      band: ClosedRange<Int>, isAtUpperBound: Bool) -> Tallies {
            guard delta.isFinite, delta > 0 else { return self }
            var next = self
            guard heartRate > 0 else {
                next.secondsWithoutHeartRate += delta
                return next
            }
            next.secondsWithoutHeartRate = 0
            next.secondsAboveForceDownCeiling =
                heartRate >= ceilings.forceDownBpm ? secondsAboveForceDownCeiling + delta : 0
            next.secondsAboveStopCeiling =
                heartRate >= ceilings.stopBpm ? secondsAboveStopCeiling + delta : 0
            next.secondsAtUpperBoundBelowBand =
                isAtUpperBound && heartRate < band.lowerBound
                ? secondsAtUpperBoundBelowBand + delta : 0
            // "The ceiling has fired" is the rung's own test, made here so the
            // signature can be counted without the caller reporting decisions
            // back into the tallies.
            next.didForceDown = didForceDown
                || next.secondsAboveForceDownCeiling >= forceDownHoldSeconds
            if next.didForceDown, heartRate < band.lowerBound {
                next.secondsBelowBandAfterForceDown = secondsBelowBandAfterForceDown + delta
            }
            return next
        }
    }

    struct Input: Equatable, Sendable {
        var target: HeartRateTarget
        /// Resolved once when the session began (`HeartRateBasis`), so neither a
        /// Health re-read nor a profile edit can move a ceiling under a governor
        /// that is steering a belt.
        var basis: HeartRateBasis
        var limits: TreadmillLimits
        /// `WatchHeartRateManager.freshHeartRate()`; 0 means no fresh reading,
        /// as everywhere else in this codebase.
        var heartRate: Int
        /// `client.targetSpeedKmh` / `client.targetIncline`: the client's own
        /// copy of fact 1, reconciled with the belt's measured value once the
        /// app's command is older than `FitShowTreadmillClient
        /// .targetHoldOffSeconds`. It is an *observation*, so it is only ever
        /// read the one way an observation may be read — to lower the reference,
        /// never to raise it, and never as evidence about a person.
        var command: Command
        /// Fact 1: the app's own last write, as the caller recorded it.
        var lastAppliedChange: Change
        /// **Fact 1, live**: `FitShowTreadmillClient.commandedSpeedKmh` /
        /// `commandedIncline`, which no incoming frame may move. It is a third copy
        /// of fact 1 and it enters the reference the same way as the other two —
        /// downward only. It earns its place because it is the one copy an in-app
        /// "−" press brings down at once: the client's target can be reconciled
        /// back up to a belt somebody has since dialled up, and the runner's
        /// `lastAppliedChange` records the loop's own writes and not the user's.
        var appCommand: Command? = nil
        var secondsSinceSegmentStart: Double
        /// Since the **app's own** last write. It floors the interval between two
        /// forced reductions, so it is deliberately not re-armed by anything a
        /// person does: a brake may not be postponed by the dial that made it
        /// necessary.
        var secondsSinceLastCommand: Double
        /// Since the **load** last changed, whoever changed it — the app, the
        /// console, or the app's own ± tiles. This is what the settle window is
        /// stated in: the window exists because the reading in hand still describes
        /// the load before the last change, and whose hand made that change has
        /// nothing to do with it (finding 137). The caller keeps it; in production
        /// it is never later than `secondsSinceLastCommand`, because the app's own
        /// write re-arms both.
        var secondsSinceLoadChange: Double
        var tallies: Tallies
        /// Facts 2 and 3, from `FitShowTreadmillClient.beltFacts`. Defaulted
        /// because the runner is wired to them in the next packet; the default is
        /// the conservative reading, not a convenient one.
        var belt: BeltFacts = .unobserved
    }

    /// Why a decision came out the way it did. The runner publishes this as the
    /// dashboard's governor status; the tests read it to pin the precedence.
    enum Reason: Equatable, Sendable {
        case belowBand
        case aboveBand
        case insideBand
        case settling
        /// A reversal inside the reversal margin.
        case hysteresis
        case ceilingForceDown
        /// The step would leave the segment's bounds, so nothing was commanded.
        case atBound
        /// At the upper bound, or already pulled back by the ceiling, still below
        /// the band, past the stall window: the target is not reachable and the
        /// governor says so instead of pushing.
        case targetUnreachable
        /// The command was outside the segment's bounds and has been brought back.
        case outOfBounds
        /// The band's lower edge is at or above the force-down ceiling: there is
        /// nothing here to steer toward, so the segment runs fixed.
        case bandNotSteerable
    }

    enum Decision: Equatable, Sendable {
        case hold(reason: Reason)
        case adjust(command: Command, reason: Reason)
        /// No fresh reading: keep whatever is commanded now, and never more.
        case frozen
        /// The feed has been gone too long — the segment's fallback, which by
        /// construction is never above the current command.
        case fallback(command: Command)
        /// The caller must call `client.requestStop()`.
        case emergencyStop
        /// The user changed speed or incline by hand: control is theirs for the
        /// rest of the segment. The caller latches this.
        case manualControl
    }

    /// The rule ladder, most authority first. Precedence is this list rather
    /// than the order of statements in a function body: it can be read without
    /// following control flow, and a test asserts it.
    enum Rung: Int, CaseIterable, Sendable {
        /// Above everything, including a lost feed: the last thing known was that
        /// the user was over the stop ceiling, and silence is not recovery.
        case stopCeiling
        /// Above the ceiling below it because it is the more decisive reduction of
        /// the two, and above the hand-back because it can only restate or lower
        /// the load — the same reason the ceilings outrank it (finding 98).
        case feedLostFallback
        /// Reduces load only, so it outranks the hand-back and the settle window:
        /// waiting 45 s at 92% of maximum is not settling, it is waiting.
        case forceDownCeiling
        /// The user's dial beats the loop's estimate.
        case manualControl
        /// A malformed segment can start above its own upper bound. Correcting it
        /// is a reduction; there is deliberately no upward correction.
        case outOfBoundsCorrection
        case feedLostFreeze
        /// The band cannot be held on this basis at all. Below the reductions,
        /// above everything that could ask for more load.
        case bandNotSteerable
        case stalledAtUpperBound
        case settling
        case insideBand
        /// The band law itself, and the only rung that can add load — by one step
        /// from the reference, which is never above the app's own command.
        case followBand
    }

    // MARK: - Derived quantities (the runner needs these too)

    static func ceilings(for basis: HeartRateBasis) -> Ceilings {
        Ceilings(forceDownBpm: Int((Double(basis.maxBpm) * forceDownCeilingFraction).rounded()),
                 stopBpm: Int((Double(basis.maxBpm) * stopCeilingFraction).rounded()))
    }

    /// The band, repaired: a stored pair in the wrong order must not invert the
    /// sign of every error the loop computes.
    static func band(for target: HeartRateTarget) -> ClosedRange<Int> {
        min(target.lowBpm, target.highBpm)...max(target.lowBpm, target.highBpm)
    }

    /// The band against the ceilings derived from the same frozen basis. See
    /// `BandArbitration`.
    static func arbitration(for target: HeartRateTarget,
                            basis: HeartRateBasis) -> BandArbitration {
        let band = band(for: target)
        let forceDown = ceilings(for: basis).forceDownBpm
        guard band.lowerBound < forceDown else { return .notSteerable }
        guard band.upperBound >= forceDown else { return .steerable(band) }
        return .clamped(band.lowerBound...(forceDown - 1))
    }

    /// The bpm a band may be *asked* for on this basis: the plausible range with
    /// its top cut one bpm below the force-down ceiling. The editor takes its
    /// Stepper range from here, so a user cannot ask for a band the loop is
    /// forbidden to chase and then wonder why the segment ran fixed.
    static func holdableBandRangeBpm(for basis: HeartRateBasis) -> ClosedRange<Int> {
        let top = min(HeartRateTarget.bandRangeBpm.upperBound, ceilings(for: basis).forceDownBpm - 1)
        let bottom = min(HeartRateTarget.bandRangeBpm.lowerBound,
                         top - HeartRateTarget.minBandWidthBpm)
        return bottom...top
    }

    /// The segment's speed bounds intersected with the device's, snapped *inward*
    /// to the protocol's 0.1 km/h grid. Inward matters: an upper bound of
    /// 8.35 km/h left un-snapped would be sent as 8.4, i.e. above the bound the
    /// user set.
    static func speedBounds(for target: HeartRateTarget,
                            limits: TreadmillLimits) -> ClosedRange<Double> {
        let low = quantized(max(target.minSpeedKmh, limits.minSpeedKmh), rule: .up)
        let high = quantized(min(target.maxSpeedKmh, limits.maxSpeedKmh), rule: .down)
        let clampedLow = min(max(low, limits.minSpeedKmh), limits.maxSpeedKmh)
        let clampedHigh = min(max(high, limits.minSpeedKmh), limits.maxSpeedKmh)
        // An empty range would trap, and a nonsense segment must still be safe to
        // run: collapse it instead, at the lower of the two.
        return min(clampedLow, clampedHigh)...max(clampedLow, clampedHigh)
    }

    static func inclineBounds(for target: HeartRateTarget,
                              limits: TreadmillLimits) -> ClosedRange<Int> {
        let low = min(max(target.minIncline, limits.minIncline), limits.maxIncline)
        let high = min(max(target.maxIncline, limits.minIncline), limits.maxIncline)
        return min(low, high)...max(low, high)
    }

    /// The device's own limits, snapped inward to the protocol grid — and
    /// **the only bound a brake has**.
    ///
    /// Spec section 4, "A brake is not bounded by the segment's corridor": the
    /// two ceilings and the feed-loss fallback are clamped by these and never by
    /// the segment's speed or incline corridor. A segment whose floor is 8 km/h
    /// must not prevent a force-down from going below 8 — the corridor is the
    /// user's statement about where they want to train, not a floor under the
    /// brakes. And the old answer was worse than doing nothing: with an 8–10 km/h
    /// corridor and a console dialled down to 6, the 92% reduction to 5.8 was
    /// rejected as out of bounds while the decision still reported the ceiling,
    /// so the dashboard said the app was slowing down while nothing was sent
    /// (finding 97).
    static func deviceSpeedBounds(_ limits: TreadmillLimits) -> ClosedRange<Double> {
        let low = quantized(limits.minSpeedKmh, rule: .up)
        let high = quantized(limits.maxSpeedKmh, rule: .down)
        return min(low, high)...max(low, high)
    }

    static func deviceInclineBounds(_ limits: TreadmillLimits) -> ClosedRange<Int> {
        min(limits.minIncline, limits.maxIncline)...max(limits.minIncline, limits.maxIncline)
    }

    /// Which bounds a candidate is legal against. The segment's corridor bounds
    /// the band law and the out-of-bounds correction, both of which are about the
    /// corridor; the device's own limits bound the brakes. See
    /// `deviceSpeedBounds(_:)`.
    private enum BoundsKind { case segment, device }

    /// Has the loop run out of room at the top of what the segment allows?
    ///
    /// The question is about **fact 1** — the app's own command, which no incoming
    /// frame may move — and not about a measurement: once the app is commanding the
    /// bound, the loop cannot climb any further whatever a frame reports. The
    /// reference is asked only to be *within one step* of that bound, because the
    /// reference includes the raw measured speed and the spec's own list of
    /// confusions (a console with a one-tenth bias, a footfall loading the belt, a
    /// write the queue abandoned) all live inside one or two protocol quanta. A
    /// belt that plateaus a tenth low is not a loop with room left.
    ///
    /// The stall window is counted on this, and it is counted per tick: an exact
    /// test against a reference that carries the measurement zeroed
    /// `Tallies.secondsAtUpperBoundBelowBand` on any tick a single tenth fell
    /// short, so with a *persistent* bias the 120 s window never filled at all,
    /// the give-up rule never arrived, and the dashboard said "adjusting" for the
    /// whole segment while the loop re-sent the same bound for ever.
    ///
    /// A tolerance on the exact comparison was the other candidate and is refused:
    /// one quantum leaves a two-quantum bias broken, and `ConsoleDialDetector`
    /// names half a km/h of divergence as realistic. Reading fact 1 has no such
    /// scale to guess at.
    ///
    /// Which way the remaining imprecision falls: a belt still *ramping* toward a
    /// bound the app has just commanded now counts as at the bound for the ramp's
    /// duration, ~10–20 s against a 120 s window — over-counting, which is the
    /// direction the spec calls safe (giving up holds a load; pushing at an
    /// unreachable band raises one).
    ///
    /// Both callers of the stall window go through this one function — the ladder's
    /// `stalledAtUpperBound` rung and `ProgramRunner.advancing`'s tally — so the
    /// runner and the governor cannot disagree about being at the bound.
    /// Comparisons are in protocol units, never floating-point km/h.
    static func isAtUpperBound(reference: Command, appCommand: Command,
                               target: HeartRateTarget,
                               limits: TreadmillLimits) -> Bool {
        switch target.actuator {
        case .speed:
            let bound = speedUnits(speedBounds(for: target, limits: limits).upperBound)
            return speedUnits(appCommand.speedKmh) >= bound
                && speedUnits(reference.speedKmh) >= bound - speedUnits(maxSpeedStepKmh)
        case .incline:
            let bound = inclineBounds(for: target, limits: limits).upperBound
            return appCommand.incline >= bound
                && reference.incline >= bound - maxInclineStep
        }
    }

    /// The value every decision is measured from, and the only one: **the lower of
    /// fact 1 and fact 2, per axis, on both axes, with no exception** — the app's
    /// own last command, and what the belt is measured to be doing.
    ///
    /// An observation may therefore only ever *lower* what the governor believes it
    /// is holding. A belt still travelling makes it conservative; a console turned
    /// down is believed at once; and no frame can talk it above its own last
    /// command. Both axes, not just the actuated one: `setTarget` writes the pair,
    /// so a reduction that passed the other axis through from an observation could
    /// re-command load the app had already cancelled (finding 74) — and one that
    /// passed it through from fact 1 alone re-commanded the app's own 10 km/h over
    /// the 6 the user had dialled, *accelerating* the belt while the dashboard read
    /// "slowing down" (finding 111).
    ///
    /// **The exception is gone and may not come back.** It used to take fact 1
    /// alone on an axis still travelling toward it, so that a fallback could not
    /// revoke the segment's own command mid-journey (finding 99). That decision was
    /// reversed three times over three review rounds, and the spec now closes it:
    /// any exception is a window in which a brake re-commands a remembered value,
    /// and a person holding the belt away from that value is precisely what keeps
    /// the window open. The accepted consequence is written down there too — a
    /// brake firing during an incline climb leaves the incline where the belt had
    /// got to, which is a segment doing less than it said.
    ///
    /// Every copy of fact 1 the caller holds is folded in the same direction: the
    /// client's target (`command`, an observation seen through the client's
    /// reconcile rule), the runner's record of its own last write (`change.to`) and
    /// the client's live `commandedSpeedKmh` (`appCommand`, when supplied). A `min`
    /// cannot be raised by adding a term, so more copies only ever make it more
    /// conservative — and the live one matters: after an in-app "−" press the
    /// client's own record is the only copy that has come down.
    static func reference(command: Command, lastAppliedChange change: Change,
                          appCommand: Command? = nil,
                          belt: BeltFacts = .unobserved) -> Command {
        var speedUnits = min(speedUnits(command.speedKmh), speedUnits(change.to.speedKmh))
        var incline = min(command.incline, change.to.incline)
        for fact in [appCommand, belt.measured].compactMap({ $0 }) {
            speedUnits = min(speedUnits, self.speedUnits(fact.speedKmh))
            incline = min(incline, fact.incline)
        }
        return Command(speedKmh: speedKmh(units: speedUnits), incline: incline)
    }

    /// The reference, brought under the device's own ceiling — downward only, so
    /// repairing a bound can never be a way for a restatement to become an
    /// increase. The client clamps upward when it writes.
    private static func clampedDown(_ command: Command,
                                    to limits: TreadmillLimits) -> Command {
        Command(speedKmh: min(command.speedKmh, deviceSpeedBounds(limits).upperBound),
                incline: min(command.incline, deviceInclineBounds(limits).upperBound))
    }

    /// Did the user turn a dial? **Fact 3**, and the governor does not compute it:
    /// it is inferred from the measured values by
    /// `ConsoleDialDetector` in the client, which sees every frame instead of
    /// every tenth second and knows what the app commanded and when.
    ///
    /// That is the redesign. The three rounds of blockers before it all came out
    /// of inferring this from `Input.command` — a corridor around the app's own
    /// write, an arrival latch, a floating-point dead band, an incline dead band —
    /// and every piece of that machinery blinded the axis it was meant to protect.
    static func isManualIntervention(_ input: Input) -> Bool {
        input.belt.isSetByHand
    }

    /// Two commands equal on the protocol's own grid — compared as the integers
    /// the wire carries, never as floating-point km/h.
    static func isSameCommand(_ one: Command, _ other: Command) -> Bool {
        speedUnits(one.speedKmh) == speedUnits(other.speedKmh) && one.incline == other.incline
    }

    /// Is this an observed change of **load**, rather than the noise a belt reports
    /// around a value it is holding?
    ///
    /// The threshold is the loop's own step, per axis: a change the size of the step
    /// that earns a 45 s settle window has to earn one too, whoever made it. The
    /// caller is `ProgramRunner.GovernorRun.observing(_:)`, which re-arms the settle
    /// window on any observed change of load and not only on the app's own writes
    /// (finding 137) — the loop used to be free to step up ten seconds after a
    /// manual reduction, from a heart rate that still described the load before it.
    ///
    /// Measured against the value the window was armed at rather than against the
    /// previous tick, so a tenth of jitter either side of one value never
    /// accumulates into a change and never re-arms the window for ever. Integer
    /// units, like every other comparison of two speeds in this file.
    static func isLoadChanged(from: Command, to: Command) -> Bool {
        abs(speedUnits(to.speedKmh) - speedUnits(from.speedKmh)) >= speedUnits(maxSpeedStepKmh)
            || abs(to.incline - from.incline) >= maxInclineStep
    }

    /// How long a change of this actuator is given to show up in the reading.
    static func settleSeconds(for actuator: HeartRateActuator) -> Double {
        actuator == .incline ? inclineSettleAfterChangeSeconds : settleAfterChangeSeconds
    }

    // MARK: - The decision

    static func decide(_ input: Input) -> Decision {
        let resolved = Resolved(input)
        for rung in Rung.allCases {
            if let decision = decision(on: rung, resolved) { return decision }
        }
        // Unreachable: `insideBand` and `followBand` are jointly total. Frozen is
        // the safest answer if a rung is ever removed — it writes nothing.
        return .frozen
    }

    private static func decision(on rung: Rung, _ r: Resolved) -> Decision? {
        switch rung {
        case .stopCeiling:
            guard r.input.tallies.secondsAboveStopCeiling >= stopHoldSeconds else { return nil }
            return .emergencyStop

        case .feedLostFallback:
            // It runs under a hand-back, exactly as the two ceilings do: it can
            // only restate or lower the load, so it cannot do the thing the
            // hand-back rule exists to prevent (spec section 4, "The fallback
            // survives a hand-back, for the same reason the ceilings do";
            // finding 98). It used to be skipped on a hand-back, which meant a
            // *falsely* inferred person silently disabled the one rule that
            // answers a dead feed.
            guard !r.hasFreshReading,
                  r.input.tallies.secondsWithoutHeartRate >= feedLossFallbackSeconds
            else { return nil }
            let fallback = fallbackCommand(r)
            // No cross-axis step here, unlike the force-down below: the fallback is
            // a declared destination rather than a rule that stands and steps, and
            // when there is nothing left to take off it says `.frozen` rather than
            // claiming a reduction it is not making.
            return r.changes(fallback, on: r.actuator, within: .device)
                ? .fallback(command: fallback) : .frozen

        case .forceDownCeiling:
            guard r.input.tallies.secondsAboveForceDownCeiling >= forceDownHoldSeconds
            else { return nil }
            // The status still says ceiling while the interval runs: the rule is
            // active, it just may not write twice inside one evaluation window.
            guard r.input.secondsSinceLastCommand >= evaluationIntervalSeconds else {
                return .hold(reason: .ceilingForceDown)
            }
            // Bounded by the device and not by the segment: a brake is not
            // bounded by the corridor it is braking inside.
            let reduced = moved(r, axis: r.actuator, towards: -1,
                                magnitudeKmh: maxSpeedStepKmh, bounds: .device)
            if r.changes(reduced, on: r.actuator, within: .device) {
                return .adjust(command: reduced, reason: .ceilingForceDown)
            }
            // The actuated axis is at the machine's own bound with nothing left to
            // take off — and a brake that has run out of room on one axis has not
            // run out of options, so the load comes off the other one instead,
            // bounded by the device there too. An incline-actuated segment used to
            // become a permanent no-op the moment the incline reached the flattest
            // the machine does, while the dashboard went on reporting that the app
            // was slowing the belt down (finding 112).
            let crossed = moved(r, axis: r.actuator.other, towards: -1,
                                magnitudeKmh: maxSpeedStepKmh, bounds: .device)
            if r.changes(crossed, on: r.actuator.other, within: .device) {
                return .adjust(command: crossed, reason: .ceilingForceDown)
            }
            // Both axes are at the machine's floor: the one honest hold left, the
            // rule standing with nothing anywhere to take off.
            return .hold(reason: .ceilingForceDown)

        case .manualControl:
            return r.isManualIntervention ? .manualControl : nil

        case .outOfBoundsCorrection:
            guard let corrected = correctedIntoBounds(r),
                  r.changes(corrected, on: r.actuator, within: .segment) else { return nil }
            return .adjust(command: corrected, reason: .outOfBounds)

        case .feedLostFreeze:
            return r.hasFreshReading ? nil : .frozen

        case .bandNotSteerable:
            guard r.arbitration == .notSteerable else { return nil }
            return .hold(reason: .bandNotSteerable)

        case .stalledAtUpperBound:
            guard r.bandError < 0 else { return nil }
            let atBound = r.isAtUpperBound
                && r.input.tallies.secondsAtUpperBoundBelowBand >= stallWindowSeconds
            let pulledBack = r.input.tallies.didForceDown
                && r.input.tallies.secondsBelowBandAfterForceDown >= stallWindowSeconds
            guard atBound || pulledBack else { return nil }
            return .hold(reason: .targetUnreachable)

        case .settling:
            let settle = settleSeconds(for: r.actuator)
            // Any of the three: the segment's own ramp, the app's last write, and
            // the last observed change of load. The third is the one a person's dial
            // moves (finding 137) — without it the first step after a manual
            // reduction could be commanded ten seconds later, from a reading that
            // still described the load the person had just chosen to leave.
            guard r.input.secondsSinceSegmentStart < settle
                    || r.input.secondsSinceLastCommand < settle
                    || r.input.secondsSinceLoadChange < settle else { return nil }
            return .hold(reason: .settling)

        case .insideBand:
            return r.bandError == 0 ? .hold(reason: .insideBand) : nil

        case .followBand:
            let error = r.bandError
            guard error != 0 else { return nil }
            let direction = error > 0 ? -1 : 1
            // A reversal inside the margin is the ping-pong the hysteresis exists
            // for: the last change has not been given the benefit of the doubt yet.
            if reverses(direction, r), abs(error) <= reversalMarginBpm {
                return .hold(reason: .hysteresis)
            }
            // The band law is the one rung the *segment's* corridor bounds: it is
            // the user's statement about where they want to train. It is also the
            // only rung that never crosses axes: a brake takes load off wherever it
            // can, a control law steers the axis the segment chose.
            let next = moved(r, axis: r.actuator, towards: direction,
                             magnitudeKmh: speedStepKmh(forError: abs(error)),
                             bounds: .segment)
            guard r.changes(next, on: r.actuator, within: .segment) else {
                return .hold(reason: .atBound)
            }
            return .adjust(command: next, reason: error > 0 ? .aboveBand : .belowBand)
        }
    }

    // MARK: - The control law

    /// The proportional step, quantised and saturated. Quantisation is what makes
    /// this a three-output law; the floor of one quantum is why no error can
    /// persist forever under a step that rounds to nothing.
    static func speedStepKmh(forError errorBpm: Int) -> Double {
        let quantised = quantized(Double(abs(errorBpm)) * speedGainKmhPerBpm, rule: .nearest)
        return min(max(quantised, speedQuantumKmh), maxSpeedStepKmh)
    }

    /// The command one step from the reference on `axis`. The axis it does not move
    /// is restated *at* the reference — `min(fact 1, fact 2)` there too, which is
    /// what makes a small manual change persist with nothing having to detect it.
    ///
    /// `axis` is a parameter rather than `r.actuator` for one reason: a brake at the
    /// machine's bound on the segment's own axis steps the *other* one instead
    /// (finding 112), and the two cases must be the same arithmetic rather than two
    /// spellings of it.
    private static func moved(_ r: Resolved, axis: HeartRateActuator, towards direction: Int,
                              magnitudeKmh: Double, bounds: BoundsKind) -> Command {
        switch axis {
        case .speed:
            return Command(speedKmh: stepped(from: r.reference.speedKmh, direction: direction,
                                             magnitude: magnitudeKmh,
                                             bounds: r.speedBounds(bounds)),
                           incline: r.reference.incline)
        case .incline:
            return Command(speedKmh: r.reference.speedKmh,
                           incline: stepped(from: r.reference.incline, direction: direction,
                                            magnitude: maxInclineStep,
                                            bounds: r.inclineBounds(bounds)))
        }
    }

    /// One step from `start`, with the step's *magnitude* capped and not merely
    /// its result clamped.
    ///
    /// That distinction is the whole of finding 62. Clamping the result into the
    /// segment's bounds turns a command sitting below the segment's floor into a
    /// single leap up to that floor: a stored start of 3.0 km/h under an 8.0–10.0
    /// corridor became one 5 km/h acceleration, arrived at by adding 0.2. So the
    /// bounds may pull a step back *toward* `start`, never push it past one step.
    /// Upward, when one step cannot even reach the floor, the answer is to stay
    /// put — raising the load is the one move that has to be earned, and no
    /// reading earns five km/h at once. Downward the clamp may travel further
    /// than a step, because a command above the segment's ceiling has to come
    /// back and a bigger reduction is still a reduction.
    private static func stepped(from start: Double, direction: Int, magnitude: Double,
                                bounds: ClosedRange<Double>) -> Double {
        let raw = quantized(start + Double(direction) * magnitude, rule: .nearest)
        let bounded = min(max(raw, bounds.lowerBound), bounds.upperBound)
        // A step down must not come back up: a command already below the
        // segment's floor would otherwise be *raised* by the bounds clamp — an
        // acceleration arrived at by reducing the load, which is the one move
        // this design refuses.
        guard direction > 0 else { return min(bounded, start) }
        let capped = min(bounded, raw)
        guard speedUnits(capped) >= speedUnits(bounds.lowerBound) else { return start }
        return max(capped, start)
    }

    private static func stepped(from start: Int, direction: Int, magnitude: Int,
                                bounds: ClosedRange<Int>) -> Int {
        let raw = start + direction * magnitude
        let bounded = min(max(raw, bounds.lowerBound), bounds.upperBound)
        guard direction > 0 else { return min(bounded, start) }
        let capped = min(bounded, raw)
        guard capped >= bounds.lowerBound else { return start }
        return max(capped, start)
    }

    /// A reference above the segment's upper bound, brought back to it — nil when
    /// there is nothing above the bound to correct. Nil rather than "the command
    /// unchanged", because the reference and the client's target are two different
    /// numbers now and "unchanged" would read as a decision. There is no
    /// counterpart below the lower bound, for the reason `stepped` gives.
    private static func correctedIntoBounds(_ r: Resolved) -> Command? {
        let segmentSpeed = r.speedBounds(.segment)
        let segmentIncline = r.inclineBounds(.segment)
        switch r.actuator {
        case .speed:
            guard speedUnits(r.reference.speedKmh) > speedUnits(segmentSpeed.upperBound)
            else { return nil }
            return Command(speedKmh: segmentSpeed.upperBound, incline: r.reference.incline)
        case .incline:
            guard r.reference.incline > segmentIncline.upperBound else { return nil }
            return Command(speedKmh: r.reference.speedKmh, incline: segmentIncline.upperBound)
        }
    }

    /// Where a lost feed leaves the belt. Never above the reference: a fallback
    /// that accelerates would be the failure mode this release has already found
    /// twice, dressed as a safety feature.
    ///
    /// Bounded by the device and not by the segment, like the two ceilings: a
    /// declared fallback below the corridor's floor is honoured, and a stored 0
    /// therefore means the slowest walk this machine does rather than the
    /// segment's own floor. Still never a stop — the device minimum is a walking
    /// speed, not zero.
    private static func fallbackCommand(_ r: Resolved) -> Command {
        switch r.actuator {
        case .speed:
            let declared = clampedSpeed(r.input.target.fallbackSpeedKmh,
                                        into: r.speedBounds(.device))
            return Command(speedKmh: min(r.reference.speedKmh, declared),
                           incline: r.reference.incline)
        case .incline:
            return Command(speedKmh: r.reference.speedKmh,
                           incline: min(r.reference.incline,
                                        r.inclineBounds(.device).lowerBound))
        }
    }

    /// Would a step in `direction` undo the app's last change? A change of less
    /// than half a quantum is no change, so it has no direction to reverse.
    private static func reverses(_ direction: Int, _ r: Resolved) -> Bool {
        let change = r.input.lastAppliedChange
        let delta = r.actuator == .speed
            ? speedUnits(change.to.speedKmh) - speedUnits(change.from.speedKmh)
            : change.to.incline - change.from.incline
        guard delta != 0 else { return false }
        return (delta > 0) != (direction > 0)
    }

    private static func clampedSpeed(_ speedKmh: Double,
                                     into bounds: ClosedRange<Double>) -> Double {
        guard speedKmh.isFinite else { return bounds.lowerBound }
        let snapped = quantized(speedKmh, rule: .nearest)
        return min(max(snapped, bounds.lowerBound), bounds.upperBound)
    }

    private enum QuantizeRule { case up, down, nearest }

    /// Onto the protocol's 0.1 km/h grid. The rule is the caller's, because a
    /// bound has to move inward and a command has to move to the nearest step.
    private static func quantized(_ speedKmh: Double, rule: QuantizeRule) -> Double {
        guard speedKmh.isFinite else { return 0 }
        let units = speedKmh * speedUnitsPerKmh
        let rounded: Double
        switch rule {
        // The epsilon absorbs the division's own error, so a value already on the
        // grid is not nudged off it by a rounding rule that means to leave it be.
        case .up: rounded = (units - 1e-9).rounded(.up)
        case .down: rounded = (units + 1e-9).rounded(.down)
        case .nearest: rounded = units.rounded()
        }
        return rounded / speedUnitsPerKmh
    }

    /// Everything a rung needs, resolved once. The bounds are repaired here and
    /// the band is arbitrated against the ceilings here, so no rung has to trust
    /// the stored target's ordering or its plausibility.
    private struct Resolved {
        let input: Input
        let arbitration: BandArbitration
        let band: ClosedRange<Int>
        let ceilings: Ceilings
        let segmentSpeedBounds: ClosedRange<Double>
        let segmentInclineBounds: ClosedRange<Int>
        let deviceSpeedBounds: ClosedRange<Double>
        let deviceInclineBounds: ClosedRange<Int>
        let hasFreshReading: Bool
        let isManualIntervention: Bool
        let isAtUpperBound: Bool
        /// The one number every rung measures from, on both axes and with no
        /// exception: see `HeartRateGovernor.reference(command:lastAppliedChange:
        /// appCommand:belt:)`, brought under the device's own ceiling here.
        let reference: Command

        init(_ input: Input) {
            self.input = input
            arbitration = HeartRateGovernor.arbitration(for: input.target, basis: input.basis)
            // The raw band when there is nothing steerable: the `bandNotSteerable`
            // rung fires before anything reads this, and the raw band keeps
            // `bandError` agreeing with the caller's own tallies.
            band = arbitration.band ?? HeartRateGovernor.band(for: input.target)
            ceilings = HeartRateGovernor.ceilings(for: input.basis)
            segmentSpeedBounds = HeartRateGovernor.speedBounds(for: input.target,
                                                               limits: input.limits)
            segmentInclineBounds = HeartRateGovernor.inclineBounds(for: input.target,
                                                                   limits: input.limits)
            deviceSpeedBounds = HeartRateGovernor.deviceSpeedBounds(input.limits)
            deviceInclineBounds = HeartRateGovernor.deviceInclineBounds(input.limits)
            hasFreshReading = input.heartRate > 0
            isManualIntervention = HeartRateGovernor.isManualIntervention(input)
            reference = HeartRateGovernor.clampedDown(
                HeartRateGovernor.reference(command: input.command,
                                            lastAppliedChange: input.lastAppliedChange,
                                            appCommand: input.appCommand,
                                            belt: input.belt),
                to: input.limits)
            // Fact 1 for the bound test: the live copy when the caller holds it,
            // because it is the one an in-app "−" press brings down at once, and
            // the runner's record of its own last write otherwise. Never
            // `input.command`, which is an observation.
            isAtUpperBound = HeartRateGovernor.isAtUpperBound(
                reference: reference,
                appCommand: input.appCommand ?? input.lastAppliedChange.to,
                target: input.target, limits: input.limits)
        }

        var actuator: HeartRateActuator { input.target.actuator }

        /// One axis of a command, so a rung can be stated once instead of once per
        /// axis — and so a brake can be pointed at either one (finding 112).
        func value(_ command: Command, on axis: HeartRateActuator) -> Double {
            axis == .speed ? command.speedKmh : Double(command.incline)
        }

        func actuated(_ command: Command) -> Double { value(command, on: actuator) }

        func speedBounds(_ kind: BoundsKind) -> ClosedRange<Double> {
            kind == .segment ? segmentSpeedBounds : deviceSpeedBounds
        }

        func inclineBounds(_ kind: BoundsKind) -> ClosedRange<Int> {
            kind == .segment ? segmentInclineBounds : deviceInclineBounds
        }

        func bounds(_ kind: BoundsKind, on axis: HeartRateActuator) -> ClosedRange<Double> {
            guard axis == .speed else {
                let bounds = inclineBounds(kind)
                return Double(bounds.lowerBound)...Double(bounds.upperBound)
            }
            return speedBounds(kind)
        }

        /// Is this candidate worth sending?
        ///
        /// It has to be legal first: nothing outside the caller's own bounds is
        /// ever emitted, which is also what stops a reference that already sits
        /// outside them from being written back out by a rung that found nothing
        /// to move. Which bounds those are is the rung's to say — the segment's
        /// corridor for the band law, the device's own limits for a brake (see
        /// `deviceSpeedBounds(_:)`).
        ///
        /// Then either of two things makes it a decision. The arithmetic moved it
        /// away from the reference — the ordinary case — or the belt is
        /// *observed* above the reference, in which case re-asserting the
        /// reference is a real reduction and not a no-op: it is how a forced
        /// reduction still reduces when the console has been dialled above the
        /// app's last write, and how the app re-states a deceleration a console
        /// has quietly stopped tracking.
        ///
        /// `axis` is the axis the rung actually moved, which is the segment's own
        /// for everything except a brake that has crossed to the other one
        /// (finding 112) — judging a cross-axis reduction by the axis it did not
        /// touch would report it as a no-op.
        func changes(_ candidate: Command, on axis: HeartRateActuator,
                     within kind: BoundsKind) -> Bool {
            let epsilon = HeartRateGovernor.speedQuantumKmh / 2
            let bounds = bounds(kind, on: axis)
            let candidateValue = value(candidate, on: axis)
            guard candidateValue >= bounds.lowerBound - epsilon,
                  candidateValue <= bounds.upperBound + epsilon else { return false }
            let referenceValue = value(reference, on: axis)
            if abs(candidateValue - referenceValue) >= epsilon { return true }
            // Either observation will do here, and using one changes nothing about
            // what may be *emitted*: the candidate is already the reference, so the
            // only question is whether re-sending it does any work.
            let observed = max(value(input.command, on: axis),
                               input.belt.measured.map { value($0, on: axis) } ?? -.infinity)
            return observed > referenceValue + epsilon
        }

        /// The bpm outside the band: positive above it, negative below it, 0
        /// inside. Only meaningful with a fresh reading, which every rung that
        /// reads it has already established.
        var bandError: Int {
            if input.heartRate > band.upperBound { return input.heartRate - band.upperBound }
            if input.heartRate < band.lowerBound { return input.heartRate - band.lowerBound }
            return 0
        }
    }
}
