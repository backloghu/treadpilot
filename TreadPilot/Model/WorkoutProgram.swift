// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import Foundation

/// `TreadmillLimits` itself lives in `TreadPilot/FitShow/FitShowProtocol.swift`,
/// next to the client; this extension is here because only the editor has any
/// use for combining two of them (finding 119).
extension TreadmillLimits {
    /// The narrower of two limits, axis by axis — never wider than either one.
    /// `ProgramEditorView` uses this to bound itself by the connected device
    /// *and* the plausible default range at once, so nothing it produces can be
    /// wider than what `HeartRateTarget.isUsable` (measured against the default)
    /// already accepts, whichever direction a real device's own limits differ
    /// from the default in.
    ///
    /// Collapsed to a single point rather than left inverted if the two ranges
    /// do not overlap at all — a malformed limits reading from a real device
    /// must not turn an editor range downstream into the exact trap finding 118
    /// reports, just from a different cause.
    static func narrower(_ a: TreadmillLimits, _ b: TreadmillLimits) -> TreadmillLimits {
        let minSpeedRaw = max(a.minSpeedRaw, b.minSpeedRaw)
        let maxSpeedRaw = max(minSpeedRaw, min(a.maxSpeedRaw, b.maxSpeedRaw))
        let minIncline = max(a.minIncline, b.minIncline)
        let maxIncline = max(minIncline, min(a.maxIncline, b.maxIncline))
        return TreadmillLimits(minSpeedRaw: minSpeedRaw, maxSpeedRaw: maxSpeedRaw,
                               minIncline: minIncline, maxIncline: maxIncline,
                               fromDevice: a.fromDevice || b.fromDevice)
    }
}

/// What ends a segment. A segment has two independent axes: the goal (when is it
/// over) and the target (what does it command).
enum SegmentGoal: Equatable, Hashable, Sendable {
    case time(seconds: Int)
    case distance(km: Double)
    /// Active recovery: hold the target until the heart rate drops below `bpm`,
    /// but never longer than `maxSeconds`. The cap is mandatory, so a failed
    /// sensor cannot stall the program — with no reading at all the segment is a
    /// plain time goal of `maxSeconds`.
    case untilHeartRateBelow(bpm: Int, maxSeconds: Int)

    /// The stored discriminator (`CustomSegmentRecord.goalKindRaw`).
    enum Kind: String, CaseIterable, Sendable {
        case time
        case distance
        case untilHeartRateBelow
    }

    var kind: Kind {
        switch self {
        case .time:
            return .time
        case .distance:
            return .distance
        case .untilHeartRateBelow:
            return .untilHeartRateBelow
        }
    }

    /// Does the goal need a moving belt to be satisfiable at all? Only recovery
    /// does: it waits for a heart rate to come down, which a standing belt never
    /// makes happen, and 0 km/h is a stop rather than a target.
    var requiresWalkingTarget: Bool {
        if case .untilHeartRateBelow = self { return true }
        return false
    }
}

/// Which axis a heart-rate segment lets the governor move. One segment, one
/// actuator: two loops on one plant fight each other, and the axis is the user's
/// choice, not the controller's.
enum HeartRateActuator: String, Equatable, Hashable, Sendable, CaseIterable {
    case speed
    case incline
}

/// What a heart-rate segment commands: the band to hold, the axis to hold it
/// with, and the bounds it may move between. Read by `HeartRateGovernor`.
struct HeartRateTarget: Equatable, Hashable, Sendable {
    var lowBpm: Int
    var highBpm: Int
    var actuator: HeartRateActuator = .speed
    /// The command the segment starts from — and the one it runs at end to end
    /// when heart-rate control is switched off. Stored in the same two columns a
    /// fixed target uses, which is what makes surrendering control a read rather
    /// than a migration.
    var startSpeedKmh: Double
    var startIncline: Int
    var minSpeedKmh: Double
    var maxSpeedKmh: Double
    var minIncline: Int
    var maxIncline: Int
    /// Where a speed-actuated segment goes when the feed has been gone for
    /// `HeartRateGovernor.feedLossFallbackSeconds`. The stored default is 0,
    /// which clamps into the segment's own lower bound — that clamp is what
    /// keeps the fallback off zero without a second validation rule.
    var fallbackSpeedKmh: Double = 0
}

extension HeartRateTarget {
    // The ranges the editor may offer, next to the model rather than in the view.
    // This release has twice shipped an editor that could not represent a value
    // the model had stored, and walking such a value back took a hundred taps.

