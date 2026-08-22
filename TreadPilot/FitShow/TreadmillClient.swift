// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import CoreBluetooth
import Foundation

/// The treadmill's momentary state, intended for the UI.
struct TreadmillState: Equatable {
    var status: FitShow.Status = .idle
    var countdownSeconds: Int = 0
    var speedKmh: Double = 0
    var inclinePercent: Int = 0
    var elapsedSeconds: Int = 0
    var distanceKm: Double = 0
    var kcal: Int = 0
    var steps: Int = 0
    var heartRate: Int = 0

    var isRunning: Bool { status == .running }
}

enum ConnectionPhase: Equatable {
    case idle
    case scanning
    case connecting(name: String)
    case preparing(name: String)
    case ready(name: String)
    case bluetoothOff
}

struct DiscoveredTreadmill: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
}

/// A stop the app has asked for and not yet seen obeyed.
struct OutstandingStop: Equatable, Sendable {
    /// Measured seconds since the first stop command went out. The insistence's
    /// own clock: how long the app has been asking, whatever the belt is doing.
    var secondsSinceRequest: Double = 0
    /// Measured seconds since the last one did.
    var secondsSinceAttempt: Double = 0
    var attempts = 1
    /// The measured speed the stop was asked for at, which is what the failure
    /// window is sized against: a belt sheds about
    /// `FitShowTreadmillClient.beltDecelerationKmhPerSecond`, so a stop from
    /// 10 km/h legitimately takes the better part of twenty seconds.
    var speedAtRequestKmh: Double = 0
    /// The last speed observed, so a belt that is still slowing can be told from
    /// one that has stopped slowing.
    var lastSpeedKmh: Double = 0
    /// **The failure clock**, and deliberately not `secondsSinceRequest`: a
    /// monotonically falling measured speed is a belt obeying, so this does not
    /// run while the belt is slowing or already standing (spec section 4, "The
    /// belt did not stop must mean it"; finding 95). The app requests a stop at
    /// the end of every ordinary program, and a red banner after every workout is
    /// a banner nobody reads when it matters.
    var secondsNotSlowing: Double = 0
    /// Was the belt observed slowing (or already standing), latched monotonically
    /// rather than from whichever single reading the last tick happened to see
    /// (finding 140 — the poll outruns the console's own report rate, so most
    /// ticks re-observe an unchanged reading, and comparing only to the
    /// immediately preceding one misread that as "not obeying" on an honest
    /// wind-down). `insisting(_:bySeconds:isObservedStopped:measuredSpeedKmh:)`
    /// latches it so the abandon path can ask it from the stop's own evidence
    /// alone — a disconnect wipes the client's live state to zero before the
    /// failure is ever judged there (finding 129), and reading that zero as "the
    /// belt stopped" would forgive exactly the ceiling-stop-then-dropped-link
    /// case the insistence exists for. Judging by plain "last speed nonzero"
    /// instead cried wolf on every ordinary wind-down (finding 130): a belt
    /// shedding half a km/h a second is still nonzero for the better part of
    /// twenty seconds, and every program requests a stop at the end. Defaults to
    /// false: an outstanding stop nobody has watched even once has earned no
    /// credit yet.
    var wasObservedSlowing = false
    /// Measured seconds since the belt was last *seen* coming down: a reading
    /// lower than the one on file, or a reading of zero. Reset by that evidence
    /// and by nothing else — a repeated reading, a stale frame and a link outage
    /// all count against it, exactly as they count for the failure clock.
    ///
    /// This is the recency `isObeying` needs, and the reason it cannot be read off
    /// either clock that already exists. `secondsNotSlowing` is *cumulative*
    /// flatness: the poll runs five times a second while the console reports a new
    /// speed far less often (finding 140), so four ticks in five re-observe the
    /// reading already on file even in the middle of an honest wind-down, and that
    /// clock therefore grows through most of every legitimate wind-down — correct
    /// for a failure window sized in tens of seconds, useless as a gate measured
    /// in twos. The per-tick comparison is the opposite failure: it is false on
    /// those same four ticks in five, so gating on it would push an obeying belt
    /// on nearly every re-issue that came due. What separates the two cases is
    /// *how long ago* the last genuine decrease was, which is what this counts.
    var secondsSinceSlowing: Double = 0

    /// Has the belt failed to obey? Both halves of the ruling: the clock that
    /// pauses while the belt slows, against a window sized by the speed the stop
    /// was asked for at.
    var isFailure: Bool {
        secondsNotSlowing >= FitShowTreadmillClient.stopFailureSeconds(
            fromSpeedKmh: speedAtRequestKmh)
    }

    /// **Is the belt credited with obeying right now?** — the gate on the
    /// re-issue, and the whole of finding 199. A belt seen coming down within the
    /// last `FitShowTreadmillClient.stopObeyingCreditSeconds` is a belt obeying,
    /// and *an obeying belt must not be pushed*: the same evidence that pauses the
    /// failure clock above now also withholds the next stop command and the stop
    /// aid that rides with it.
    ///
    /// The hardware test (2026-08-22, a real Tunturi T40) is what this is for. At
    /// the end of an ordinary program — cool-down at 6.2 km/h — the belt braked to
    /// a standstill almost at once, because the insistence re-issued every
    /// `stopReissueSeconds` regardless of what the belt was doing, and every
    /// re-issue also writes a target one km/h below what is already happening. The
    /// console honours target changes, so instead of its own gentle wind-down it
    /// was stepped down a km/h every two seconds. The aid exists for the console
    /// class of finding 141 — one that honours a target change while ignoring the
    /// stop — and that class never shows as slowing in the first place, so it
    /// loses nothing to this gate.
    ///
    /// `wasObservedSlowing` is the precondition rather than a `secondsSinceSlowing`
    /// of zero, because a stop nobody has watched even once has earned no credit:
    /// that clock reads zero at birth, and a belt whose stop frame was dropped
    /// outright has to insist at the first window, which is exactly what it does.
    var isObeying: Bool {
        wasObservedSlowing
            && secondsSinceSlowing < FitShowTreadmillClient.stopObeyingCreditSeconds
    }
}

enum StopInsistence: Equatable, Sendable {
    /// The belt is observed idle or ended: the stop was obeyed.
    case obeyed
    /// Send it again, and take the load off as belt-and-braces.
    case insist
    /// Between two attempts.
    case wait
    /// Long past the point where asking again could help.
    case abandoned
}

/// A pause the app has asked for and not yet seen the belt honour.
///
/// Deliberately not a second `OutstandingStop`: a pause carries no failure to
/// surface and no re-issue of its own — the queue's three attempts are the only
/// retry — because a belt that ignores a pause simply keeps running, which the
/// user is standing on and can see. What it does carry is the *fact of the ask*,
/// because two other rules have to read it (finding 205):
/// - `ProgramRunner` suspends the program on the tick the ask is made, and must
///   not auto-resume — "the belt is moving, so the user resumed at the console" —
///   while the moving belt is this pause's own wind-down.
/// - The console-dial inference must not read that wind-down as a person turning
///   a dial: the belt is doing what the app itself asked.
/// The T40 reports a pause as `running` at a *falling* speed for many seconds
/// before the standstill (finding 181), which is exactly the window in which a
/// governed segment's next evaluation used to write a target — and a console
/// that honours target changes takes the write as the pause being called off.
struct OutstandingPause: Equatable, Sendable {
    /// Measured seconds since the pause command went out.
    var secondsSinceRequest: Double = 0
    /// The measured speed at the ask, which is what the give-up window is sized
    /// against: the wind-down the belt owes is proportional to it.
    var speedAtRequestKmh: Double = 0
}

/// What one poll decided about an outstanding pause.
enum PauseResolution: Equatable, Sendable {
    /// The belt was observed standing — or paused, idle, ended: the pause is done.
    case honoured
    /// Still inside the wind-down the belt was given.
    case waiting
    /// The belt never came down inside that window: the ask is dropped, so the
    /// runner's automatic resume works again and a lost pause frame cannot hold
    /// a program suspended forever.
    case gaveUp
}

/// One axis of the console-dial inference — **fact 3** of the spec's "Three
/// facts, kept apart", which this protocol does not carry and which therefore
/// has to be inferred from fact 2, the measured value, and never from a target
/// field.
///
/// Integer protocol units throughout — tenths of a km/h for speed, levels for
/// incline. One 0.1 km/h quantum is 0.09999999999999964 as a `Double`, so a
/// `>= 0.1` comparison is false for 114 of the 193 speeds this device can be set
/// to (finding 76).
///
/// **A hand-back needs a decisive intervention, not a detectable one** (spec
/// section 4). This protocol reports the belt's measured speed and never the
/// console's setpoint, so "did a person turn the dial" is an inference from a
/// noisy scalar, and three review rounds found a new confusion in it each time: a
/// console a tenth off its own setpoint, a heavy runner's footfall loading the
/// belt, a write the queue abandoned, an actuator still travelling, a governor
/// step landing on the value the user had just dialled to. Every one of those
/// lives inside one or two protocol quanta, so this type stops trying to classify
/// them. One test, three clauses, one threshold per axis — half a km/h, or two
/// incline levels:
///
/// 1. **Decisively away from the app's command**, by `decisiveUnits`.
/// 2. **Against the direction the app asked for.** A belt held short of an
///    increase it was given, or over a reduction it was given, is the person's; a
///    belt that went further the way the app itself chose is not.
/// 3. **The belt has actually been somewhere.** Either it reached the command and
///    then left it, or it has moved `decisiveUnits` from the value it was last
///    observed *holding*. A command the belt never obeyed — a write the queue
///    abandoned after three attempts, an actuator that never set off — leaves the
///    measurement where it was, and a belt going on doing exactly what it was
///    already doing says nothing about a person (finding 91). Measured with the
///    same threshold, so a tenth of measurement noise cannot supply the movement
///    half of the evidence either (finding 128).
///
/// All of it only past the travel allowance the app computes from the distance the
/// actuator had to cover and its own rate.
///
/// **The verdict is latched the instant the three clauses are met, not once the
/// belt has finished arriving at the person's value** (finding 134). On a command
/// the belt had reached there is no journey left for the measurement to be part
/// of, and the two seconds of settling this used to wait for were two seconds in
/// which an evaluation could land mid-travel, write a step from the mid-travel
/// measurement and turn the belt around before it ever got to the value the person
/// had dialled. The one case that still waits for a plateau is a command the belt
/// never reached, where a value in motion may be the machine's own late journey
/// rather than a hand — see `observe(measured:deltaSeconds:)`.
///
/// **Nothing smaller is classified at all, and nothing needs to be.** The
/// governor commands one step from `min(fact 1, fact 2)` and never from a stored
/// setpoint, so a small manual change is respected without anything having to
/// detect it: dial the belt down a tenth and the loop's next move is a step from
/// *your* value. What a false hand-back costs is a segment that silently loses
/// governing *and* the feed-loss protection, so an over-sensitive criterion is not
/// the safe direction — and an inference that cannot be made reliable should not
/// be load-bearing.
///
/// **The residue, stated.** A machine that moved and then stopped half a km/h
/// short of a command it was given — a motor at the top of its own travel, a
/// console that silently stops tracking a target — reads as a person. It errs that
/// way deliberately: the cost is a segment that runs fixed while both ceilings and
/// the feed-loss fallback stay live, against a belt that walks itself back up
/// under somebody's hand. In production every command is clamped to the device's
/// own limits, so this needs limits the device never reported.
///
/// **A write does not erase evidence it has not reported.** A verdict already
/// reached, and a departure still being judged, both survive the next command
/// (finding 92): evaluations are ten seconds apart
/// while frames arrive five times a second, and the write in question is one step
/// from the person's own value, so the new command lands right next to the belt and
/// nothing would be decisive any more. Only the travel bookkeeping is reset by a
/// write, and only when the command actually changed (finding 125): a rung
/// restating one value on the ten-second grid, with a travel allowance longer than
/// ten seconds, kept "travelling" true for ever and starved the only clause that
/// could catch a person on that axis.
///
/// **There is no mid-segment release.** The verdict is retired by a new segment
/// (`segmentBegan`) or an explicit start (`started`) — both a person's own action —
/// and by nothing else. A release granted because the belt was observed at the
/// app's command used to drop a departure that was still being judged, which is
/// the loop's own step landing on the value the user had just dialled to, after
/// which the loop adopted the person's number as its baseline (finding 126). The
/// spec's rule is the whole segment: a manual change hands control back for the
/// rest of it.
struct ConsoleDialAxis: Equatable, Sendable {
    /// A measured value this long unchanged is a value the actuator has stopped
    /// moving — a plateau. Ten frames at the 200 ms poll.
    static let settledSeconds: Double = 2
    /// Slack on top of the computed travel time, for a console that answers a
    /// beat late.
    static let travelSlackSeconds: Double = 3

