// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import Foundation

/// The FitShow treadmill protocol's commands and status codes.
/// Sources: FitShow vendor documentation (treadmill protocol v1.1),
/// qdomyos-zwift fitshowtreadmill.cpp, tyge68/fitshow-treadmill.
enum FitShow {
    enum Command: UInt8 {
        case sysInfo = 0x50
        case sysStatus = 0x51
        case sysData = 0x52
        case sysControl = 0x53
    }

    enum InfoSub: UInt8 {
        case model = 0x00
        case date = 0x01
        case speed = 0x02
        case incline = 0x03
        case total = 0x04
        /// Extended limit query for AnyRun consoles (they do not answer 0x02/0x03).
        case extended = 0x05
    }

    enum ControlSub: UInt8 {
        case user = 0x00
        case start = 0x01
        case target = 0x02
        case stop = 0x03
        /// QZ sends 0x06 as pause; per the vendor documentation 0x0A is pause and
        /// 0x09 is start/resume — which one the console understands is to be tested
        /// on device.
        case pauseQZ = 0x06
        case startVendor = 0x09
        case pauseVendor = 0x0A
    }

    enum Status: UInt8 {
        case idle = 0x00
        case end = 0x01
        case countdown = 0x02
        case running = 0x03
        case stopping = 0x04
        case error = 0x05
        case safety = 0x06
        case study = 0x07
        case ready = 0x09
        case paused = 0x0A
    }
}

/// The two byte-order variants of the FitShow run-data frame. The frame layout is
/// the same, but AnyRun-family consoles (for example the 2019 Tunturi T40, with
/// "SW…CAI" names) send time as a (minute, second) byte pair and the other words
/// big-endian.
/// Source: qdomyos-zwift fitshowtreadmill.cpp (the fitshow_anyrun branch).
enum FitShowVariant: String {
    case standard  // words little-endian, time = u16 seconds
    case anyRun    // words big-endian, time = (minute, second)
}

/// Automatic variant detection at run time from the time byte pair: with standard,
/// the frame's 4th payload byte advances every second (the low byte of a u16le);
/// with AnyRun it is the 5th (the seconds byte). Two consecutive running frames are
/// enough to decide; the minute rollover (where both bytes change) is skipped.
struct FitShowVariantDetector {
    private var lastByte4: UInt8?
    private var lastByte5: UInt8?
    private(set) var detected: FitShowVariant?

    mutating func observeRunningFrame(_ payload: [UInt8]) {
        guard detected == nil, payload.count >= 6 else { return }
        defer {
            lastByte4 = payload[4]
            lastByte5 = payload[5]
        }
        guard let lastByte4, let lastByte5 else { return }
        let changed4 = payload[4] != lastByte4
        let changed5 = payload[5] != lastByte5
        if changed4 && !changed5 {
            detected = .standard
        } else if changed5 && !changed4 {
            detected = .anyRun
        }
    }
}

/// The treadmill's speed and incline limits. The 2019 Tunturi consoles typically do
/// not answer the SYS_INFO queries, so we start from defaults (Competence T40 factory
/// specification: 16 km/h, 12 incline levels) and only override them if the treadmill
/// does answer.
struct TreadmillLimits: Equatable {
    /// In units of 0.1 km/h.
    var minSpeedRaw: Int = 8
    var maxSpeedRaw: Int = 160
    var minIncline: Int = 0
    var maxIncline: Int = 12
    var fromDevice = false

    var minSpeedKmh: Double { Double(minSpeedRaw) / 10 }
    var maxSpeedKmh: Double { Double(maxSpeedRaw) / 10 }
}

/// Command builders. Every function returns the unframed payload (CMD + data
/// bytes); framing is done by FitShowFrame.encode.
enum FitShowCommands {
    /// `02 51 51 03` — status poll, the protocol's heartbeat (roughly every 200 ms).
    static let statusPoll: [UInt8] = [FitShow.Command.sysStatus.rawValue]

    /// `02 53 01 00×8 52 03` — start; the console begins with a countdown.
    /// The 8 zero bytes: sportID (u32) + mode (u8) + segment count (u8) + mode value (u16).
    static let start: [UInt8] =
        [FitShow.Command.sysControl.rawValue, FitShow.ControlSub.start.rawValue]
        + Array(repeating: 0, count: 8)