    /// The heart rates a band may be drawn between: under 60 is a resting rate,
    /// over 220 is above any plausible maximum.
    static let bandRangeBpm = 60...220
    static let bandStepBpm = 1
    /// A band narrower than this cannot be held: one 0.2 km/h step moves the
    /// steady-state heart rate by roughly 2 bpm, so a hair-thin band leaves the
    /// loop no output that lands inside it and it oscillates instead.
    static let minBandWidthBpm = 5
    /// Speeds for the start command, the bounds and the fallback. The editor
    /// cannot know the device's own limits — the same reason `ProgramEditorView`
    /// bounds its steppers with a default `TreadmillLimits()` — and the governor
    /// intersects with the real ones at run time.
    static let speedRangeKmh = TreadmillLimits().minSpeedKmh...TreadmillLimits().maxSpeedKmh
    /// The editor's Stepper increment, which is the protocol's 0.1 km/h grid —
    /// taken from the governor rather than spelled again, because a bound off that
    /// grid is a bound the belt cannot be set to.
    static let speedStepKmh = HeartRateGovernor.speedQuantumKmh
    static let inclineRange = TreadmillLimits().minIncline...TreadmillLimits().maxIncline
    /// The band a fresh target starts from when the caller offers none. The
    /// editor should pass the user's own zone instead; this is the floor.
    static let defaultBandBpm = 130...145
    /// How much authority a freshly seeded target is given on each axis. A first
    /// release does not hand the loop the machine's whole range by default — the
    /// user widens it deliberately.
    static let seededSpeedCorridorKmh = 2.0
    static let seededInclineCorridor = 2

    /// Is this payload something the governor could actually steer with? A stored
    /// target that fails here reads as a fixed segment at its start command — the
    /// honest degradation, and the same one the opt-in-off path takes.
    ///
    /// Against the default `TreadmillLimits()` — the one every existing caller in
    /// this codebase already measures against (`ProgramRunner.gate`, storage's own
    /// `CustomSegmentRecord.target`), and the one this property must go on
    /// producing for them without a signature change. See
    /// `isUsable(within:)` for the parametrised check finding 119 asks for: "one
    /// source of truth", chosen as an additional overload rather than a change to
    /// this property, because `ProgramRunner.swift` calls this exact spelling and
    /// this packet may not touch that file.
    var isUsable: Bool { isUsable(within: TreadmillLimits()) }

    /// `isUsable`, against `limits` rather than always the hardcoded default.
    ///
    /// Spec finding 119: a segment's own usability was checked only against a
    /// `TreadmillLimits()` built fresh from its default member values, with no
    /// connection to whatever device the segment will actually run on. On a real
    /// machine wider than the default this rejects a start command or a corridor
    /// edge the device can perfectly well hold; on one narrower it can accept a
    /// corridor the belt can never fully occupy. `ProgramEditorView` uses this
    /// packet's fix for that — narrowing its own steppers to
    /// `TreadmillLimits.narrower(client.limits, TreadmillLimits())` — so nothing
    /// it produces can fail this check called either way; this overload is the
    /// one call sites with a real device in hand (a future `ProgramRunner`
    /// change, in particular) should prefer.
    func isUsable(within limits: TreadmillLimits) -> Bool {
        let low = min(lowBpm, highBpm)
        let high = max(lowBpm, highBpm)
        guard Self.bandRangeBpm.contains(low), Self.bandRangeBpm.contains(high),
              high - low >= Self.minBandWidthBpm else { return false }
        let speedRange = limits.minSpeedKmh...limits.maxSpeedKmh
        let inclineRange = limits.minIncline...limits.maxIncline
        // Both axes are commanded whatever the actuator is — `setTarget` writes
        // the pair — so a start value the machine cannot represent is a payload
        // the segment cannot be started from, actuated or not.
        guard startSpeedKmh.isFinite, contains(speedRange, startSpeedKmh),
              inclineRange.contains(startIncline) else { return false }
        switch actuator {
        case .speed:
            guard minSpeedKmh.isFinite, maxSpeedKmh.isFinite,
                  contains(speedRange, minSpeedKmh),
                  contains(speedRange, maxSpeedKmh) else { return false }
            // The start command has to be inside the corridor the loop will steer
            // in. Nothing else checks it: the editor writes the start command
            // through the same speed stepper a fixed segment uses, which knows
            // nothing about these bounds, so a stored start of 3.0 under an
            // 8.0–10.0 corridor is reachable by hand — and a loop that then
            // clamped its first step into the bounds would take the belt from 3.0
            // to 8.0 in one command. Degrading to a fixed segment is the honest
            // answer, and it is the one every other degeneracy here already gets.
            guard contains(min(minSpeedKmh, maxSpeedKmh)...max(minSpeedKmh, maxSpeedKmh),
                           startSpeedKmh) else { return false }
            // Room for at least one step on the actuated axis, or the loop is
            // pinned wherever it starts and chases a band it cannot move toward.
            // In protocol units, so the answer does not depend on which of the two
            // ways of writing 0.1 km/h the stored bounds happen to hold.
            return HeartRateGovernor.speedUnits(maxSpeedKmh)
                - HeartRateGovernor.speedUnits(minSpeedKmh) >= 1
        case .incline:
            guard inclineRange.contains(minIncline),
                  inclineRange.contains(maxIncline),
                  (min(minIncline, maxIncline)...max(minIncline, maxIncline))
                      .contains(startIncline) else { return false }
            return maxIncline - minIncline >= HeartRateGovernor.maxInclineStep
        }
    }