    /// How fast this actuator travels, in units per second.
    let unitsPerSecond: Double
    /// What counts as taking over on this axis: half a km/h, or two incline
    /// levels. Everything smaller is left unclassified on purpose.
    let decisiveUnits: Int

    /// The belt reaches a new speed at about 0.5 km/h per second — five tenths.
    static var forSpeed: ConsoleDialAxis {
        ConsoleDialAxis(unitsPerSecond: 5, decisiveUnits: 5)
    }
    /// The incline motor takes about five seconds per level.
    static var forIncline: ConsoleDialAxis {
        ConsoleDialAxis(unitsPerSecond: 0.2, decisiveUnits: 2)
    }

    /// The verdict, latched: nothing the app can observe is evidence that a hand
    /// came off a dial, so only a boundary or a start retires it.
    private(set) var isSetByHand = false

    /// nil until the app has commanded this axis at all, so a first command of
    /// zero — a legitimate incline — is still a command.
    private var commandUnits: Int?
    private var gapAtCommandUnits = 0
    /// What was measured when this command went out. Clause 2's baseline — the
    /// direction the app asked for — and clause 3's until the belt has held a
    /// value of its own.
    private var measuredAtCommandUnits = 0
    private var secondsSinceCommand: Double = 0
    /// Has the belt reached, or gone past, the standing command? One bit, and
    /// exact — the arrival *tolerance* that used to sit here was one of the
    /// confusions this design stopped classifying. Its only job is to excuse
    /// clause 3: a belt that obeyed and then left has nothing more to prove.
    private var didReachCommand = false

    /// The observation history, which is about the belt and not about the command,
    /// so no write touches any of it (finding 92).
    ///
    /// `plateauUnits` is the last value the belt was observed *holding* — clause
    /// 3's baseline, so a departure is measured from where the belt actually was
    /// and not from a snapshot taken when the command went out. A value held
    /// mid-journey is not the belt's own: the plateau is only taken once the travel
    /// allowance has run out, or a ramp pausing at each level on its way would
    /// become the baseline the next clause is measured against.
    private var plateauUnits: Int?
    private var lastMeasuredUnits: Int?
    private var settledFor: Double = 0
    /// A departure already seen on a command the belt never reached, latched at the
    /// instant it is seen so a write cannot erase evidence it has not reported
    /// (finding 92). Only that case waits for a plateau at all — see `observe`.
    private var departureUnits: Int?

    /// The time by which the actuator must have reached the command.
    var travelAllowanceSeconds: Double {
        Double(gapAtCommandUnits) / unitsPerSecond + Self.travelSlackSeconds
    }

    /// Is the actuator still on its way? Nothing is inferred about a person while
    /// it is: a ramp and a hand are the same picture until the journey is over.
    var isTravelling: Bool {
        !didReachCommand && secondsSinceCommand <= travelAllowanceSeconds
    }

    /// The app's control loop has commanded this axis.
    mutating func commanded(units: Int, measured: Int) {
        record(command: units, measured: measured)
    }

    /// A person moved this axis, in the app. The write itself is the evidence —
    /// there is nothing to wait for and no threshold to clear (spec section 4, "A
    /// manual change is a manual change wherever it is made"; finding 90).
    mutating func setByHand(units: Int, measured: Int) {
        record(command: units, measured: measured)
        isSetByHand = true
        departureUnits = nil
    }

    /// An explicit start: a user action carrying its own confirmation, and the one
    /// thing that wipes the slate. Nothing is remembered about a belt that was not
    /// running.
    mutating func started(units: Int, measured: Int) {
        self = ConsoleDialAxis(unitsPerSecond: unitsPerSecond, decisiveUnits: decisiveUnits)
        commanded(units: units, measured: measured)
    }

    /// A new segment has begun. The verdict goes — spec section 4, "Governing
    /// resumes at the next segment" (finding 114) — while the travel bookkeeping
    /// stays, because it is about the belt and the belt did not change when the
    /// program moved on.
    mutating func segmentBegan() {
        isSetByHand = false
        departureUnits = nil
    }

    /// The travel bookkeeping, and only when the command actually changed
    /// (finding 125). Re-asking for the command already standing is the same
    /// question: it neither restarts the journey nor moves the baseline the
    /// journey is measured from.
    private mutating func record(command units: Int, measured: Int) {
        guard units != commandUnits else { return }
        commandUnits = units
        gapAtCommandUnits = abs(measured - units)
        measuredAtCommandUnits = measured
        secondsSinceCommand = 0
        didReachCommand = measured == units
    }

    mutating func observe(measured: Int, deltaSeconds: Double) {
        // A radio gap is not evidence: nothing was measured during it, so a value
        // that looks unchanged across it has not been observed to stand still.
        guard deltaSeconds.isFinite, deltaSeconds > 0,
              deltaSeconds <= FitShowTreadmillClient.freshnessHorizonSeconds else {
            settledFor = 0
            lastMeasuredUnits = measured
            departureUnits = nil
            return
        }
        secondsSinceCommand += deltaSeconds
        settledFor = measured == lastMeasuredUnits ? settledFor + deltaSeconds : 0
        lastMeasuredUnits = measured
        noteArrival(measured)
        if isDecisive(measured) {
            // **Latched the instant the departure is decisive** on a belt that had
            // reached the command it is leaving: the app has nothing outstanding
            // there, so the movement in hand is the person's and not a journey of the
            // machine's. Waiting for the plateau cost a whole intervention (finding
            // 134) — four seconds of travel plus two of settling, inside a
            // ten-second evaluation grid, so an evaluation landed mid-travel and
            // wrote a step that turned the belt around before it ever arrived.
            //
            // A command the belt never reached still waits for its plateau: there a
            // value in motion may be the machine's own late journey, and classifying
            // it early would disable governing for a whole segment on an honest belt.
            if didReachCommand {
                isSetByHand = true
            } else {
                departureUnits = measured
            }
        }
        guard settledFor >= Self.settledSeconds else { return }
        if departureUnits == measured { isSetByHand = true }
        // The value has stood long enough to be the belt's own: the next departure
        // is measured from here, and the departure in hand has been answered.
        if !isTravelling { plateauUnits = measured }
        departureUnits = nil
    }

    /// Has the measurement reached the command, or crossed it, coming from
    /// wherever it stood when the command went out?
    private mutating func noteArrival(_ measured: Int) {
        guard let command = commandUnits else { return }
        if (measuredAtCommandUnits <= command && measured >= command)
            || (measuredAtCommandUnits >= command && measured <= command) {
            didReachCommand = true
        }
    }

    /// The one test: decisively away from the command, against the direction the
    /// app asked for, on a belt that has been somewhere, past the travel
    /// allowance. See the type's own note for why there is nothing else.
    private func isDecisive(_ measured: Int) -> Bool {
        guard let command = commandUnits, !isTravelling else { return false }
        let away = measured - command
        guard abs(away) >= decisiveUnits else { return false }
        // A restatement asked for no direction at all, so any decisive departure
        // from it is a person's.
        let asked = command - measuredAtCommandUnits
        guard asked == 0 || (away > 0) != (asked > 0) else { return false }
        return didReachCommand
            || abs(measured - (plateauUnits ?? measuredAtCommandUnits)) >= decisiveUnits
    }
}

/// Fact 3 for both axes. Per axis on purpose: a segment steers one of them, and
/// the *other* one is where a console change used to be invisible.
struct ConsoleDialDetector: Equatable, Sendable {
    var speed = ConsoleDialAxis.forSpeed
    var incline = ConsoleDialAxis.forIncline

    var isSetByHand: Bool { speed.isSetByHand || incline.isSetByHand }

    mutating func commanded(speedUnits: Int, incline inclineLevel: Int,
                            measuredSpeedUnits: Int, measuredIncline: Int) {
        speed.commanded(units: speedUnits, measured: measuredSpeedUnits)
        incline.commanded(units: inclineLevel, measured: measuredIncline)
    }

    /// A person moved one axis in the app. Only that axis latches: the ± tiles
    /// move one at a time, and the other axis is being restated rather than
    /// chosen — exactly as a console press on one dial says nothing about the
    /// other (spec section 4, "A manual change is a manual change wherever it is
    /// made").
    mutating func setByHand(_ axis: HeartRateActuator, speedUnits: Int,
                            incline inclineLevel: Int,
                            measuredSpeedUnits: Int, measuredIncline: Int) {
        switch axis {
        case .speed:
            speed.setByHand(units: speedUnits, measured: measuredSpeedUnits)
            incline.commanded(units: inclineLevel, measured: measuredIncline)
        case .incline:
            speed.commanded(units: speedUnits, measured: measuredSpeedUnits)
            incline.setByHand(units: inclineLevel, measured: measuredIncline)
        }
    }

    /// An explicit start clears both axes: see `ConsoleDialAxis.started`.
    mutating func started(speedUnits: Int, incline inclineLevel: Int,
                          measuredSpeedUnits: Int, measuredIncline: Int) {
        speed.started(units: speedUnits, measured: measuredSpeedUnits)
        incline.started(units: inclineLevel, measured: measuredIncline)
    }

    /// A new segment has begun, on both axes: see `ConsoleDialAxis.segmentBegan`.
    mutating func segmentBegan() {
        speed.segmentBegan()
        incline.segmentBegan()
    }

    mutating func observe(measuredSpeedUnits: Int, measuredIncline: Int, deltaSeconds: Double) {
        speed.observe(measured: measuredSpeedUnits, deltaSeconds: deltaSeconds)
        incline.observe(measured: measuredIncline, deltaSeconds: deltaSeconds)
    }
}

/// BLE client for a FitShow-protocol treadmill.
///
/// How it works: after connecting it subscribes to the notify characteristic,
/// starts the 200 ms poll, and queries the speed/incline limits. Every command is
/// sent through a serial queue: re-sent every 200 ms, at most 3 attempts, and
/// acknowledged by the treadmill's command echo. The safety rule holds at the
/// client level too: only an explicit user action can start the belt.
@MainActor
final class FitShowTreadmillClient: NSObject, ObservableObject {

    @Published private(set) var phase: ConnectionPhase = .idle
    @Published private(set) var discovered: [DiscoveredTreadmill] = []
    @Published private(set) var state = TreadmillState()
    @Published private(set) var limits = TreadmillLimits()

    /// **Fact 2's neighbour, and not a record.** What the belt is set to as best
    /// the app can tell: the dashboard's ± tiles show it and step from it. It is
    /// the app's own command while that command is fresh and the belt's measured
    /// value afterwards — see `reconciled(commandUnits:measuredUnits:…)`, the one
    /// reconcile rule this client has.
    ///
    /// No control decision may read it as "what the app asked for". That is
    /// `commandedSpeedKmh` below, and keeping the two apart is the whole of the
    /// spec's "Three facts, kept apart" (section 4): three review rounds of
    /// blockers came out of one number meaning both.
    @Published private(set) var targetSpeedKmh: Double = 0.8
    @Published private(set) var targetIncline: Int = 0

    /// **Fact 1: what the app itself last commanded**, after the machine's own
    /// clamps and after the stale bound below. No incoming frame may move it —
    /// that is the entire point of it — and it is what `HeartRateGovernor`
    /// measures every decision from.
    @Published private(set) var commandedSpeedKmh: Double = 0.8
    @Published private(set) var commandedIncline: Int = 0

    @Published var lostConnectionWhileRunning = false
    @Published private(set) var staleData = false
    @Published private(set) var lastError: String?
    @Published private(set) var variant: FitShowVariant = .standard

    /// A stop the app asked for that the belt has not obeyed within
    /// `stopFailureSeconds`. The one visible failure in this feature: a safety
    /// rule that did not fire must not look like one that did, so the UI shows
    /// this with the instruction to stop the belt at the console.
    @Published private(set) var stopNotObeyed = false

    /// The other half of the same fact: a stop of the app's own is outstanding
    /// *now*, from the first attempt onward and before any failure is established.
    /// Published because the runner and the dashboard both have to see it — a
    /// program may not start on such a belt, a running program may not keep
    /// writing targets onto one, and the UI must not offer to accelerate it
    /// (finding 94).
    @Published private(set) var isStopOutstanding = false

    /// A pause the app asked for is outstanding *now* — from the ask until the
    /// belt is observed standing, or the give-up window closes over a belt that
    /// never came down. `ProgramRunner` reads it to suspend at once and to hold
    /// its automatic resume through the wind-down; see `OutstandingPause` for
    /// why the fact has to exist at all (finding 205).
    @Published private(set) var isPauseOutstanding = false

    /// The developer-toggled event log. **Observation only**: no branch in this
    /// class reads it, and with the toggle off every call below costs one Bool
    /// read — which is the requirement, because the 200 ms poll runs through
    /// `tick()`. It logs the writes `ProgramRunner` does not make (a person's ±
    /// tiles, a start, the stop aid) and the whole stop lifecycle, whose facts
    /// live here because this object's lifetime is the connection.
    private let diagnostics = DiagnosticLog.shared