    /// `02 53 03 50 03` — the belt slows down and stops.
    static let stop: [UInt8] =
        [FitShow.Command.sysControl.rawValue, FitShow.ControlSub.stop.rawValue]

    /// `02 53 0A 59 03` — pause per the VENDOR documentation (CONTROL_PAUSE = 0x0A).
    /// QZ's 0x06 is a status code in the vendor table (safety/disable): on the T40 it
    /// caused a stuck, unresumable state — confirmed by a live test (#181).
    static let pause: [UInt8] =
        [FitShow.Command.sysControl.rawValue, FitShow.ControlSub.pauseVendor.rawValue]

    /// Speed and incline share a single command: to change incline we re-send the
    /// current speed with the new incline byte.
    static func setTarget(speedKmh: Double, inclinePercent: Int, limits: TreadmillLimits) -> [UInt8] {
        let rawSpeed = Int((speedKmh * 10).rounded())
        let speed = UInt8(clamping: min(max(rawSpeed, limits.minSpeedRaw), limits.maxSpeedRaw))
        let incline = Int8(clamping: min(max(inclinePercent, limits.minIncline), limits.maxIncline))
        return [FitShow.Command.sysControl.rawValue, FitShow.ControlSub.target.rawValue,
                speed, UInt8(bitPattern: incline)]
    }

    /// Optional user initialisation (the tyge68 client works without it).
    static func userInit(userId: UInt16 = 0, weightKg: UInt8 = 75) -> [UInt8] {
        [FitShow.Command.sysControl.rawValue, FitShow.ControlSub.user.rawValue,
         UInt8(userId & 0xFF), UInt8(userId >> 8), 110, 30, weightKg]
    }

    /// `02 50 02 52 03` — query max/min speed.
    static let infoSpeed: [UInt8] =
        [FitShow.Command.sysInfo.rawValue, FitShow.InfoSub.speed.rawValue]

    /// `02 50 03 53 03` — query max/min incline.
    static let infoIncline: [UInt8] =
        [FitShow.Command.sysInfo.rawValue, FitShow.InfoSub.incline.rawValue]

    /// `02 50 05 55 03` — extended limits (AnyRun consoles answer this one).
    static let infoExtended: [UInt8] =
        [FitShow.Command.sysInfo.rawValue, FitShow.InfoSub.extended.rawValue]

    /// `02 52 00 52 03` — cumulative counters, while the machine is not running.
    static let sportData: [UInt8] =
        [FitShow.Command.sysData.rawValue, 0x00]
}

/// The contents of the running machine's 17-byte status frame.
struct RunData: Equatable {
    var status: FitShow.Status
    var speedKmh: Double
    var inclinePercent: Int
    var elapsedSeconds: Int
    var distanceKm: Double
    var kcal: Int
    var steps: Int
    var heartRate: Int
    var programSegment: Int
}

/// The interpreted events of the already-unpacked payloads arriving from the treadmill.
enum FitShowEvent: Equatable {
    case runData(RunData)
    case idle
    case countdown(seconds: Int)
    case statusOnly(FitShow.Status)
    case speedLimits(maxRaw: Int, minRaw: Int)
    case inclineLimits(max: Int, min: Int, pauseSupported: Bool)
    case inclineUnsupported
    case extendedLimits(maxSpeedRaw: Int, minSpeedRaw: Int, maxIncline: Int, minIncline: Int)
    case controlAck(sub: UInt8, data: [UInt8])
    case other(command: UInt8, data: [UInt8])
}

enum FitShowParser {
    static func parse(_ payload: [UInt8], variant: FitShowVariant = .standard) -> FitShowEvent {
        guard let first = payload.first else { return .other(command: 0, data: []) }
        switch first {
        case FitShow.Command.sysStatus.rawValue:
            return parseStatus(payload, variant: variant)
        case FitShow.Command.sysInfo.rawValue:
            return parseInfo(payload)
        case FitShow.Command.sysControl.rawValue:
            let sub = payload.count > 1 ? payload[1] : 0
            return .controlAck(sub: sub, data: Array(payload.dropFirst(2)))
        default:
            return .other(command: first, data: Array(payload.dropFirst()))
        }
    }