    /// `ClosedRange.contains` on the protocol's own grid: a stored speed off the
    /// 0.1 km/h grid by less than half a quantum is the same command on the wire,
    /// and must not be read as a payload the machine cannot hold. Compared as the
    /// integers the wire carries, because half a quantum in binary floating point
    /// is not half a quantum.
    private func contains(_ range: ClosedRange<Double>, _ speedKmh: Double) -> Bool {
        let units = HeartRateGovernor.speedUnits(speedKmh)
        return units >= HeartRateGovernor.speedUnits(range.lowerBound)
            && units <= HeartRateGovernor.speedUnits(range.upperBound)
    }

    /// This target if it is usable, otherwise the same values repaired into the
    /// editor's ranges. Keeps whatever the user already typed instead of throwing
    /// a half-filled band away.
    var repairedForEditing: HeartRateTarget {
        guard !isUsable else { return self }
        let band = lowBpm > 0 && highBpm > 0
            ? min(lowBpm, highBpm)...max(lowBpm, highBpm)
            : Self.defaultBandBpm
        return .seeded(startSpeedKmh: startSpeedKmh, startIncline: startIncline,
                       band: band, actuator: actuator)
    }

    /// A band inside `bandRangeBpm` and at least `minBandWidthBpm` wide. It
    /// widens downward: the upper edge is the one that costs effort, so a repair
    /// must never ask for more than the caller did.
    static func repairedBand(_ band: ClosedRange<Int>) -> ClosedRange<Int> {
        repairedBand(band, within: bandRangeBpm)
    }

    /// `repairedBand`, against an arbitrary plausible range rather than always
    /// `bandRangeBpm` — the live profile's own holdable band, when the caller has
    /// one (finding 118: a band valid against the absolute range can still be
    /// unholdable on this profile's force-down ceiling, and a repair that never
    /// checks that is a repair that leaves the trap in place). `plausible` is
    /// never narrower than `minBandWidthBpm`, for both callers this packet
    /// gives it: `bandRangeBpm` is 160 wide, and
    /// `HeartRateGovernor.holdableBandRangeBpm(for:)` is built so its own width
    /// is never under `minBandWidthBpm` either — so this can never invert.
    static func repairedBand(_ band: ClosedRange<Int>,
                             within plausible: ClosedRange<Int>) -> ClosedRange<Int> {
        let high = min(max(max(band.lowerBound, band.upperBound),
                           plausible.lowerBound + minBandWidthBpm),
                       plausible.upperBound)
        let low = min(max(min(band.lowerBound, band.upperBound), plausible.lowerBound),
                      high - minBandWidthBpm)
        return low...high
    }

    /// The "Band low" stepper's range for a band being edited against
    /// `holdableRange` — the live profile's own holdable band. Structurally safe
    /// against inversion for *any* stored `highBpm`, which is the point: a band
    /// that was valid when it was seeded can outlive the profile it was seeded
    /// against (a lower maximum-heart-rate override typed in afterwards), and the
    /// trap finding 118 reports is exactly a Stepper `in:` range computed from a
    /// `highBpm` that used to be valid and no longer is. `max(holdableRange
    /// .lowerBound, …)` is what makes the upper end of this range unable to fall
    /// below its own lower end no matter what `highBpm` holds.
    static func lowBpmEditingRange(highBpm: Int,
                                   holdableRange: ClosedRange<Int>) -> ClosedRange<Int> {
        let upper = max(holdableRange.lowerBound,
                        min(holdableRange.upperBound - minBandWidthBpm,
                            highBpm - minBandWidthBpm))
        return holdableRange.lowerBound...upper
    }

    /// The "Band high" stepper's range — the same reasoning, the other edge, and
    /// the one finding 118 was actually filed against.
    static func highBpmEditingRange(lowBpm: Int,
                                    holdableRange: ClosedRange<Int>) -> ClosedRange<Int> {
        let lower = min(holdableRange.upperBound,
                        max(holdableRange.lowerBound + minBandWidthBpm,
                            lowBpm + minBandWidthBpm))
        return lower...holdableRange.upperBound
    }