    /// How old the data in hand may be while the belt runs before `staleData` is
    /// raised. Named, because `ProgramRunner.maxTickSeconds` is derived from it: the
    /// runner may not credit a tick with more running than one frame is evidence
    /// for, and a bare literal here would let the two drift apart silently.
    nonisolated static let freshnessHorizonSeconds: TimeInterval = 3

    /// How long the app's own command holds `targetSpeedKmh` / `targetIncline`
    /// against the belt's measured value. Two quick "+" taps therefore
    /// accumulate instead of each stepping from a belt that has not caught up.
    nonisolated static let targetHoldOffSeconds: TimeInterval = 10

    /// The handlebar heart rate a reading this old is still evidence for. The age
    /// is the *reading's* own, not the last frame's: only a run-data frame
    /// carries a heart rate, so a stream of command echoes would otherwise keep
    /// certifying a byte nothing has re-stated. The Watch feed has its own window
    /// in `WatchHeartRateManager.freshHeartRate`.
    nonisolated static func freshHeartRate(_ heartRate: Int, readingAge: TimeInterval) -> Int {
        readingAge <= freshnessHorizonSeconds ? heartRate : 0
    }

    // MARK: - The one reconcile rule

    /// What `targetSpeedKmh` / `targetIncline` hold, in protocol units.
    ///
    /// Inside `targetHoldOffSeconds` the app's own command stands; past it the
    /// belt's measured value is the better number and is adopted **with no dead
    /// band**. The two dead bands this function used to have are gone: the
    /// one-level incline band removed the incline axis's only evidence of a
    /// console change (finding 75), and the 0.1 km/h speed band was compared in
    /// binary floating point where one quantum is 0.09999999999999964, so a
    /// single console press was invisible for 114 of the 193 speeds this device
    /// offers (finding 76). Everything here is integer tenths for that reason.
    ///
    /// Telling a travelling actuator from a person is no longer this function's
    /// job at all — `ConsoleDialDetector` does it from the measured values, at
    /// frame cadence. This is the only reconcile rule in the app: production and
    /// every test fake call it, so a fake can no longer model a client that does
    /// not exist (finding 80).
    ///
    /// `ignoreZeroMeasurement` is the speed axis's own asymmetry: 0 km/h is a
    /// belt that has stopped, while 0% is a legitimate incline.
    nonisolated static func reconciled(commandUnits: Int, measuredUnits: Int,
                                       secondsSinceCommand: TimeInterval,
                                       ignoreZeroMeasurement: Bool) -> Int {
        guard secondsSinceCommand > targetHoldOffSeconds else { return commandUnits }
        if ignoreZeroMeasurement, measuredUnits <= 0 { return commandUnits }
        return measuredUnits
    }

    // MARK: - The stop this client insists on

    /// How long between two stop commands. The queue has already tried three
    /// times over 600 ms by then, so this is a second line and not a louder
    /// version of the first.
    nonisolated static let stopReissueSeconds: Double = 2
    /// The floor under the failure window: a belt that was standing still when the
    /// stop went out has no wind-down to be given time for.
    nonisolated static let stopFailureSeconds: Double = 5
    /// What a belt sheds per second whatever it is told — the same 0.5 km/h/s the
    /// dial inference computes its speed travel allowance from.
    nonisolated static let beltDecelerationKmhPerSecond: Double =
        ConsoleDialAxis.forSpeed.unitsPerSecond / HeartRateGovernor.speedUnitsPerKmh

    /// How long a belt winding down from `speedKmh` is given before its failure to
    /// stop counts as a failure. Sized against a real wind-down from the speed the
    /// stop was asked for at, plus the same slack a standing belt gets: 10 km/h is
    /// 20 s of deceleration, and the five-second warning fired on every ordinary
    /// program end (finding 95).
    nonisolated static func stopFailureSeconds(fromSpeedKmh speedKmh: Double) -> Double {
        guard speedKmh.isFinite, speedKmh > 0 else { return stopFailureSeconds }
        return speedKmh / beltDecelerationKmhPerSecond + stopFailureSeconds
    }

    /// A stop nobody has answered for this long will not be answered. The
    /// insistence ends here — `stopNotObeyed` does not — because an outstanding
    /// stop that never expired would also kill a start the user makes at the
    /// console minutes later. It is never shorter than the failure window plus a
    /// few more attempts, so the insistence cannot give up before the belt has
    /// even been given its wind-down.
    nonisolated static let stopGiveUpSeconds: Double = 30

    /// Finding 141: a console that honours a target *change* while ignoring the
    /// stop itself is walked down by the stop aid one km/h at a time and
    /// plateaus at the machine's minimum instead of ever reaching zero — a real,
    /// ongoing refusal, not a wind-down. The old formula (one failure window
    /// plus a few reissues) sized the give-up clock as if the failure clock
    /// started at the first attempt; in fact `secondsNotSlowing` cannot start
    /// accumulating until the belt stops actually falling, and descending from
    /// `speedKmh` to that plateau can itself take up to `speedKmh /
    /// beltDecelerationKmhPerSecond` of the give-up budget. Doubling the failure
    /// window covers that descent with room to spare — for every speed the
    /// device offers, `stopGiveUpSeconds > descentTime + stopFailureSeconds`, so
    /// the belt is provably declared a failure before the insistence ever gives
    /// up on it, and giving up silently (finding 141's own description of the
    /// bug) can no longer happen. A belt that genuinely reaches true zero is
    /// unaffected: `secondsNotSlowing` never accumulates for it in the first
    /// place (`OutstandingStop.isFailure`; finding 113), whatever this window is
    /// sized to.
    nonisolated static func stopGiveUpSeconds(fromSpeedKmh speedKmh: Double) -> Double {
        max(stopGiveUpSeconds,
            2 * stopFailureSeconds(fromSpeedKmh: speedKmh) + stopReissueSeconds * 3)
    }

    /// How long one genuine observation of the belt coming down credits it with
    /// obeying (`OutstandingStop.isObeying`). One re-issue window, and that is a
    /// choice with two sides to satisfy.
    ///
    /// It has to be long enough to survive the poll re-observing an unchanged
    /// reading — 5 Hz of polling against a console that publishes a new speed
    /// perhaps once a second (finding 140), so a flat repeat must not instantly
    /// discredit an honest wind-down. And it has to be short enough to hand the
    /// insistence back promptly once a belt stops falling for real, which is the
    /// finding-141 plateau. One window does both: a wind-down produces a new lower
    /// reading well inside it, and a belt that flattens loses the credit — on the
    /// very tick it lapses, because the attempt clock is not reset while the app
    /// waits, so the next stop command goes out immediately rather than at the
    /// following window.
    nonisolated static let stopObeyingCreditSeconds: Double = stopReissueSeconds

    /// How much speed each re-issue takes off, as belt-and-braces for a dropped
    /// stop frame.
    nonisolated static let stopSpeedStepKmh: Double = 1.0

    /// One poll of an outstanding stop, as a pure function so that "it keeps
    /// asking until the belt stops, and only while the belt is not already doing
    /// it" is a property of something tested rather than of a statement order.
    ///
    /// A tick is credited with at most one freshness horizon, for the same reason
    /// the runner's tallies are: a wedged timer must not fast-forward the give-up
    /// clock.
    nonisolated static func insisting(_ stop: OutstandingStop, bySeconds deltaSeconds: Double,
                                      isObservedStopped: Bool,
                                      measuredSpeedKmh: Double?)
        -> (OutstandingStop, StopInsistence) {
        guard !isObservedStopped else { return (stop, .obeyed) }
        guard deltaSeconds.isFinite, deltaSeconds > 0 else { return (stop, .wait) }
        var next = stop
        let delta = min(deltaSeconds, freshnessHorizonSeconds)
        next.secondsSinceRequest += delta
        next.secondsSinceAttempt += delta
        // A belt that is slowing, or already standing, is a belt obeying: the
        // failure clock does not run. Tenths, like every other comparison of two
        // speeds here — one quantum is 0.09999999999999964 as a `Double`. Nothing
        // observed is not a belt observed obeying, so a stale frame runs the clock:
        // `nil` and a remembered zero are two very different things.
        var isSlowingNow = false
        if let observed = measuredSpeedKmh, observed.isFinite {
            let units = HeartRateGovernor.speedUnits(observed)
            let lastUnits = HeartRateGovernor.speedUnits(next.lastSpeedKmh)
            isSlowingNow = units <= 0 || units < lastUnits
            // Finding 140: `wasObservedSlowing` used to be overwritten from this
            // one comparison every tick, but the poll runs five times a second
            // while the console reports a new speed far less often — so most
            // ticks re-observe the very reading already on file, which reads
            // here as "not decreasing" even on a belt in the middle of an
            // honest wind-down. A disconnect landing on one of those repeat
            // ticks then raised a false belt-did-not-stop that blocked every
            // later program start. Latched monotonically instead: once
            // genuinely seen obeying, the belt stays credited with it until an
            // actual increase says otherwise. A repeated reading is not new
            // evidence of anything, so it moves neither the credit nor the
            // discredit — `secondsNotSlowing` below is unaffected and still
            // judges the belt from the duration it spends flat, never from
            // this latch.
            if isSlowingNow {
                next.wasObservedSlowing = true
            } else if units > lastUnits {
                next.wasObservedSlowing = false
            }
            next.lastSpeedKmh = observed
        }
        // The failure clock and the credit's own recency clock, from the same one
        // judgement: this tick either brought new evidence of the belt coming down
        // or it did not. `secondsNotSlowing` is unchanged in every respect — it
        // still runs on exactly the ticks it used to and is still what
        // `isFailure` and the give-up sizing of finding 141 are reasoned against.
        if isSlowingNow {
            next.secondsSinceSlowing = 0
        } else {
            next.secondsNotSlowing += delta
            next.secondsSinceSlowing += delta
        }
        guard next.secondsSinceRequest
            < stopGiveUpSeconds(fromSpeedKmh: next.speedAtRequestKmh) else {
            return (next, .abandoned)
        }
        guard next.secondsSinceAttempt >= stopReissueSeconds else { return (next, .wait) }
        // Finding 199: it is time to ask again, but an obeying belt must not be
        // pushed. The re-issue — and the stop aid that rides with it in
        // `insistOnOutstandingStop` — is gated on the same evidence as the failure
        // clock above, so a belt that is coming down is left to come down, and the
        // insistence resumes the moment the credit lapses: the belt flattens above
        // zero, or speeds up and unlatches `wasObservedSlowing`. The attempt clock
        // is deliberately *not* reset here, which is what makes that resume
        // immediate rather than a window late.
        //
        // Neither reversal in this file's history is reopened. Finding 96 was the
        // aid leaking into the app's own three facts, and its fix — the aid going
        // straight onto the wire, touching no record — is untouched by firing it
        // strictly less often. Finding 141 sized the give-up clock so that a
        // console honouring targets while ignoring the stop is *declared a
        // failure* before the insistence gives up on it; that sizing only gains
        // slack here, because the gated walk-down spends a credit window flat at
        // every step — with the failure clock running — instead of being aided
        // down every two seconds, so the failure now lands earlier in the
        // walk-down rather than only at the plateau.
        guard !next.isObeying else { return (next, .wait) }
        next.secondsSinceAttempt = 0
        next.attempts += 1
        return (next, .insist)
    }

    /// Has the belt been *observed* stopped?
    ///
    /// Idle or ended, and deliberately not "no longer running": a console winding
    /// the belt down reports `paused`, and so does a console the user can resume
    /// from, so reading either as a confirmed stop is one of the three ways a stop
    /// got abandoned (finding 78). And it has to come from a frame that actually
    /// arrived — a state wiped by a disconnect reads as `idle`, and a remembered
    /// idle is not an observation.
    nonisolated static func isObservedStopped(status: FitShow.Status,
                                             frameAge: TimeInterval) -> Bool {
        guard frameAge <= freshnessHorizonSeconds else { return false }
        return status == .idle || status == .end
    }

    // MARK: - The pause this client remembers asking for

    /// The floor under the pause give-up window: a belt already crawling when
    /// the ask went out still gets a few seconds to be seen standing.
    nonisolated static let pauseGiveUpFloorSeconds: Double = 5

    /// How long a belt winding down from `speedKmh` is given to be observed
    /// standing before the outstanding pause is dropped. The wind-down the belt
    /// owes, plus the same floor a standing belt gets — the same shape as
    /// `stopFailureSeconds(fromSpeedKmh:)`, and for the same reason: "the belt
    /// did not pause" is only readable against the wind-down it was given.
    nonisolated static func pauseGiveUpSeconds(fromSpeedKmh speedKmh: Double) -> Double {
        guard speedKmh.isFinite, speedKmh > 0 else { return pauseGiveUpFloorSeconds }
        return speedKmh / beltDecelerationKmhPerSecond + pauseGiveUpFloorSeconds
    }