    private static func parseStatus(_ payload: [UInt8], variant: FitShowVariant) -> FitShowEvent {
        // Idle is exclusively the reply with an explicit 0x00 status byte
        // (02 51 00 51 03); a bare 0x51 echo cannot mean the belt is stopped.
        guard payload.count > 1 else { return .other(command: payload[0], data: []) }
        let status = FitShow.Status(rawValue: payload[1])

        if status == .idle { return .idle }
        if status == .countdown {
            return .countdown(seconds: payload.count > 2 ? Int(payload[2]) : 0)
        }
        // Full run-data frame: 02 51 st spd incl time16 dist16 kcal16 steps16 HR seg FCS 03
        if payload.count >= 14, let status {
            let elapsed: Int, distanceRaw: Int, kcal: Int
            let stepsPrimary: Int, stepsSecondary: Int
            let stepsLE = Int(payload[10]) | (Int(payload[11]) << 8)
            let stepsBE = Int(payload[11]) | (Int(payload[10]) << 8)
            switch variant {
            case .standard:
                elapsed = Int(payload[4]) | (Int(payload[5]) << 8)
                distanceRaw = Int(payload[6]) | (Int(payload[7]) << 8)
                kcal = Int(payload[8]) | (Int(payload[9]) << 8)
                stepsPrimary = stepsLE
                stepsSecondary = stepsBE
            case .anyRun:
                elapsed = Int(payload[4]) * 60 + Int(payload[5])
                distanceRaw = Int(payload[7]) | (Int(payload[6]) << 8)
                kcal = Int(payload[9]) | (Int(payload[8]) << 8)
                stepsPrimary = stepsBE
                stepsSecondary = stepsLE
            }
            // Some consoles send the step count in the opposite byte order to the
            // variant — we pick the physiologically plausible reading.
            let steps = plausibleSteps(primary: stepsPrimary, secondary: stepsSecondary,
                                       elapsedSeconds: elapsed)
            let data = RunData(
                status: status,
                speedKmh: Double(payload[2]) / 10,
                inclinePercent: Int(Int8(bitPattern: payload[3])),
                elapsedSeconds: elapsed,
                distanceKm: Double(distanceRaw) / 10,
                kcal: kcal,
                steps: steps,
                heartRate: Int(payload[12]),
                programSegment: Int(payload[13])
            )
            return .runData(data)
        }
        if let status { return .statusOnly(status) }
        return .other(command: payload[0], data: Array(payload.dropFirst()))
    }

    /// Plausibility choice for the step count: while running, at most ~5 steps/s is
    /// realistic. If the primary reading (per the variant) is too large we use the
    /// byte-swapped one; if that is not plausible either, 0 (the UI shows a dash).
    static func plausibleSteps(primary: Int, secondary: Int, elapsedSeconds: Int) -> Int {
        let cap = elapsedSeconds * 5 + 90
        if primary <= cap { return primary }
        if secondary <= cap { return secondary }
        return 0
    }

    private static func parseInfo(_ payload: [UInt8]) -> FitShowEvent {
        guard payload.count > 1 else { return .other(command: payload[0], data: []) }
        switch payload[1] {
        case FitShow.InfoSub.speed.rawValue where payload.count >= 4:
            return .speedLimits(maxRaw: Int(payload[2]), minRaw: Int(payload[3]))
        case FitShow.InfoSub.incline.rawValue:
            // A short reply = the machine does not support incline control.
            guard payload.count >= 4 else { return .inclineUnsupported }
            return .inclineLimits(
                max: Int(Int8(bitPattern: payload[2])),
                min: Int(Int8(bitPattern: payload[3])),
                pauseSupported: payload.count > 4 && payload[4] & 0x02 != 0
            )
        case FitShow.InfoSub.extended.rawValue where payload.count >= 6:
            return .extendedLimits(
                maxSpeedRaw: Int(payload[2]),
                minSpeedRaw: Int(payload[3]),
                maxIncline: Int(Int8(bitPattern: payload[4])),
                minIncline: Int(Int8(bitPattern: payload[5]))
            )
        default:
            return .other(command: payload[0], data: Array(payload.dropFirst()))
        }
    }
}