    /// The "Min speed" corridor stepper's range against `limits` — the same
    /// inversion-proof shape as `lowBpmEditingRange`, generalised to the speed
    /// corridor that finding 119 makes device-aware: a corridor edge valid
    /// against one connected device is not guaranteed to still fit a different
    /// one, or the plausible default range with nothing connected at all.
    static func minSpeedEditingRange(maxSpeedKmh: Double,
                                     limits: TreadmillLimits) -> ClosedRange<Double> {
        let upper = max(limits.minSpeedKmh,
                        min(limits.maxSpeedKmh - HeartRateGovernor.speedQuantumKmh,
                            maxSpeedKmh - HeartRateGovernor.speedQuantumKmh))
        return limits.minSpeedKmh...upper
    }

    /// The "Max speed" corridor stepper's range — the other edge.
    static func maxSpeedEditingRange(minSpeedKmh: Double,
                                     limits: TreadmillLimits) -> ClosedRange<Double> {
        let lower = min(limits.maxSpeedKmh,
                        max(limits.minSpeedKmh + HeartRateGovernor.speedQuantumKmh,
                            minSpeedKmh + HeartRateGovernor.speedQuantumKmh))
        return lower...limits.maxSpeedKmh
    }

    /// The "Min incline" corridor stepper's range — the incline counterpart.
    static func minInclineEditingRange(maxIncline: Int,
                                       limits: TreadmillLimits) -> ClosedRange<Int> {
        let upper = max(limits.minIncline,
                        min(limits.maxIncline - HeartRateGovernor.maxInclineStep,
                            maxIncline - HeartRateGovernor.maxInclineStep))
        return limits.minIncline...upper
    }

    /// The "Max incline" corridor stepper's range — the other edge.
    static func maxInclineEditingRange(minIncline: Int,
                                       limits: TreadmillLimits) -> ClosedRange<Int> {
        let lower = min(limits.maxIncline,
                        max(limits.minIncline + HeartRateGovernor.maxInclineStep,
                            minIncline + HeartRateGovernor.maxInclineStep))
        return lower...limits.maxIncline
    }

    /// A target the editor can show immediately, seeded from the segment's
    /// current command. Every value lands inside the ranges above and on their
    /// grid: phase 1's lesson is that a seeded value the editor cannot represent
    /// leaves the user unable to walk it back.
    static func seeded(startSpeedKmh: Double, startIncline: Int,
                       band: ClosedRange<Int> = defaultBandBpm,
                       actuator: HeartRateActuator = .speed) -> HeartRateTarget {
        let repaired = repairedBand(band)
        let start = quantizedSpeed(startSpeedKmh)
        let incline = min(max(startIncline, inclineRange.lowerBound), inclineRange.upperBound)
        let low = max(speedRangeKmh.lowerBound,
                      quantizedSpeed(start - seededSpeedCorridorKmh))
        return HeartRateTarget(
            lowBpm: repaired.lowerBound,
            highBpm: repaired.upperBound,
            actuator: actuator,
            startSpeedKmh: start,
            startIncline: incline,
            minSpeedKmh: low,
            maxSpeedKmh: min(speedRangeKmh.upperBound,
                             quantizedSpeed(start + seededSpeedCorridorKmh)),
            minIncline: max(inclineRange.lowerBound, incline - seededInclineCorridor),
            maxIncline: min(inclineRange.upperBound, incline + seededInclineCorridor),
            fallbackSpeedKmh: low)
    }

    /// Onto the protocol's 0.1 km/h grid and inside `speedRangeKmh`. Built as
    /// `units / 10` for the same reason `TreadmillLimits.minSpeedKmh` is: 82 × 0.1
    /// and 8.2 are not the same Double, and the governor reads one bit of drift as
    /// somebody having turned a dial.
    static func quantizedSpeed(_ speedKmh: Double) -> Double {
        guard speedKmh.isFinite else { return speedRangeKmh.lowerBound }
        let clamped = min(max(speedKmh, speedRangeKmh.lowerBound), speedRangeKmh.upperBound)
        return HeartRateGovernor.speedKmh(units: HeartRateGovernor.speedUnits(clamped))
    }
}

/// What the segment commands. The second axis: `SegmentGoal` says when the
/// segment is over, this says what it asks of the belt while it runs.
enum SegmentTarget: Equatable, Hashable, Sendable {
    case fixed(speedKmh: Double, incline: Int)
    case heartRate(HeartRateTarget)