    /// Has the belt been observed standing, for the pause's purposes? Wider than
    /// `isObservedStopped(status:frameAge:)` on purpose: the T40 reports a
    /// paused belt as `running` at 0 km/h (finding 181), so a measured zero is
    /// evidence here, and `paused` is the honoured outcome rather than the
    /// unconfirmed one it is for a stop. It still has to come from a frame that
    /// actually arrived — a state wiped by a disconnect reads as zero, and a
    /// remembered zero is not an observation.
    nonisolated static func isObservedStanding(status: FitShow.Status, speedKmh: Double,
                                               frameAge: TimeInterval) -> Bool {
        guard frameAge <= freshnessHorizonSeconds else { return false }
        if status == .idle || status == .end || status == .paused { return true }
        return HeartRateGovernor.speedUnits(speedKmh) <= 0
    }

    /// One poll of an outstanding pause, as a pure function for the same reason
    /// `insisting(_:bySeconds:isObservedStopped:measuredSpeedKmh:)` is one. A
    /// tick is credited with at most one freshness horizon, so a wedged timer
    /// cannot fast-forward the give-up.
    nonisolated static func resolvingPause(_ pause: OutstandingPause,
                                           bySeconds deltaSeconds: Double,
                                           isObservedStanding: Bool)
        -> (OutstandingPause, PauseResolution) {
        guard !isObservedStanding else { return (pause, .honoured) }
        guard deltaSeconds.isFinite, deltaSeconds > 0 else { return (pause, .waiting) }
        var next = pause
        next.secondsSinceRequest += min(deltaSeconds, freshnessHorizonSeconds)
        guard next.secondsSinceRequest
            < pauseGiveUpSeconds(fromSpeedKmh: next.speedAtRequestKmh) else {
            return (next, .gaveUp)
        }
        return (next, .waiting)
    }

    /// What a write may ask for while the treadmill link is stale.
    ///
    /// No frame has arrived for longer than the freshness horizon, so the app's
    /// own record is not evidence about the belt any more: the user may have
    /// dialled the console down unseen, and nothing can say otherwise while
    /// frames are absent. A step computed from the app's record would then reach
    /// the console as a large *acceleration* — the app's last write was 8.0, the
    /// user settled at 5.0, and the 92% ceiling "reduces" to 7.8 (finding 79).
    /// Writes still succeed in that state, because losing notifications is not
    /// losing the write characteristic, so the bound has to be here.
    ///
    /// The most conservative number available is the last measured value, and it
    /// bounds both axes. `requestStop` does not come through here: a stop can
    /// only ever reduce load, so it is exempt unconditionally.
    nonisolated static func bounded(speedKmh: Double, incline: Int, isLinkStale: Bool,
                                    measuredSpeedKmh: Double, measuredIncline: Int)
        -> (speedKmh: Double, incline: Int) {
        guard isLinkStale else { return (speedKmh, incline) }
        return (min(speedKmh, measuredSpeedKmh), min(incline, measuredIncline))
    }

    /// What a write may ask for while a stop of the app's own is outstanding:
    /// **nothing above what is already happening.**
    ///
    /// The dashboard's stop button only asks the client to stop; it does not end
    /// the program. So if the belt does not obey, the runner keeps ticking, the
    /// heart rate falls as the belt winds down, and a below-band reading produces
    /// an acceleration — the belt speeds up after the user pressed STOP
    /// (finding 94). Every write is therefore clamped to the lower of the app's
    /// own last command and the last measured value, which lets a reduction
    /// through and refuses an increase. The insistence's own belt-and-braces
    /// reduction does not come through here at all (see `sendStopAidReduction`),
    /// and neither does `startBelt`, which is the explicit user action that
    /// cancels the stop before writing anything.
    nonisolated static func boundedByStop(speedKmh: Double, incline: Int,
                                          isStopOutstanding: Bool,
                                          appSpeedKmh: Double, appIncline: Int,
                                          measuredSpeedKmh: Double, measuredIncline: Int)
        -> (speedKmh: Double, incline: Int) {
        guard isStopOutstanding else { return (speedKmh, incline) }
        // A measured 0 is a belt that has stopped, not a target: bounding by it
        // would be bounding by nothing the machine can be set to. The app's own
        // command is the bound in that case, and it is coming down anyway.
        let measuredBound = measuredSpeedKmh > 0 ? measuredSpeedKmh : appSpeedKmh
        return (min(speedKmh, min(appSpeedKmh, measuredBound)),
                min(incline, min(appIncline, measuredIncline)))
    }

    /// Facts 2 and 3 for `HeartRateGovernor.Input.belt`: what the belt is
    /// measured to be doing, and whether a dial has been turned. The governor
    /// reads the belt through this and through nothing else — never through
    /// `targetSpeedKmh`, which is an observation the reconcile rule above may
    /// rewrite.
    var beltFacts: HeartRateGovernor.BeltFacts {
        HeartRateGovernor.BeltFacts(
            measured: HeartRateGovernor.Command(speedKmh: state.speedKmh,
                                                incline: state.inclinePercent),
            isSpeedSetByHand: dial.speed.isSetByHand,
            isInclineSetByHand: dial.incline.isSetByHand)
    }

    // The services observed in the 2019 Tunturi consoles' advertisements.
    private static let advertisedServices = [CBUUID(string: "E0FF"), CBUUID(string: "1826")]
    private static let preferredService = CBUUID(string: "FFE0")
    private static let serialServices = [CBUUID(string: "FFE0"), CBUUID(string: "FFF0")]
    private static let writeCharUUIDs = [CBUUID(string: "FFE1"), CBUUID(string: "FFF2")]
    private static let notifyCharUUIDs = [CBUUID(string: "FFE4"), CBUUID(string: "FFF1")]

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var peripheralsById: [UUID: CBPeripheral] = [:]
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var chosenServiceUUID: CBUUID?

    private var pollTimer: Timer?
    private var prepTimer: Timer?
    private var pending: [(payload: [UInt8], attempts: Int)] = []
    private var lastFrameAt: Date = .distantPast
    /// Stamped by the run-data frames alone — the only ones that carry a heart rate.
    private var lastHeartRateAt: Date = .distantPast
    /// Stamped by the running frames the dial detector is fed from, so its
    /// evidence is measured in observed seconds and a radio gap counts as none.
    private var lastRunningFrameAt: Date = .distantPast
    private var lastTargetCommandAt: Date = .distantPast
    private var targetsDirtyWhileNotRunning = false
    /// Fact 3: the inference that somebody turned a dial on the console. Private,
    /// because what leaves this class is the finished fact (`beltFacts`) and not
    /// the state machine that produced it.
    private var dial = ConsoleDialDetector()
    private var outstandingStop: OutstandingStop?
    private var lastStopTickAt: Date = .distantPast
    private var outstandingPause: OutstandingPause?
    private var lastPauseTickAt: Date = .distantPast
    /// Diagnostics only: has this waiting spell already said why it is waiting?
    /// Keeps "the belt is obeying, so nothing was sent" one line per spell instead
    /// of five a second (finding 199).
    private var loggedStopObeying = false
    private var userWantsConnection = false
    private var pendingScanRequest = false
    private var variantDetector = FitShowVariantDetector()
    private var variantLocked = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Demo mode (simulator only — the simulator has no Bluetooth)

    // `demoMode` is `@Published` so the composition root can rebind the
    // governor's heart-rate source (`DemoHeartRateSource` vs. the Watch) the
    // moment it flips, rather than only at launch.
    @Published private(set) var demoMode = false
    private var demoTimer: Timer?

    /// Demo heart-rate plant: a first-order lag toward a speed-dependent steady
    /// state, the same shape as `LaggedHeartRatePlant` in
    /// `HeartRateGovernorTests.swift`, so what a reviewer sees in demo mode is
    /// the trace the governor was designed and tested against.
    // `nonisolated`: plain immutable Doubles, read from `demoHeartRateStep`
    // below, which is itself `nonisolated` so it can be called as a pure
    // function without main-actor hops.
    private nonisolated static let demoRestingHeartRateBpm: Double = 60
    private nonisolated static let demoHeartRateBpmPerKmh: Double = 11
    private nonisolated static let demoHeartRateTauSeconds: Double = 30
    private var demoHeartRateBpm = FitShowTreadmillClient.demoRestingHeartRateBpm

    /// One second of the plant's lag, free of `self` and `Date()` so it is
    /// testable directly instead of only through the 1 Hz timer — the lesson
    /// behind the governor's own injected-time rule. The steady state is
    /// clamped to `HeartRateTarget.bandRangeBpm`'s own ceiling ("above this is
    /// above any plausible maximum") rather than left to grow with speed
    /// without bound: at the device's own top speed the unclamped formula
    /// reaches into the 230s, which no ceiling or band arithmetic downstream
    /// treats as a real heart rate.
    nonisolated static func demoHeartRateStep(current: Double, speedKmh: Double) -> Double {
        let steady = min(Double(HeartRateTarget.bandRangeBpm.upperBound),
                         demoRestingHeartRateBpm + demoHeartRateBpmPerKmh * speedKmh)
        return current + (steady - current) * (1 - exp(-1 / demoHeartRateTauSeconds))
    }

    /// The governor's only route to the demo plant, and never through
    /// `state.heartRate` — that field is where a real handlebar byte would
    /// arrive, and `GovernorHeartRateSource` must stay unreachable from it even
    /// in demo mode. 0 outside demo mode and while nothing is running, so the
    /// governor reads it exactly like a feed with nothing fresh to report.
    var demoHeartRateBpmForGovernor: Int {
        guard demoMode, state.isRunning else { return 0 }
        return Int(demoHeartRateBpm.rounded())
    }

    /// May demo mode be entered from this phase? **The client owns this rule**,
    /// and that is the point of the function existing: `demoMode` is an invariant
    /// of this class — nothing real is written, nothing real is read — and until
    /// now the only thing enforcing it was `ContentView`, which happens to render
    /// the DEMO MODE button (in `ScanView`) exactly in the three phases below.
    /// A UI routing table is not a guard; one new entry point to the same button
    /// and a simulated belt would be laid over a moving one.
    ///
    /// What it prevents, concretely: with a link up there are two writers to
    /// `state` — the 200 ms `tick()`, which runs as soon as there is a write
    /// characteristic, and the 1 Hz `demoTick()` — so real frames and a
    /// simulated belt would overwrite each other. Worse, `demoMode` short-circuits
    /// every command path (`startBelt`, `requestStop`, `requestPause`, `write`):
    /// a real belt at 10 km/h would become *uncommandable*, its stop button
    /// mutating a local struct instead of sending a stop frame. And the demo
    /// heart-rate expiry (finding 144) rests on "demo mode never reaches
    /// `tick()`", which is only true while there is no characteristic to poll on.
    ///
    /// **Refusing, rather than tearing the link down first.** An orderly
    /// teardown-then-demo would fix the two writers too, but it buys that by
    /// having a UI button silently cancel a connection to a belt that may be
    /// running, and `disconnect()`'s `abandonStopKeepingFailure()` would drop an
    /// outstanding stop *while the radio still exists* — the exact opposite of
    /// spec section 4, where the insistence belongs to the client because its
    /// lifetime is the connection, and nothing that ends a program may clear an
    /// outstanding stop. A button that does nothing is not a way to lose a belt;
    /// a button that hands away the only radio that can stop one is. Refusing
    /// also keeps `startDemo()` free of CoreBluetooth entirely, which is the
    /// other half of what `demoMode` promises.
    ///
    /// Demo mode's own phase is `.ready(…)`, so this makes a second entry a no-op
    /// as well. That is the right answer anyway: the demo the caller is asking
    /// for is already running, and starting it again would wipe a workout in
    /// progress.
    ///
    /// The switch is exhaustive on purpose — no `default`. A new
    /// `ConnectionPhase` case has to be classified here rather than defaulting
    /// into whichever answer happened to be listed first.
    nonisolated static func mayEnterDemo(phase: ConnectionPhase) -> Bool {
        switch phase {
        case .idle, .scanning, .bluetoothOff:
            // No peripheral link: nothing to write to, nothing polling, no
            // characteristic for `tick()` to return past. These are exactly the
            // phases `ContentView` shows `ScanView` — and therefore the DEMO MODE
            // button — in, so the working entry path is unchanged.
            return true
        case .connecting, .preparing, .ready:
            // A link to a real treadmill exists or is being established.
            return false
        }
    }