    /// The stored discriminator (`CustomSegmentRecord.targetKindRaw`).
    enum Kind: String, CaseIterable, Sendable {
        case fixed
        case heartRate
    }

    var kind: Kind {
        switch self {
        case .fixed:
            return .fixed
        case .heartRate:
            return .heartRate
        }
    }

    /// The command the segment starts from — and, for a heart-rate target, the
    /// one it runs at end to end whenever the loop may not steer: control
    /// switched off, an unusable payload, a feed that never arrives.
    var startSpeedKmh: Double {
        switch self {
        case .fixed(let speedKmh, _):
            return speedKmh
        case .heartRate(let target):
            return target.startSpeedKmh
        }
    }

    var startIncline: Int {
        switch self {
        case .fixed(_, let incline):
            return incline
        case .heartRate(let target):
            return target.startIncline
        }
    }

    /// The governor's payload, or nil for a fixed target — the runner's test for
    /// whether to run the loop at all.
    var heartRate: HeartRateTarget? {
        switch self {
        case .fixed:
            return nil
        case .heartRate(let target):
            return target
        }
    }

    /// This target with the loop surrendered: a fixed command at the start
    /// values. The opt-in-off path and an unusable payload are the same
    /// operation, which is why there is one function for both.
    var withoutHeartRateControl: SegmentTarget {
        .fixed(speedKmh: startSpeedKmh, incline: startIncline)
    }

    /// The same target with its start command at or above `minSpeedKmh`, for the
    /// recovery goal's walking-target rule. It repairs a stored *plan*, not a
    /// running belt: what it replaces is a 0 km/h command, which is a stop.
    func withStartSpeedFloor(_ minSpeedKmh: Double) -> SegmentTarget {
        guard minSpeedKmh.isFinite, startSpeedKmh < minSpeedKmh else { return self }
        switch self {
        case .fixed(_, let incline):
            return .fixed(speedKmh: minSpeedKmh, incline: incline)
        case .heartRate(var target):
            target.startSpeedKmh = minSpeedKmh
            target.minSpeedKmh = max(target.minSpeedKmh, minSpeedKmh)
            return .heartRate(target)
        }
    }
}