    func startDemo() {
        guard Self.mayEnterDemo(phase: phase) else { return }
        demoMode = true
        // `TreadmillControlling` does not carry this, so the runner cannot state
        // it on the workout's own line. The client says it once, here.
        diagnostics.noteDemoMode(true)
        lastError = nil
        state = TreadmillState()
        limits = TreadmillLimits()
        forgetTargets()
        // A simulated treadmill is a new world: there is no real belt left for the
        // insistence to ask again on, so the *request* goes. The **failure** does
        // not, exactly as in `disconnect()` — a belt last seen running after the
        // app asked it to stop is still a belt somebody has to walk over to, and
        // the demo button is on the scan screen of every build, not only the
        // simulator's. This used to clear both, so entering demo mode after a real
        // console refused a stop erased the red banner and the stop-at-the-console
        // instruction with it (finding 145). Same judged-from-evidence path as
        // every other teardown: an ordinary program end, whose belt was seen
        // winding down, raises nothing.
        abandonStopKeepingFailure()
        // A scan the app deferred is a scan nobody wants any more. On a cold
        // launch the central's state is still `.unknown`, so `ScanView.onAppear`'s
        // `startScan()` only sets `pendingScanRequest` and leaves the phase
        // `.idle` — which is precisely a phase the scan screen, and with it the
        // DEMO MODE button, is on screen in. Without this line the `poweredOn`
        // callback that arrives a moment later calls `startScan()`, which sets
        // `phase = .scanning` and empties `discovered`: the user is yanked out of
        // a running demo back to the scan screen while `demoMode` stays true and
        // the 1 Hz demo timer keeps ticking behind it. Only the flag is cleared;
        // `central.stopScan()` would be a CoreBluetooth call on a path that
        // promises not to make any. An actual scan in flight (entering demo from
        // `.scanning`) is left exactly as it was — that is today's behaviour and
        // not this fix's business.
        pendingScanRequest = false
        demoHeartRateBpm = Self.demoRestingHeartRateBpm
        phase = .ready(name: String(localized: "Demo treadmill (simulated)"))
        demoTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.demoTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        demoTimer = timer
    }

    private func stopDemo() {
        demoTimer?.invalidate()
        demoTimer = nil
        demoMode = false
        diagnostics.noteDemoMode(false)
        state = TreadmillState()
        phase = .idle
    }

    /// The fractional part of the demo step counter between two ticks.
    private var demoStepFraction = 0.0

    private func demoTick() {
        switch state.status {
        case .countdown:
            state.countdownSeconds -= 1
            if state.countdownSeconds <= 0 { state.status = .running }
        case .running:
            // The demo belt follows fact 1 — the app's own command — and the dial
            // detector watches it exactly as it watches a real console, so demo
            // mode exercises the same inference the hardware does.
            let diff = commandedSpeedKmh - state.speedKmh
            state.speedKmh = max(0, ((state.speedKmh + max(-0.5, min(0.5, diff))) * 10).rounded() / 10)
            state.inclinePercent = commandedIncline
            dial.observe(measuredSpeedUnits: HeartRateGovernor.speedUnits(state.speedKmh),
                         measuredIncline: state.inclinePercent, deltaSeconds: 1)
            // The demo belt has no `tick()` — the poll only runs on a real link —
            // so the dial's verdict is reported from here instead.
            diagnostics.noteDial(isSpeedSetByHand: dial.speed.isSetByHand,
                                 isInclineSetByHand: dial.incline.isSetByHand,
                                 commandedSpeedKmh: commandedSpeedKmh,
                                 measuredSpeedKmh: state.speedKmh,
                                 commandedIncline: commandedIncline,
                                 measuredIncline: state.inclinePercent)
            state.elapsedSeconds += 1
            state.distanceKm = ((state.distanceKm + state.speedKmh / 3600) * 1000).rounded() / 1000
            state.kcal = Int(Double(state.elapsedSeconds) * 0.11 * max(1, state.speedKmh / 6))
            // A realistic step rate: from walking to running, cadence is roughly
            // 1.7–3.0 steps/s, and does not grow linearly with speed. We accumulate
            // the fractional part, otherwise per-second rounding would wash it away.
            if state.speedKmh > 0 {
                demoStepFraction += 1.4 + state.speedKmh * 0.12
                let whole = demoStepFraction.rounded(.down)
                state.steps += Int(whole)
                demoStepFraction -= whole
            }
            // First-order lag toward a speed-dependent, clamped steady state:
            // heart rate rises with load and recovers when the belt slows,
            // instead of tracking speed instantaneously.
            demoHeartRateBpm = Self.demoHeartRateStep(current: demoHeartRateBpm,
                                                      speedKmh: state.speedKmh)
            state.heartRate = Int(demoHeartRateBpm.rounded())
        default:
            break
        }
    }

    private func demoStart() {
        state.status = .countdown
        state.countdownSeconds = 3
    }

    private func demoStop() {
        state = Self.demoBeltHalted(state, status: .idle)
    }

    private func demoPause() {
        state = Self.demoBeltHalted(state, status: .paused)
    }

    /// A demo belt that is no longer moving — stopped or paused, the same rule
    /// either way: the speed goes and **so does the heart-rate reading**.
    ///
    /// `state.heartRate` is expired by the reading's own age in `tick()`, and
    /// demo mode never gets there — `tick()` returns on its first line without a
    /// write characteristic, and the demo runs on `demoTimer` instead. So a
    /// paused demo belt used to leave the last bpm on screen indefinitely, and
    /// phase 2's rule that the zone chip disappears once the reading goes stale
    /// was broken in exactly the mode used for screenshots and App Store review
    /// (finding 144). Zeroing it here rather than decaying the plant, for two
    /// reasons: it is what `demoStop()` has always done, and it is what the real
    /// client does — a paused console sends no run-data frames, so the handlebar
    /// reading expires within `freshnessHorizonSeconds`. The plant
    /// (`demoHeartRateBpm`) is a body and not a reading: it keeps its value
    /// across the pause, nothing displays it while the belt stands, and
    /// `demoHeartRateBpmForGovernor` already reports 0 for a belt that is not
    /// running.
    nonisolated static func demoBeltHalted(_ state: TreadmillState,
                                           status: FitShow.Status) -> TreadmillState {
        var next = state
        next.status = status
        next.speedKmh = 0
        next.heartRate = 0
        return next
    }

    // MARK: - Connection

    func startScan() {
        lastError = nil
        switch central.state {
        case .poweredOn:
            pendingScanRequest = false
            discovered = []
            peripheralsById = [:]
            phase = .scanning
            central.scanForPeripherals(withServices: Self.advertisedServices)
        case .unknown, .resetting:
            // On a cold start the central's state is still .unknown — scanning starts
            // automatically when poweredOn arrives.
            pendingScanRequest = true
        default:
            phase = .bluetoothOff
        }
    }

    func stopScan() {
        pendingScanRequest = false
        central.stopScan()
        if phase == .scanning { phase = .idle }
    }

    func connect(to id: UUID) {
        guard let peripheral = peripheralsById[id] else { return }
        central.stopScan()
        userWantsConnection = true
        lastError = nil
        // A new device: the limits and targets learned from the previous treadmill do not apply.
        limits = TreadmillLimits()
        forgetTargets()
        targetsDirtyWhileNotRunning = false
        lostConnectionWhileRunning = false
        // Reload the previously detected frame variant for this device.
        if let stored = UserDefaults.standard.string(forKey: Self.variantKey(peripheral.identifier)),
           let storedVariant = FitShowVariant(rawValue: stored) {
            variant = storedVariant
            variantLocked = true
        } else {
            variant = .standard
            variantLocked = false
            variantDetector = FitShowVariantDetector()
        }
        self.peripheral = peripheral
        phase = .connecting(name: peripheral.name ?? String(localized: "Treadmill"))
        central.connect(peripheral)
        startPrepTimeout()
    }

    /// All three facts, back to what a treadmill nobody has commanded yet looks
    /// like. One function, because a fact 1 left behind by the previous device
    /// would be a command this one never received.
    ///
    /// It deliberately says nothing about a stop. A stop the app asked for outlives
    /// the program that asked, and it outlives a reconnection too: this used to be
    /// how connecting again erased an outstanding stop and the failure with it
    /// (finding 93). If the belt this connects to is standing, the first frame is
    /// idle and the insistence retires itself as obeyed; if it is the same belt
    /// still running, the insistence is exactly what is wanted.
    private func forgetTargets() {
        commandedSpeedKmh = limits.minSpeedKmh
        commandedIncline = 0
        targetSpeedKmh = commandedSpeedKmh
        targetIncline = commandedIncline
        // Anchored on the fact 1 it has just been given, not on a zero nobody
        // commanded: an axis whose recorded command is a value the app never sent
        // would read the belt's very first frame as a hand on the dial.
        dial = ConsoleDialDetector()
        dial.started(speedUnits: HeartRateGovernor.speedUnits(commandedSpeedKmh),
                     incline: commandedIncline,
                     measuredSpeedUnits: HeartRateGovernor.speedUnits(state.speedKmh),
                     measuredIncline: state.inclinePercent)
    }

    /// The request, dropped. `isStopOutstanding` is published, so it may only ever
    /// change here and in `requestStop`.
    private func clearOutstandingStop() {
        outstandingStop = nil
        loggedStopObeying = false
        if isStopOutstanding { isStopOutstanding = false }
    }

    /// The link is gone for good while a stop of the app's own was outstanding.
    /// There is no radio left to ask again on, so the request goes — but the
    /// failure stays: a belt that was asked to stop and was last seen running is
    /// exactly what the user has to be told about, and every teardown path except
    /// the radio-loss one used to drop both (finding 93).
    ///
    /// From evidence, though, like the give-up branch of the insistence: this is the
    /// other place that used to declare a failure unconditionally, and the app asks
    /// for a stop at the end of every ordinary program (finding 113).
    private func abandonStopKeepingFailure() {
        // A pause has no failure half to keep: giving up on the device ends the
        // suspend-and-hold it was carrying, and nothing else.
        clearOutstandingPause()
        guard let stop = outstandingStop else { return }
        clearOutstandingStop()
        if Self.abandonRaisesFailure(stop) {
            stopNotObeyed = true
        }
    }

    /// Does losing the link on this stop leave a failure the user has to act on? A
    /// pure function, judged only from the stop's own remembered evidence — never
    /// the client's live `state`. A disconnect wipes that to zero before this ever
    /// runs (finding 129: a 97% ceiling stop followed by a failed reconnect used to
    /// read the wiped zero as "the belt stopped" and raise nothing), and
    /// `lastSpeedKmh` already falls back to the speed the stop was requested at —
    /// its own initial value — for a stop nobody has watched even once.
    ///
    /// Either the failure clock already ran out, or the belt was not seen slowing
    /// on the last reading that actually arrived and is still not at zero: with the
    /// radio gone, nothing will ever observe it stop after that. A belt observed
    /// slowing is a belt obeying (finding 130) — raising this on any nonzero speed
    /// cried wolf on the wind-down every ordinary program ends with, since a belt
    /// shedding half a km/h a second is nonzero for the better part of twenty
    /// seconds. A belt last seen at zero is not something to send anybody across
    /// the room for.
    nonisolated static func abandonRaisesFailure(_ stop: OutstandingStop) -> Bool {
        stop.isFailure
            || (!stop.wasObservedSlowing && HeartRateGovernor.speedUnits(stop.lastSpeedKmh) > 0)
    }

    /// A stop that outlived a gap in the link. The request stays and the poll will
    /// re-issue it at once; what the gap costs is only the *observation*, so the
    /// failure clock is credited with it and the insistence's own clocks are not.
    /// That is what gives a reconnection a full window to insist in rather than
    /// abandoning the stop on its first tick (finding 93).
    private func creditStopOutage(seconds: TimeInterval) {
        guard let stop = outstandingStop else { return }
        let next = Self.outaged(stop, bySeconds: seconds)
        outstandingStop = next
        if next.isFailure, !stopNotObeyed { stopNotObeyed = true }
    }

    /// The outage, folded in — a pure function, because "a reconnection gets a
    /// full window to insist in" is a property worth testing rather than a
    /// statement order. The failure clock takes the whole gap (nothing could be
    /// observed slowing during it) and the insistence's own clocks take none of it
    /// (the app was not asking and had no radio to ask on), while the attempt clock
    /// is left due so the first tick on the new link re-issues at once.
    ///
    /// The gap counts against the obeying credit too (finding 199), for the same
    /// reason it counts for the failure clock: a wiped link is not an observation
    /// of a belt coming down, and a credit earned before the radio went away must
    /// not be what makes the reconnection wait. The first ticks after a reconnect
    /// read a stale `lastFrameAt` anyway, so they observe nothing at all.
    nonisolated static func outaged(_ stop: OutstandingStop,
                                    bySeconds seconds: Double) -> OutstandingStop {
        guard seconds.isFinite, seconds > 0 else { return stop }
        var next = stop
        next.secondsNotSlowing += seconds
        next.secondsSinceSlowing += seconds
        next.secondsSinceAttempt = stopReissueSeconds
        return next
    }

    func disconnect() {
        if demoMode { return stopDemo() }
        // The user has given up on this device: there is no longer a belt of ours
        // to insist to. The *failure* is not theirs to dismiss by disconnecting,
        // though — a belt last seen running after the app asked it to stop is
        // still a belt somebody has to walk over to.
        abandonStopKeepingFailure()
        userWantsConnection = false
        prepTimer?.invalidate()
        stopPolling()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        phase = .idle
    }

    // MARK: - Control (all of these are called by an explicit user action)

    /// Starting the belt from the dashboard. Only callable after a user confirmation!
    func userConfirmedStart() {
        startBelt(speedKmh: max(limits.minSpeedKmh, targetSpeedKmh), incline: targetIncline)
    }

    /// Starting the belt with given targets. For a program-driven start ProgramRunner
    /// calls this — exclusively after the user confirmation plus the cancellable
    /// app-side countdown.
    func startBelt(speedKmh: Double, incline: Int) {
        // An explicit start is the one thing that may cancel an outstanding stop:
        // it is a user action carrying its own confirmation. Nothing that merely
        // ends a *program* may do this — spec section 4, "A stop the app asked
        // for outlives the program that asked".
        clearOutstandingStop()
        // An outstanding pause goes with it: the user has asked for the belt to
        // move, so the suspend-and-hold the pause was carrying is over.
        clearOutstandingPause()
        stopNotObeyed = false
        record(command: speedKmh, incline: incline, origin: .start)
        targetsDirtyWhileNotRunning = false
        if demoMode { return demoStart() }
        enqueue(FitShowCommands.start)
        // Following the QZ pattern, we also send a target after starting.
        sendCurrentTargets()
    }

    /// A stop, and then the insistence on it until the belt is observed idle or
    /// ended. `enqueue` alone is not enough: the queue drops a command after
    /// three attempts (about 600 ms), and the radio gap that lets a heart rate
    /// sit unobserved at 97% of maximum is exactly the gap that eats those
    /// 600 ms. The insistence lives here because this object's lifetime is the
    /// *connection*: the program that asked is torn down in the same breath, and
    /// reviews found three ways it abandoned the stop — its own timer being
    /// invalidated, an ordinary navigation home calling `stop()`, and a `paused`
    /// frame read as a confirmed stop (finding 78).
    func requestStop() {
        if demoMode { return demoStop() }
        // A stop supersedes a pause: the stronger ask owns the belt from here,
        // and the runner's outstanding-stop guard already suspends and finishes
        // the program on its own.
        clearOutstandingPause()
        if outstandingStop == nil {
            // The speed the stop is asked for at is what the failure window is
            // sized against, so it is captured once, here (finding 95).
            outstandingStop = OutstandingStop(speedAtRequestKmh: state.speedKmh,
                                              lastSpeedKmh: state.speedKmh)
            isStopOutstanding = true
            lastStopTickAt = Date()
            // Both windows, written out: "the belt did not stop" is only readable
            // against the wind-down the belt was actually given.
            diagnostics.record(.stop, [
                .text("phase", "outstanding"),
                .speed("speedAtRequestKmh", state.speedKmh),
                .text("status", DiagnosticLog.name(of: state.status)),
                .seconds("failureWindowSeconds",
                         Self.stopFailureSeconds(fromSpeedKmh: state.speedKmh)),
                .seconds("giveUpWindowSeconds",
                         Self.stopGiveUpSeconds(fromSpeedKmh: state.speedKmh))])
        }
        enqueue(FitShowCommands.stop)
    }

    /// A pause, remembered as outstanding until the belt is observed standing.
    ///
    /// The command itself is the vendor 0x0A frame and the queue's three
    /// attempts; what this adds is the *fact of the ask*. The T40 honours a
    /// pause through many seconds of `running` frames at a falling speed before
    /// the standstill (finding 181), and the runner used to learn about the
    /// pause only from that standstill — so the whole wind-down stayed inside
    /// the segment, where the next governed evaluation wrote a target and a
    /// target-honouring console took the write as the pause being called off
    /// (finding 205). The demo path stays as it was: its pause is instant and
    /// reports `paused`, which the runner already suspends on.
    func requestPause() {
        if demoMode { return demoPause() }
        if outstandingPause == nil {
            outstandingPause = OutstandingPause(speedAtRequestKmh: state.speedKmh)
            isPauseOutstanding = true
            lastPauseTickAt = Date()
            diagnostics.record(.pause, [
                .text("phase", "requested"),
                .speed("speedAtRequestKmh", state.speedKmh),
                .text("status", DiagnosticLog.name(of: state.status)),
                .seconds("giveUpWindowSeconds",
                         Self.pauseGiveUpSeconds(fromSpeedKmh: state.speedKmh))])
        }
        enqueue(FitShowCommands.pause)
    }

    /// The pause, dropped without ceremony. A pause carries no failure and no
    /// banner — what ends here is only the runner's suspend-and-hold — so the
    /// user actions that supersede it (an explicit start, a stop of the app's
    /// own) and the paths that wipe the link's state all land here.
    private func clearOutstandingPause() {
        guard outstandingPause != nil else { return }
        outstandingPause = nil
        isPauseOutstanding = false
    }

    /// A new segment of a program has begun. It retires the console-dial verdict
    /// and nothing else: spec section 4, "Governing resumes at the next segment".
    ///
    /// `ProgramRunner.begin(_:at:)` calls this at the boundary, alongside its entry
    /// write; either order is safe, because a control-loop write never sets a
    /// verdict. Without it a hand-back leaked into the next segment — the verdict
    /// was released only by observing the belt *at* the app's command, which on a
    /// boundary with an entry ramp arrives after that segment's first evaluation
    /// has already latched a hand-back of its own (finding 114).
    func segmentBegan() {
        dial.segmentBegan()
    }

    /// The dashboard's ± tiles. **A person, not the control loop** — and the whole
    /// reason this is a separate entry point from `setTarget`: the two used to be
    /// the same call, so the dial inference cleared its evidence on a change the
    /// user made in the app while catching the same change made on the console,
    /// and the loop then accelerated back through it (spec section 4, "A manual
    /// change is a manual change wherever it is made"; finding 90). The tiles are
    /// enabled during a governed segment, which makes this the likeliest
    /// intervention of all.
    func adjustSpeed(by delta: Double) {
        write(speedKmh: targetSpeedKmh + delta, incline: targetIncline, origin: .hand(.speed))
    }

    func adjustIncline(by delta: Int) {
        write(speedKmh: targetSpeedKmh, incline: targetIncline + delta, origin: .hand(.incline))
    }

    /// The control loop's write: `ProgramRunner`'s segment entries, resumes and
    /// every `HeartRateGovernor` decision. A human's write goes through
    /// `adjustSpeed`/`adjustIncline` above.
    func setTarget(speedKmh: Double, incline: Int) {
        write(speedKmh: speedKmh, incline: incline, origin: .controlLoop)
    }

    /// Who made a write. The dial inference has to know, because "a person set
    /// this axis" is a fact about people and not about code paths.
    private enum WriteOrigin: Equatable {
        /// The control loop, or the app restating a target nobody chose.
        case controlLoop
        /// A person, in the app. The axis is the one they moved.
        case hand(HeartRateActuator)
        /// An explicit start: a user action carrying its own confirmation.
        case start

        /// How the diagnostic log names this write — nil for the control loop,
        /// whose write the runner logs with the rule that asked for it.
        var diagnosticOrigin: DiagnosticWriteOrigin? {
            switch self {
            case .controlLoop: return nil
            case .hand: return .user
            case .start: return .start
            }
        }
    }

    private func write(speedKmh: Double, incline: Int, origin: WriteOrigin) {
        let previous = HeartRateGovernor.Command(speedKmh: commandedSpeedKmh,
                                                 incline: commandedIncline)
        record(command: speedKmh, incline: incline, origin: origin)
        // The writes the runner does not make. A `.controlLoop` write is logged
        // by `ProgramRunner.write(_:to:origin:)` instead, which knows *which*
        // rule asked — a boundary's entry command, the band law, a brake, the
        // fallback — and one line saying that is worth more than two saying
        // "the control loop".
        if let logged = origin.diagnosticOrigin {
            diagnostics.record(.clientWrite, DiagnosticLog.writeFields(
                origin: logged,
                requested: HeartRateGovernor.Command(speedKmh: speedKmh, incline: incline),
                clamped: HeartRateGovernor.Command(speedKmh: commandedSpeedKmh,
                                                   incline: commandedIncline),
                previous: previous)
                + [.speed("beltSpeedKmh", state.speedKmh),
                   .flag("isLinkStale", staleData),
                   .flag("isStopOutstanding", isStopOutstanding)])
        }
        if demoMode { return } // the demo tick follows the targets
        guard state.isRunning else {
            // We do not send on a standing/counting-down belt — we catch up on the
            // transition to running.
            targetsDirtyWhileNotRunning = true
            return
        }
        sendCurrentTargets()
    }

    /// The single write path's bookkeeping: fact 1 is recorded here, the machine's
    /// clamps are applied here, and the dial detector is told whose write this was.
    ///
    /// Both bounds are applied here: the stale-link bound by `bounded(…)` and the
    /// outstanding-stop bound by `boundedByStop(…)`. `.start` is exempt from the
    /// second because `startBelt` has already cancelled the stop — it is the one
    /// user action that may.
    private func record(command speedKmh: Double, incline: Int, origin: WriteOrigin) {
        let stale = Self.bounded(speedKmh: speedKmh, incline: incline, isLinkStale: staleData,
                                 measuredSpeedKmh: state.speedKmh,
                                 measuredIncline: state.inclinePercent)
        let bound = Self.boundedByStop(speedKmh: stale.speedKmh, incline: stale.incline,
                                       isStopOutstanding: origin != .start
                                           && outstandingStop != nil,
                                       appSpeedKmh: commandedSpeedKmh,
                                       appIncline: commandedIncline,
                                       measuredSpeedKmh: state.speedKmh,
                                       measuredIncline: state.inclinePercent)
        commandedSpeedKmh = min(max(bound.speedKmh, limits.minSpeedKmh), limits.maxSpeedKmh)
        commandedIncline = min(max(bound.incline, limits.minIncline), limits.maxIncline)
        // The observation collapses onto the command at the instant of a write:
        // there is nothing newer to observe until the next frame.
        targetSpeedKmh = commandedSpeedKmh
        targetIncline = commandedIncline
        let speedUnits = HeartRateGovernor.speedUnits(commandedSpeedKmh)
        let measuredSpeedUnits = HeartRateGovernor.speedUnits(state.speedKmh)
        switch origin {
        case .controlLoop:
            dial.commanded(speedUnits: speedUnits, incline: commandedIncline,
                           measuredSpeedUnits: measuredSpeedUnits,
                           measuredIncline: state.inclinePercent)
        case .hand(let axis):
            dial.setByHand(axis, speedUnits: speedUnits, incline: commandedIncline,
                           measuredSpeedUnits: measuredSpeedUnits,
                           measuredIncline: state.inclinePercent)
        case .start:
            dial.started(speedUnits: speedUnits, incline: commandedIncline,
                         measuredSpeedUnits: measuredSpeedUnits,
                         measuredIncline: state.inclinePercent)
        }
    }

    /// Sends **fact 1** and never the observation: re-sending a reconciled target
    /// would let the app command a value nobody ever chose.
    private func sendCurrentTargets() {
        enqueue(FitShowCommands.setTarget(speedKmh: commandedSpeedKmh,
                                          inclinePercent: commandedIncline,
                                          limits: limits))
        lastTargetCommandAt = Date()
    }

    // MARK: - Command queue and poll

    private func enqueue(_ payload: [UInt8]) {
        // For the same CMD+sub we replace the not-yet-sent command (coalescing): two
        // quick "+" taps thus send a single, latest target, and a duplicated echo
        // cannot falsely acknowledge a command that was never sent.
        if payload.count >= 2,
           let index = pending.firstIndex(where: {
               $0.attempts == 0 && $0.payload.count >= 2
               && $0.payload[0] == payload[0] && $0.payload[1] == payload[1]
           }) {
            pending[index] = (payload, 0)
        } else {
            pending.append((payload, 0))
        }
    }

    private func startPolling() {
        stopPolling()
        // A stop outstanding across a link outage: nothing could be observed while
        // frames were absent, so the failure clock ran and the insistence's own
        // clocks did not — and the first tick on the fresh link must not
        // fast-forward either of them.
        creditStopOutage(seconds: Date().timeIntervalSince(lastStopTickAt))
        lastStopTickAt = Date()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        pending = []
    }