/// One workout program segment: a target held until the segment's goal is
/// reached. Both axes are `private(set)` because both carry mandatory repairs
/// that only the initializer applies — an assignment could bypass them.
struct WorkoutSegment: Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    private(set) var goal: SegmentGoal
    private(set) var target: SegmentTarget

    init(id: UUID = UUID(), name: String, goal: SegmentGoal, target: SegmentTarget) {
        self.id = id
        self.name = name
        // Repaired here rather than at every producer: storage, the editor and
        // the tests all build segments, and the recovery goal's two mandatory
        // rules — a cap that exists, a belt that walks — must hold for all three.
        self.goal = Self.repaired(goal)
        self.target = self.goal.requiresWalkingTarget
            ? target.withStartSpeedFloor(Self.recoveryMinSpeedKmh)
            : target
    }

    /// A fixed-target segment. Kept as its own initializer so every call site
    /// that predates the target axis — the built-in programs, the sample data,
    /// storage's own conversion, the tests — reads exactly as it did.
    init(id: UUID = UUID(), name: String, goal: SegmentGoal,
         targetSpeedKmh: Double, targetIncline: Int) {
        self.init(id: id, name: name, goal: goal,
                  target: .fixed(speedKmh: targetSpeedKmh, incline: targetIncline))
    }

    /// A time-goal segment. Kept as its own initializer so every call site that
    /// only ever knew a duration — the built-in programs, the sample data, the
    /// tests — reads exactly as it did before the goal axis existed.
    init(id: UUID = UUID(), name: String, duration: TimeInterval,
         targetSpeedKmh: Double, targetIncline: Int) {
        self.init(id: id, name: name, goal: .time(seconds: Int(duration)),
                  target: .fixed(speedKmh: targetSpeedKmh, incline: targetIncline))
    }

    /// The slowest speed an estimate may divide by. A segment with a zero (or
    /// nonsense) speed would otherwise produce an infinite planned duration and
    /// poison every program total; the runner's ETA uses the same floor, so the
    /// two can never disagree.
    static let minEstimateSpeedKmh = TreadmillLimits().minSpeedKmh
    /// Upper bound for every duration estimate. An estimate is a division: a
    /// nonsense input has to yield an implausible number, never an overflow.
    static let maxEstimateSeconds = 24 * 3600
    /// The distances a distance goal may be given: a tenth of a kilometre up to
    /// a marathon. The editor's stepper takes its range from here, so the two
    /// cannot drift apart.
    static let goalDistanceRangeKm = 0.1...42.2
    /// The grid a distance goal snaps to, and the editor's Stepper step.
    /// Hoisted for the same reason as `goalDurationStepSeconds`: seeding a
    /// value the Stepper cannot represent leaves the editor unable to walk it
    /// back, so the grid has to exist in exactly one place.
    static let goalDistanceStepKm = 0.1
    /// The durations a time goal may be given, and the grid the editor's
    /// Stepper snaps to. Hoisted here for the same reason as
    /// `goalDistanceRangeKm`: switching a goal kind must never seed a value
    /// outside what the editor can represent, so `CustomSegmentRecord`'s own
    /// clamp and the editor's Stepper must read the same numbers instead of
    /// two literals that can drift apart.
    static let goalDurationRangeSeconds = 15...7200
    static let goalDurationStepSeconds = 15
    /// The heart rates a recovery goal may wait for. Its time cap deliberately
    /// reuses `goalDurationRangeSeconds` and its step: it is the same stepper,
    /// and a second spelling of 15...7200 is a second thing to drift.
    static let goalHeartRateBelowRangeBpm = 60...180
    static let goalHeartRateBelowStepBpm = 1
    /// The threshold a fresh recovery goal starts from. The editor should offer
    /// the user's own zone-1 ceiling instead; this is the fallback.
    static let defaultGoalHeartRateBelowBpm = 120
    /// A recovery segment always walks: it waits for a heart rate to come down,
    /// which a standing belt never makes happen, and a 0 km/h target is a stop
    /// that would end the console's workout rather than an active recovery.
    static let recoveryMinSpeedKmh = TreadmillLimits().minSpeedKmh
    /// How long a recovery segment's heart rate must stay under the threshold
    /// before the segment ends — one reading below is noise, which is why the
    /// governor holds its ceilings too. `ProgramRunner` reads it once wired.
    static let recoveryHeartRateHoldSeconds = 5

    /// A goal with its mandatory rules applied. Only recovery has any: a
    /// threshold outside `goalHeartRateBelowRangeBpm` can never be met (0 bpm
    /// means "no reading" throughout this codebase), and a cap of zero is no cap
    /// at all — both degrade to the plain time goal a failed sensor produces.
    static func repaired(_ goal: SegmentGoal) -> SegmentGoal {
        guard case .untilHeartRateBelow(let bpm, let maxSeconds) = goal else { return goal }
        let cap = max(maxSeconds, 0)
        guard goalHeartRateBelowRangeBpm.contains(bpm), cap > 0 else {
            return .time(seconds: cap)
        }
        return .untilHeartRateBelow(bpm: bpm, maxSeconds: cap)
    }

    /// The speed the segment commands: a fixed target's own value, a heart-rate
    /// target's starting value.
    var nominalSpeedKmh: Double { target.startSpeedKmh }

    /// The incline the segment commands — the same indirection, for the same
    /// reason: a heart-rate segment's commanded incline is its starting incline,
    /// and every call site that reads the plan already goes through here.
    var nominalIncline: Int { target.startIncline }

    /// The pre-target-axis spelling of the two above, kept so that no call site
    /// had to change when the target axis landed. New code reads the nominal pair.
    var targetSpeedKmh: Double { nominalSpeedKmh }
    var targetIncline: Int { nominalIncline }

    /// The governor's payload, or nil when this segment does not steer.
    var heartRateTarget: HeartRateTarget? { target.heartRate }

    var isHeartRateDriven: Bool { target.kind == .heartRate }

    /// This segment with heart-rate control surrendered — the opt-in-off path:
    /// an HR-targeted segment then runs at its start command as a fixed segment.
    var withoutHeartRateControl: WorkoutSegment {
        WorkoutSegment(id: id, name: name, goal: goal,
                       target: target.withoutHeartRateControl)
    }

    /// The divisor of every estimate: the commanded speed, floored and finite.
    private var estimateSpeedKmh: Double {
        let speed = nominalSpeedKmh
        return speed.isFinite && speed > Self.minEstimateSpeedKmh ? speed : Self.minEstimateSpeedKmh
    }

    /// Every planned duration passes through here, and so does the runner's live
    /// ETA: `ProgramRunner.clampedSeconds` calls this function and only rounds the
    /// result — one ceiling, applied once. When the two had their own, a 42.2 km
    /// segment at 0.8 km/h planned 52 hours while its ETA was capped at 24, and the
    /// program progress bar was 55% full at second zero because it divided the one
    /// by the other.
    static func cappedDuration(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return min(seconds, TimeInterval(maxEstimateSeconds))
    }

    /// How long the segment is expected to last. Exact for a time goal, an
    /// estimate otherwise — see `isDurationEstimated`.
    var plannedDuration: TimeInterval {
        switch goal {
        case .time(let seconds):
            return Self.cappedDuration(TimeInterval(seconds))
        case .distance(let km):
            guard km.isFinite, km > 0 else { return 0 }
            return Self.cappedDuration(km / estimateSpeedKmh * 3600)
        case .untilHeartRateBelow(_, let maxSeconds):
            // The time cap is the only bound known in advance.
            return Self.cappedDuration(TimeInterval(maxSeconds))
        }
    }

    /// `plannedDuration` in whole seconds. The ceiling is already applied there —
    /// this only rounds, so the two cannot say different things.
    var plannedDurationSeconds: Int {
        Int(plannedDuration.rounded())
    }

    /// How far the segment is expected to cover. Exact for a distance goal, an
    /// estimate otherwise — see `isDistanceEstimated`. The estimated cases read
    /// the *capped* duration: a distance derived from a longer time than the plan
    /// admits would put the program totals on two different scales again.
    var plannedDistanceKm: Double {
        switch goal {
        case .distance(let km):
            return km
        case .time, .untilHeartRateBelow:
            return plannedDuration / 3600 * nominalSpeedKmh
        }
    }

    var isDurationEstimated: Bool {
        if case .time = goal { return false }
        return true
    }

    var isDistanceEstimated: Bool {
        if case .distance = goal { return false }
        return true
    }
}