    private func tick() {
        guard writeCharacteristic != nil else { return }

        // Guarding data freshness: while running, older data is suspect — the
        // status and the speed in hand are then remembered values, not observations.
        let now = Date()
        staleData = state.isRunning
            && now.timeIntervalSince(lastFrameAt) > Self.freshnessHorizonSeconds
        // Both of these are transition-only inside the log, so the cost here is a
        // Bool read while the developer toggle is off — which is what keeps a
        // 200 ms poll a 200 ms poll.
        diagnostics.noteLinkStaleness(isStale: staleData,
                                      secondsSinceFrame: now.timeIntervalSince(lastFrameAt))
        diagnostics.noteDial(isSpeedSetByHand: dial.speed.isSetByHand,
                             isInclineSetByHand: dial.incline.isSetByHand,
                             commandedSpeedKmh: commandedSpeedKmh,
                             measuredSpeedKmh: state.speedKmh,
                             commandedIncline: commandedIncline,
                             measuredIncline: state.inclinePercent)
        // Expired here, at the single place that knows the reading's age, so no
        // reader of `state.heartRate` has to learn a freshness rule of its own.
        let fresh = Self.freshHeartRate(state.heartRate,
                                        readingAge: now.timeIntervalSince(lastHeartRateAt))
        if fresh != state.heartRate { state.heartRate = fresh }

        insistOnOutstandingStop(now: now)
        retireStopFailureIfObeyed(now: now)
        resolveOutstandingPause(now: now)

        // An unacknowledged command drops out after 3 sends so it does not starve the poll.
        if let head = pending.first, head.attempts >= 3 {
            pending.removeFirst()
        }
        if !pending.isEmpty {
            write(pending[0].payload)
            pending[0].attempts += 1
        } else {
            write(FitShowCommands.statusPoll)
        }
    }

    /// One poll of an outstanding stop: ask again while the belt has not been
    /// observed idle or ended, take the load off as belt-and-braces, and surface
    /// the failure once the belt has had its own wind-down to obey in.
    private func insistOnOutstandingStop(now: Date) {
        guard let stop = outstandingStop else { return }
        let delta = now.timeIntervalSince(lastStopTickAt)
        lastStopTickAt = now
        let frameAge = now.timeIntervalSince(lastFrameAt)
        let observedStopped = Self.isObservedStopped(status: state.status, frameAge: frameAge)
        let (next, step) = Self.insisting(
            stop, bySeconds: delta, isObservedStopped: observedStopped,
            measuredSpeedKmh: frameAge <= Self.freshnessHorizonSeconds ? state.speedKmh : nil)
        switch step {
        case .obeyed:
            diagnostics.record(.stop, [
                .text("phase", "observedStopped"),
                .text("status", DiagnosticLog.name(of: state.status)),
                .seconds("secondsSinceRequest", next.secondsSinceRequest),
                .int("attempts", next.attempts)])
            clearOutstandingStop()
            if stopNotObeyed { stopNotObeyed = false }
        case .abandoned:
            // Nothing here can stop the belt any more, so the shouting ends. Only
            // the *evidence* may raise the failure, though: a belt seen slowing all
            // the way down and then losing its last frames has refused nothing.
            // This branch used to declare the failure unconditionally, and because
            // it also drops the request — which is what the `.obeyed` branch above
            // needs to exist at all — the flag could never be cleared again, so a
            // false alarm silently refused every later program start for the rest
            // of the connection (finding 113).
            diagnostics.record(.stop, [
                .text("phase", "abandoned"),
                .seconds("secondsSinceRequest", next.secondsSinceRequest),
                .seconds("secondsNotSlowing", next.secondsNotSlowing),
                .speed("lastSpeedKmh", next.lastSpeedKmh),
                .flag("wasObservedSlowing", next.wasObservedSlowing),
                .flag("raisedFailure", next.isFailure)])
            clearOutstandingStop()
            if next.isFailure, !stopNotObeyed { stopNotObeyed = true }
        case .wait, .insist:
            outstandingStop = next
            // Once raised the warning stays until the belt is observed stopped.
            // The evidence for it does not go away by itself, and a red banner
            // that flickers is one nobody trusts.
            if next.isFailure, !stopNotObeyed {
                diagnostics.record(.stop, [
                    .text("phase", "failureRaised"),
                    .seconds("secondsSinceRequest", next.secondsSinceRequest),
                    .seconds("secondsNotSlowing", next.secondsNotSlowing),
                    .speed("speedAtRequestKmh", next.speedAtRequestKmh),
                    .speed("lastSpeedKmh", next.lastSpeedKmh)])
                stopNotObeyed = true
            }
            guard step == .insist else {
                // The re-issue came due and nothing went out, because the belt is
                // coming down on its own (finding 199). Worth seeing in a hardware
                // log — it is the difference between this fix working and the stop
                // frame being lost — but once per waiting spell, not once per tick:
                // the poll runs five times a second, and this is the ordinary case
                // at the end of every program.
                if next.isObeying, next.secondsSinceAttempt >= Self.stopReissueSeconds,
                   !loggedStopObeying {
                    loggedStopObeying = true
                    diagnostics.record(.stop, [
                        .text("phase", "obeying"),
                        .seconds("secondsSinceRequest", next.secondsSinceRequest),
                        .seconds("secondsSinceSlowing", next.secondsSinceSlowing),
                        .speed("lastSpeedKmh", next.lastSpeedKmh),
                        .text("status", DiagnosticLog.name(of: state.status))])
                }
                return
            }
            // The belt stopped being credited, so the next waiting spell is a new
            // one and says so in the log.
            loggedStopObeying = false
            diagnostics.record(.stop, [
                .text("phase", "insisted"),
                .int("attempt", next.attempts),
                .seconds("secondsSinceRequest", next.secondsSinceRequest),
                .seconds("secondsNotSlowing", next.secondsNotSlowing),
                .speed("lastSpeedKmh", next.lastSpeedKmh),
                .flag("wasObservedSlowing", next.wasObservedSlowing),
                .text("status", DiagnosticLog.name(of: state.status))])
            enqueue(FitShowCommands.stop)
            // The aid is handed an observation, never a wiped or remembered zero
            // and never fact 1: `next` has just been stored above, and its
            // `lastSpeedKmh` is the last speed that actually arrived.
            sendStopAidReduction(observedSpeedKmh: Self.stopAidObservedSpeedKmh(
                next, frameAge: frameAge, measuredSpeedKmh: state.speedKmh))
        }
    }

    /// The failure, retired on evidence once the request behind it is gone.
    ///
    /// `stopNotObeyed` outlives its request on purpose — a belt last seen running
    /// after the app asked it to stop is exactly what the user has to be told about,
    /// and no teardown may drop it (finding 93). It may not outlive the belt
    /// *stopping*, though: with the request cleared, `insistOnOutstandingStop`
    /// returns on its first line and the `.obeyed` branch can never fire again, so
    /// the flag would stand for the rest of the connection and refuse every later
    /// program start (finding 113).
    ///
    /// Evidence only, and the same evidence the insistence itself retires on: idle
    /// or ended, from a frame that actually arrived. A remembered idle cannot get
    /// here — the poll stops with the link, so a state wiped by a teardown is never
    /// read as an observation.
    private func retireStopFailureIfObeyed(now: Date) {
        guard Self.retiresStopFailure(
            isFailureStanding: stopNotObeyed,
            isRequestOutstanding: outstandingStop != nil,
            isObservedStopped: Self.isObservedStopped(
                status: state.status, frameAge: now.timeIntervalSince(lastFrameAt)))
        else { return }
        diagnostics.record(.stop, [
            .text("phase", "failureRetired"),
            .text("status", DiagnosticLog.name(of: state.status))])
        stopNotObeyed = false
    }

    /// The retirement rule, as a pure function: "the failure can be cleared, and
    /// only ever on evidence" is a property worth testing rather than a statement
    /// order. While a request is outstanding the insistence's own `.obeyed` branch
    /// owns the flag; this is only for after it has been given up on.
    nonisolated static func retiresStopFailure(isFailureStanding: Bool,
                                               isRequestOutstanding: Bool,
                                               isObservedStopped: Bool) -> Bool {
        isFailureStanding && !isRequestOutstanding && isObservedStopped
    }

    /// One poll of an outstanding pause: drop it the moment the belt is observed
    /// standing — the T40 reports a paused belt as `running` at 0 (finding 181),
    /// so the standstill is the observation the ask was for — and drop it too
    /// once the belt has outlived the wind-down it was given without ever coming
    /// down, so a lost pause frame cannot hold the runner's suspend forever.
    private func resolveOutstandingPause(now: Date) {
        guard let pause = outstandingPause else { return }
        let delta = now.timeIntervalSince(lastPauseTickAt)
        lastPauseTickAt = now
        let frameAge = now.timeIntervalSince(lastFrameAt)
        let (next, resolution) = Self.resolvingPause(
            pause, bySeconds: delta,
            isObservedStanding: Self.isObservedStanding(status: state.status,
                                                        speedKmh: state.speedKmh,
                                                        frameAge: frameAge))
        switch resolution {
        case .waiting:
            outstandingPause = next
        case .honoured:
            diagnostics.record(.pause, [
                .text("phase", "honoured"),
                .seconds("secondsSinceRequest", next.secondsSinceRequest),
                .text("status", DiagnosticLog.name(of: state.status)),
                .speed("speedKmh", state.speedKmh)])
            clearOutstandingPause()
        case .gaveUp:
            diagnostics.record(.pause, [
                .text("phase", "gaveUp"),
                .seconds("secondsSinceRequest", next.secondsSinceRequest),
                .speed("speedAtRequestKmh", next.speedAtRequestKmh),
                .speed("speedKmh", state.speedKmh),
                .text("status", DiagnosticLog.name(of: state.status))])
            clearOutstandingPause()
        }
    }

    /// The belt-and-braces reduction: **a stop aid, not a command anybody chose.**
    ///
    /// If the stop frame is what is being lost, a target the console does accept
    /// still brings the load down. One km/h at a time rather than a jump to the
    /// machine's minimum: a belt ramps at about 0.5 km/h per second whatever it is
    /// told, and a controlled deceleration is what a person standing on it needs.
    ///
    /// It goes straight onto the wire and touches none of the three facts: not the
    /// app's own command record, not the dial inference, not the dirty-target flag
    /// and not `lastTargetCommandAt`. Going through the public write path walked
    /// `commandedSpeedKmh` down a km/h per attempt on *every* stop — an ordinary
    /// program end included — and stranded the not-running dirty-target state, so
    /// the next manual or console start began at the device minimum (finding 96).
    private func sendStopAidReduction(observedSpeedKmh: Double) {
        let aid = Self.stopAidTarget(commandedSpeedKmh: commandedSpeedKmh,
                                     commandedIncline: commandedIncline,
                                     observedSpeedKmh: observedSpeedKmh,
                                     measuredIncline: state.inclinePercent, limits: limits)
        // The observation the reduction was computed *from*, named: this write
        // touches none of the three facts, so the file is the only place the
        // number it reduced from is ever recorded.
        diagnostics.record(.stop, [
            .text("phase", "aid"),
            .speed("observedSpeedKmh", observedSpeedKmh),
            .speed("commandedSpeedKmh", commandedSpeedKmh),
            .speed("aidSpeedKmh", aid.speedKmh),
            .int("aidIncline", aid.incline)])
        enqueue(FitShowCommands.setTarget(speedKmh: aid.speedKmh,
                                          inclinePercent: aid.incline, limits: limits))
    }

    /// What the stop aid asks for: one step below the lower of the app's own
    /// command and what the belt was last observed doing, never below the
    /// machine's minimum, with the incline restated at the lower of the same two.
    /// A pure function because "it can only ever reduce" should be a property of
    /// something tested.
    ///
    /// **An observation may only ever lower what the app asks for** (spec section
    /// 4, "Three facts, kept apart"), so the `min` has no fallback and no
    /// exception. `boundedByStop(…)` above can afford one: it only ever *bounds*
    /// a request somebody else made, and that request was already coming down.
    /// This function *originates* a target, and an origination that falls back to
    /// fact 1 turns "fails to reduce" into "commands an increase" — which is what
    /// it used to do (finding 143). The reproduction: a disconnect wipes `state`
    /// to zero but keeps the stop, the auto-reconnect never runs
    /// `forgetTargets()`, so `commandedSpeedKmh` survives at 10.0 while
    /// `lastFrameAt` is stale; the first re-issue then wrote a target of 9.0 at a
    /// belt coasting through 4, and restated it every `stopReissueSeconds` until
    /// a fresh frame landed. A brake that re-commands the app's remembered value
    /// is a brake that speeds the belt up.
    ///
    /// A measured 0 is therefore bounded *to*, not ignored: the machine minimum
    /// below already keeps the result a value the console can be set to, which
    /// was the whole of what the old fallback was for. The incline axis was
    /// always an unconditional `min` — proof, on this very line, that the
    /// conservative form works.
    nonisolated static func stopAidTarget(commandedSpeedKmh: Double, commandedIncline: Int,
                                          observedSpeedKmh: Double, measuredIncline: Int,
                                          limits: TreadmillLimits)
        -> (speedKmh: Double, incline: Int) {
        let from = min(commandedSpeedKmh, observedSpeedKmh)
        return (max(limits.minSpeedKmh, from - stopSpeedStepKmh),
                min(commandedIncline, measuredIncline))
    }