/// Renderings of a segment's goal, target, speed and pace. They live next to
/// the model so the dashboard, the editor and the program lists cannot drift
/// apart in how a segment reads. Program-level totals are not this enum's
/// concern — a total's two-decimal precision (e.g. `%.2f km`) is a deliberate
/// difference from a segment's one-decimal label, not an omission.
///
/// TODO: `SessionFormat` lives in TreadPilot/UI/HistoryView.swift. Calling it is
/// legal (one module), but the dependency points the wrong way — the app's only
/// duration formatter belongs in the model layer, next to this enum. Moving it
/// touches a UI file, so it is left to a separate change.
enum SegmentFormat {
    /// "5:00" for a time goal, "5.0 km" for a distance goal.
    static func goal(_ goal: SegmentGoal) -> String {
        switch goal {
        case .time(let seconds):
            return SessionFormat.duration(seconds)
        case .distance(let km):
            return distance(km)
        case .untilHeartRateBelow(let bpm, let maxSeconds):
            return String(localized: "<\(bpm) bpm, max \(SessionFormat.duration(maxSeconds))")
        }
    }

    /// "8.0 km/h"
    static func speed(_ speedKmh: Double) -> String {
        String(format: "%.1f km/h", speedKmh)
    }

    /// "8.0 km/h · 0%" — the same order and separator the segment rows use.
    static func target(speedKmh: Double, incline: Int) -> String {
        speed(speedKmh) + " · \(incline)%"
    }

    /// "135–150 bpm" — the band a heart-rate target holds, through the catalog
    /// key the profile's zone rows already use.
    static func heartRateBand(_ target: HeartRateTarget) -> String {
        let band = HeartRateGovernor.band(for: target)
        return String(localized: "\(band.lowerBound)–\(band.upperBound) bpm")
    }

    /// How a segment's target reads in a row: the fixed command, or the band it
    /// holds followed by the command it starts from.
    static func target(_ target: SegmentTarget) -> String {
        switch target {
        case .fixed(let speedKmh, let incline):
            return self.target(speedKmh: speedKmh, incline: incline)
        case .heartRate(let heartRate):
            return heartRateBand(heartRate) + " · "
                + self.target(speedKmh: heartRate.startSpeedKmh,
                              incline: heartRate.startIncline)
        }
    }

    /// "5.0 km"
    static func distance(_ km: Double) -> String {
        String(format: "%.1f km", km)
    }

    /// "3.2 / 5.0 km" — the dashboard's large readout for a distance goal.
    ///
    /// A progress display may only show the goal figure once the segment has
    /// truly finished. Rounding the live distance to one decimal used to show
    /// "1.0 / 1.0 km" for the last 50 metres of a 1.0 km segment, while the
    /// belt kept running for another 20–30 seconds (finding: hardware test
    /// 2026-08-22). So the live side truncates toward zero at the protocol's
    /// 0.1 km resolution instead of rounding, computed in integer tenths —
    /// the same reason `HeartRateGovernor.speedUnits` compares speeds as
    /// integers rather than as Doubles at a 0.1 quantum: a Double truncation
    /// like `(km * 10).rounded(.down) / 10` would drift for the same reason a
    /// `>= 0.1` test does. The goal side keeps `%.1f`, since goals are always
    /// set on exact 0.1 steps. Once `km` has reached `goalKm`, the goal
    /// figure is shown exactly rather than recomputed through the
    /// truncation, so a floating-point sliver past the goal at the moment of
    /// completion can only ever render as the goal, never as one tick short
    /// of it.
    static func distanceProgress(_ km: Double, goalKm: Double) -> String {
        guard km < goalKm else {
            return String(format: "%.1f / %.1f km", goalKm, goalKm)
        }
        let tenths = Int((km * 10).rounded(.down))
        return String(format: "%.1f / %.1f km", Double(tenths) / 10, goalKm)
    }

    /// "7:30 min/km" — runners think in pace. Nil for a standing belt, and for
    /// a speed so low that the pace would say nothing. The unit goes through
    /// the catalog: it used to be a bare " min/km" literal that never reached
    /// the String Catalog, so the Hungarian build showed it in English.
    static func pace(speedKmh: Double) -> String? {
        guard speedKmh.isFinite, speedKmh > 0 else { return nil }
        let secondsPerKm = 3600 / speedKmh
        guard secondsPerKm.isFinite,
              secondsPerKm < Double(WorkoutSegment.maxEstimateSeconds) else { return nil }
        return SessionFormat.duration(Int(secondsPerKm.rounded())) + " " + String(localized: "min/km")
    }
}

struct WorkoutProgram: Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var segments: [WorkoutSegment]
    var isBuiltIn = false

    var totalDuration: TimeInterval {
        segments.reduce(0) { $0 + $1.plannedDuration }
    }

    /// The program's expected total distance: exact for the distance segments,
    /// derived from the target speed for the rest. `hasEstimatedDistance` says
    /// whether any of it is a projection — a distance goal's kilometres are the
    /// contract, a time goal's are an expectation.
    var totalDistanceKm: Double {
        segments.reduce(0) { $0 + $1.plannedDistanceKm }
    }

    /// The program's expected total elevation gain (positive-incline segments only).
    var totalElevationGainM: Double {
        segments.reduce(0) {
            $0 + ElevationMath.gainPerSecond(speedKmh: $1.nominalSpeedKmh,
                                             inclinePercent: $1.nominalIncline) * $1.plannedDuration
        }
    }

    /// Time-weighted average speed.
    var averageSpeedKmh: Double {
        totalDuration > 0 ? totalDistanceKm / (totalDuration / 3600) : 0
    }

    /// True when the total time is only a projection (any distance or
    /// heart-rate goal) — the UI prefixes such a total with `~`.
    var hasEstimatedDuration: Bool {
        segments.contains { $0.isDurationEstimated }
    }

    /// True when the total distance is only a projection. A time-only program
    /// falls in here too: its distance was always derived from target speeds.
    /// A recovery segment's distance is the case that is genuinely unknown in
    /// advance — its cap is an upper bound, not a plan.
    var hasEstimatedDistance: Bool {
        segments.contains { $0.isDistanceEstimated }
    }

    /// True when any segment asks the app to steer the belt. The opt-in gate and
    /// the one-time confirmation are per program, not per segment: a user who
    /// declines must not be asked again three segments later.
    var usesHeartRateControl: Bool {
        segments.contains(where: \.isHeartRateDriven)
    }

    /// Built-in demo programs for the first tests — deliberately cautious speeds.
    static let builtIn: [WorkoutProgram] = [
        WorkoutProgram(name: String(localized: "Gentle test (6 min)"), segments: [
            WorkoutSegment(name: String(localized: "Walk"), duration: 120, targetSpeedKmh: 3.0, targetIncline: 0),
            WorkoutSegment(name: String(localized: "Brisk walk"), duration: 120, targetSpeedKmh: 5.0, targetIncline: 1),
            WorkoutSegment(name: String(localized: "Cool-down"), duration: 120, targetSpeedKmh: 3.0, targetIncline: 0),
        ], isBuiltIn: true),
        WorkoutProgram(name: String(localized: "Intervals 5×(1+1) min"), segments: [
            WorkoutSegment(name: String(localized: "Warm-up"), duration: 180, targetSpeedKmh: 5.0, targetIncline: 0)
        ]
        + (1...5).flatMap { round in [
            WorkoutSegment(name: String(localized: "Fast \(round)"), duration: 60, targetSpeedKmh: 9.0, targetIncline: 0),
            WorkoutSegment(name: String(localized: "Recovery \(round)"), duration: 60, targetSpeedKmh: 6.0, targetIncline: 0),
        ]}
        + [WorkoutSegment(name: String(localized: "Cool-down"), duration: 180, targetSpeedKmh: 4.5, targetIncline: 0)],
        isBuiltIn: true),
    ]
}