    /// Which observation the stop aid is allowed to reduce from — never fact 1,
    /// and never a `state` a teardown has wiped.
    ///
    /// A fresh frame is the belt itself. Without one, the last speed that
    /// actually *arrived*: `OutstandingStop.lastSpeedKmh`, initialised to the
    /// speed the stop was requested at, which is the same remembered evidence
    /// `abandonRaisesFailure(_:)` already judges a lost link from, and for the
    /// same reason — `didDisconnectPeripheral` zeroes the live state while
    /// keeping the stop, and an auto-reconnect re-enters the poll with a stale
    /// `lastFrameAt` and three limit queries queued ahead of the first status
    /// poll. So the aid keeps working across a reconnect while never asking for
    /// more than the last thing anybody saw.
    nonisolated static func stopAidObservedSpeedKmh(_ stop: OutstandingStop,
                                                    frameAge: TimeInterval,
                                                    measuredSpeedKmh: Double) -> Double {
        frameAge <= freshnessHorizonSeconds ? measuredSpeedKmh : stop.lastSpeedKmh
    }

    private func write(_ payload: [UInt8]) {
        guard let peripheral, let characteristic = writeCharacteristic else { return }
        let type: CBCharacteristicWriteType =
            characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(FitShowFrame.encode(payload), for: characteristic, type: type)
    }

    // MARK: - Incoming frames

    private func handleNotification(_ data: Data) {
        guard let payload = FitShowFrame.decode(data) else { return }
        lastFrameAt = Date()

        // Acknowledging a command echo: the reply starts with the sent CMD(+sub)
        // bytes. Only an already sent command can be acknowledged.
        if let head = pending.first,
           head.attempts > 0,
           payload.first == head.payload.first,
           head.payload.count < 2 || payload.count < 2 || payload[1] == head.payload[1] {
            pending.removeFirst()
        }

        // Detecting the frame variant from running frames (AnyRun consoles send time
        // as a minute+second pair and the words big-endian). Once known, we remember
        // it per device.
        if !variantLocked,
           payload.count >= 14,
           payload.first == FitShow.Command.sysStatus.rawValue,
           payload[1] == FitShow.Status.running.rawValue {
            variantDetector.observeRunningFrame(payload)
            if let detected = variantDetector.detected {
                variant = detected
                variantLocked = true
                if let id = peripheral?.identifier {
                    UserDefaults.standard.set(detected.rawValue, forKey: Self.variantKey(id))
                }
            }
        }

        switch FitShowParser.parse(payload, variant: variant) {
        case .runData(let data):
            let wasRunning = state.isRunning
            state.status = data.status
            state.speedKmh = data.speedKmh
            state.inclinePercent = data.inclinePercent
            state.elapsedSeconds = data.elapsedSeconds
            state.distanceKm = data.distanceKm
            state.kcal = data.kcal
            state.steps = data.steps
            state.heartRate = data.heartRate
            lastHeartRateAt = Date()
            if data.status == .running {
                observeDial(data)
                reconcileTargets(with: data, justStarted: !wasRunning)
            }
        case .idle:
            state.status = .idle
            state.speedKmh = 0
            state.countdownSeconds = 0
        case .countdown(let seconds):
            state.status = .countdown
            state.countdownSeconds = seconds
        case .statusOnly(let status):
            state.status = status
        case .speedLimits(let maxRaw, let minRaw) where maxRaw > 0:
            limits.maxSpeedRaw = maxRaw
            limits.minSpeedRaw = max(minRaw, 0)
            limits.fromDevice = true
        case .inclineLimits(let max, let min, _):
            limits.maxIncline = max
            limits.minIncline = min
            limits.fromDevice = true
        case .inclineUnsupported:
            limits.maxIncline = 0
            limits.minIncline = 0
        case .extendedLimits(let maxSpeedRaw, let minSpeedRaw, let maxIncline, let minIncline)
            where maxSpeedRaw > 0:
            limits.maxSpeedRaw = maxSpeedRaw
            limits.minSpeedRaw = max(minSpeedRaw, 0)
            limits.maxIncline = maxIncline
            limits.minIncline = minIncline
            limits.fromDevice = true
        case .controlAck, .other, .speedLimits, .extendedLimits:
            break
        }
    }

    private static func variantKey(_ id: UUID) -> String {
        "fitshow.variant.\(id.uuidString)"
    }

    /// Fact 3, one frame at a time.
    ///
    /// Only from a frame that reports a *moving* belt: a "running" status at
    /// 0 km/h is #181's console pause, and its zero is not a value anybody dialled
    /// in — the runner suspends the program on it, and the resume's own write
    /// re-anchors the detector.
    private func observeDial(_ data: RunData) {
        guard data.speedKmh > 0 else { return }
        // A wind-down the app itself asked for is not a person turning a dial:
        // while a pause is outstanding, the falling measurement is the belt
        // obeying that ask, and letting it accumulate here latched hand-backs
        // at random depending on where in the wind-down a frame landed. A
        // console-initiated pause has no ask to know about and is unchanged.
        guard outstandingPause == nil else { return }
        let now = Date()
        let delta = now.timeIntervalSince(lastRunningFrameAt)
        lastRunningFrameAt = now
        dial.observe(measuredSpeedUnits: HeartRateGovernor.speedUnits(data.speedKmh),
                     measuredIncline: data.inclinePercent, deltaSeconds: delta)
    }

    /// `targetSpeedKmh` / `targetIncline` recomputed from the two facts by the one
    /// reconcile rule — a pure function of (fact 1, fact 2, age of fact 1), so the
    /// number the dashboard shows is always one of two things and never a third
    /// that drifted there.
    private func reconcileTargets(with data: RunData, justStarted: Bool) {
        if justStarted && targetsDirtyWhileNotRunning {
            // A target set during the countdown/pause is applied on the transition to running.
            targetsDirtyWhileNotRunning = false
            sendCurrentTargets()
            return
        }
        let age = Date().timeIntervalSince(lastTargetCommandAt)
        let speedUnits = Self.reconciled(
            commandUnits: HeartRateGovernor.speedUnits(commandedSpeedKmh),
            measuredUnits: HeartRateGovernor.speedUnits(data.speedKmh),
            secondsSinceCommand: age, ignoreZeroMeasurement: true)
        let incline = Self.reconciled(commandUnits: commandedIncline,
                                      measuredUnits: data.inclinePercent,
                                      secondsSinceCommand: age, ignoreZeroMeasurement: false)
        let speed = HeartRateGovernor.speedKmh(units: speedUnits)
        if targetSpeedKmh != speed { targetSpeedKmh = speed }
        if targetIncline != incline { targetIncline = incline }
    }

    private func deviceReady() {
        guard case .preparing(let name) = phase else { return }
        prepTimer?.invalidate()
        phase = .ready(name: name)
        startPolling()
        // The order matters: startPolling empties the queue, so the limit queries can
        // only be enqueued after it.
        enqueue(FitShowCommands.infoSpeed)
        enqueue(FitShowCommands.infoIncline)
        enqueue(FitShowCommands.infoExtended)
    }

    // MARK: - Failure paths

    private func startPrepTimeout() {
        prepTimer?.invalidate()
        let timer = Timer(timeInterval: 15, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.preparationTimedOut() }
        }
        RunLoop.main.add(timer, forMode: .common)
        prepTimer = timer
    }

    private func preparationTimedOut() {
        switch phase {
        case .connecting:
            failPreparation(String(localized: "Couldn't connect to the device."))
        case .preparing:
            failPreparation(String(localized: "The device isn't responding — it may not be a FitShow console."))
        default:
            break
        }
    }

    private func failPreparation(_ message: String) {
        prepTimer?.invalidate()
        // A failed *re*connect is where an outstanding stop used to end for good,
        // after which connecting again erased it: the app forgot it had asked a
        // belt to stop (finding 93). The request cannot survive — there is no
        // radio — but the failure has to.
        abandonStopKeepingFailure()
        userWantsConnection = false
        stopPolling()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        writeCharacteristic = nil
        notifyCharacteristic = nil
        chosenServiceUUID = nil
        lastError = message
        phase = .idle
    }

    /// A full cleanup for when the link dies without the delegate callbacks (for
    /// example Bluetooth being turned off — there is no didDisconnectPeripheral then).
    private func teardownAfterRadioLoss() {
        prepTimer?.invalidate()
        stopPolling()
        if state.isRunning { lostConnectionWhileRunning = true }
        abandonStopKeepingFailure()
        state = TreadmillState()
        writeCharacteristic = nil
        notifyCharacteristic = nil
        chosenServiceUUID = nil
        peripheral = nil
        peripheralsById = [:]
        discovered = []
        userWantsConnection = false
    }
}

/// The governor's only route to the demo plant — a distinct type, not
/// `FitShowTreadmillClient` itself, because that is what keeps the client
/// structurally unable to conform to `GovernorHeartRateSource`: a call site
/// reaching for `client` directly (and, with it, the handlebar byte) would not
/// type-check, only this adapter does. Wired at the composition root, in place
/// of `WatchHeartRateManager`, exactly while `client.demoMode` is set.
@MainActor
final class DemoHeartRateSource: GovernorHeartRateSource {
    private weak var client: FitShowTreadmillClient?

    init(client: FitShowTreadmillClient) {
        self.client = client
    }

    func governorHeartRateBpm() -> Int {
        client?.demoHeartRateBpmForGovernor ?? 0
    }
}

// MARK: - CBCentralManagerDelegate / CBPeripheralDelegate
// The central runs on the main queue, so the delegate calls arrive on the MainActor.

extension FitShowTreadmillClient: @preconcurrency CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if phase == .bluetoothOff { phase = .idle }
            if pendingScanRequest { startScan() }
        case .poweredOff, .unauthorized, .unsupported, .resetting:
            // When the radio goes down the system does not send
            // didDisconnectPeripheral, so the cleanup has to happen here (timer,
            // characteristics, alert).
            teardownAfterRadioLoss()
            phase = .bluetoothOff
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        peripheralsById[peripheral.identifier] = peripheral
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? String(localized: "Unknown device")
        let item = DiscoveredTreadmill(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        if let index = discovered.firstIndex(where: { $0.id == item.id }) {
            discovered[index] = item
        } else {
            discovered.append(item)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        phase = .preparing(name: peripheral.name ?? String(localized: "Treadmill"))
        peripheral.delegate = self
        peripheral.discoverServices(Self.serialServices)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        failPreparation(String(localized: "Couldn't connect to the device."))
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        // A late-arriving disconnect belonging to an earlier device must not touch the state.
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        prepTimer?.invalidate()
        // An outstanding stop deliberately survives this. The poll dies with the
        // link — which is what dropped the stop frame in flight and killed the only
        // thing that re-issued it (finding 93) — but the *request* is kept, and
        // `startPolling` credits the outage and re-issues on the first tick of the
        // new link. If the reconnect never happens, the prep timeout below ends in
        // `failPreparation`, which keeps the failure.
        stopPolling()
        writeCharacteristic = nil
        notifyCharacteristic = nil
        chosenServiceUUID = nil
        if state.isRunning { lostConnectionWhileRunning = true }
        state = TreadmillState()
        if userWantsConnection {
            // connect() never expires: as soon as the treadmill is reachable again, we reconnect.
            phase = .connecting(name: peripheral.name ?? String(localized: "Treadmill"))
            central.connect(peripheral)
            startPrepTimeout()
        } else {
            phase = .idle
        }
    }
}

extension FitShowTreadmillClient: @preconcurrency CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        guard error == nil else {
            return failPreparation(String(localized: "Service discovery error."))
        }
        let serialServices = (peripheral.services ?? []).filter { Self.serialServices.contains($0.uuid) }
        guard !serialServices.isEmpty else {
            return failPreparation(String(localized: "This device doesn't use the FitShow protocol (no serial service)."))
        }
        for service in serialServices {
            peripheral.discoverCharacteristics(Self.writeCharUUIDs + Self.notifyCharUUIDs, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier, error == nil else { return }
        // The write and notify characteristics have to come from the same service,
        // otherwise we would write to one bridge and listen on the other.
        // 0xFFE0 is the primary one on Tunturis; 0xFFF0 is the fallback.
        if let chosen = chosenServiceUUID,
           chosen == Self.preferredService || service.uuid != Self.preferredService {
            return
        }
        let characteristics = service.characteristics ?? []
        guard let write = characteristics.first(where: { Self.writeCharUUIDs.contains($0.uuid) }),
              let notify = characteristics.first(where: { Self.notifyCharUUIDs.contains($0.uuid) })
        else { return }
        if let previous = notifyCharacteristic, previous.uuid != notify.uuid {
            // Switching to the preferred service: we cancel the old subscription so
            // frames do not arrive twice.
            peripheral.setNotifyValue(false, for: previous)
        }
        chosenServiceUUID = service.uuid
        writeCharacteristic = write
        notifyCharacteristic = notify
        peripheral.setNotifyValue(true, for: notify)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        guard error == nil else {
            return failPreparation(String(localized: "Couldn't subscribe to the device's data."))
        }
        guard characteristic.uuid == notifyCharacteristic?.uuid,
              characteristic.isNotifying,
              writeCharacteristic != nil else { return }
        deviceReady()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier,
              error == nil, let data = characteristic.value else { return }
        handleNotification(data)
    }
}
