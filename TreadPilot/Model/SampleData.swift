// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

#if DEBUG

import Foundation
import SwiftData
import SwiftUI

/// Demo sample data for screenshots (the landing page guide, the App Store).
///
/// It exists only in a DEBUG build, and even there it only runs with the
/// `-seedSampleData` launch flag — so it never reaches a release build, and it
/// does not overwrite anyone's real history during development. The same command
/// always produces the same state, so the screenshots are reproducible.
///
///     xcrun simctl launch <udid> hu.backlog.treadpilot -seedSampleData
enum SampleData {

    static var isRequested: Bool {
        CommandLine.arguments.contains("-seedSampleData")
    }

    /// The plan for one workout: the per-second samples are generated from it.
    private struct Plan {
        let daysAgo: Int
        let hour: Int
        let minute: Int
        let program: String?
        let segments: [(seconds: Int, speed: Double, incline: Int)]
        let restingHR: Int
        let peakHR: Int
        let synced: Bool
        let watchFeed: WatchFeed
        /// The one seeded workout that shows an active heart-rate target band
        /// (spec section 4, "Recording and review"): `nil` for every plan but
        /// one, so the history chart's band overlay has exactly one screenshot
        /// path and `hasTargetHeartRateBand` stays false everywhere else.
        /// Counted in flat session seconds, the same counter `insert(_:into:)`
        /// already keeps.
        // `var`, not `let`: a stored property's default value only becomes an
        // omittable parameter of the compiler-synthesized memberwise
        // initializer when the property is mutable (`let`+default is treated
        // as fixed and drops out of that initializer entirely).
        var bandSeconds: Range<Int>? = nil
        var bandLowBpm: Int = 0
        var bandHighBpm: Int = 0
    }

    /// What the Watch feed did during a demo workout. Coverage is counted from
    /// it second by second and never asserted, so a screenshot cannot advertise
    /// a reliability the samples themselves do not show.
    private enum WatchFeed {
        /// No Watch: the handlebar sensor recorded the heart rate, and the feed
        /// a governor would consume delivered nothing.
        case none
        case full
        case dropout(fromSecond: Int, seconds: Int)

        func delivered(at second: Int) -> Bool {
            switch self {
            case .none: return false
            case .full: return true
            case .dropout(let from, let seconds): return second < from || second >= from + seconds
            }
        }

        /// Whether anything recorded a heart rate this second: with no Watch the
        /// handlebar sensor stands in, but during a Watch dropout nothing does.
        func recorded(at second: Int) -> Bool {
            if case .none = self { return true }
            return delivered(at: second)
        }
    }

    private static let plans: [Plan] = [
        // This morning — intervals, NOT yet synced (to demonstrate the
        // retroactive Health save).
        Plan(daysAgo: 0, hour: 7, minute: 12, program: "Tuesday intervals",
             segments: intervalSegments(rounds: 5, fast: 11.0, easy: 6.0),
             restingHR: 104, peakHR: 168, synced: false,
             watchFeed: .dropout(fromSecond: 420, seconds: 95)),
        // The two climb segments (offsets 300..<1500) carry a heart-rate
        // target band: resting 98 / peak 158 puts the climbing effort's
        // converged heart rate at roughly 148-155 bpm (see the per-second
        // lag model below), so 135-158 brackets both the climb and the
        // seconds still converging into it.
        Plan(daysAgo: 2, hour: 18, minute: 40, program: "Hill steady",
             segments: [(300, 5.5, 0), (600, 8.0, 4), (600, 8.5, 6),
                        (420, 8.0, 3), (300, 4.5, 0)],
             restingHR: 98, peakHR: 158, synced: true, watchFeed: .full,
             bandSeconds: 300..<1500, bandLowBpm: 135, bandHighBpm: 158),
        Plan(daysAgo: 5, hour: 6, minute: 55, program: nil,
             segments: [(180, 5.0, 0), (900, 9.2, 1), (240, 4.5, 0)],
             restingHR: 96, peakHR: 154, synced: true,
             watchFeed: .dropout(fromSecond: 600, seconds: 210)),
        Plan(daysAgo: 7, hour: 19, minute: 20, program: "Tuesday intervals",
             segments: intervalSegments(rounds: 4, fast: 10.5, easy: 6.0),
             restingHR: 100, peakHR: 163, synced: true, watchFeed: .full),
        // Recorded without a Watch: the handlebar sensor gave a heart rate all
        // through, and the feed phase 3 would steer by gave nothing.
        Plan(daysAgo: 10, hour: 7, minute: 5, program: "Gentle test (6 min)",
             segments: [(120, 3.0, 0), (120, 5.0, 1), (120, 3.0, 0)],
             restingHR: 88, peakHR: 118, synced: true, watchFeed: .none),
        Plan(daysAgo: 13, hour: 17, minute: 48, program: nil,
             segments: [(240, 5.5, 0), (1500, 9.8, 2), (300, 4.5, 0)],
             restingHR: 102, peakHR: 171, synced: true, watchFeed: .full),
    ]

    private static func intervalSegments(rounds: Int, fast: Double,
                                         easy: Double) -> [(Int, Double, Int)] {
        var out: [(Int, Double, Int)] = [(180, 5.5, 0)]
        for _ in 0..<rounds {
            out.append((60, fast, 1))
            out.append((60, easy, 0))
        }
        out.append((180, 4.5, 0))
        return out
    }

    // MARK: - Seeding

    static func seed(into context: ModelContext) {
        wipe(context)
        seedDefaults()
        for plan in plans { insert(plan, into: context) }
        seedPrograms(into: context)
        try? context.save()
    }

    /// No duplication on a repeat run: previous sample data is deleted.
    private static func wipe(_ context: ModelContext) {
        try? context.delete(model: WorkoutSampleRecord.self)
        try? context.delete(model: WorkoutSessionRecord.self)
        try? context.delete(model: CustomSegmentRecord.self)
        try? context.delete(model: CustomProgram.self)
    }

    /// The `UserDefaults`-only half of the seeding. Split out of `seed(into:)`
    /// so it can run before any `ModelContext` exists — from the app's own
    /// `init()`, before the view hierarchy (and its `@AppStorage`/init-time
    /// reads of these same keys) ever appears — while `seed(into:)` still
    /// calls it too, so a direct call stays complete on its own. Idempotent:
    /// calling it twice on the same launch just writes the same values again.
    static func seedDefaults() {
        let defaults = UserDefaults.standard
        defaults.set(78.0, forKey: "profile.weight")
        defaults.set(182.0, forKey: "profile.height")
        defaults.set(41, forKey: "profile.age")
        defaults.set(true, forKey: "profile.isMale")
        // Keep the disclaimer from covering the screenshots: the same versioned
        // key ContentView gates on, so a version bump cannot leave this behind.
        defaults.set(DisclaimerView.currentVersion, forKey: "disclaimer.acceptedVersion")
        // Heart-rate control needs both the capability flag `ProgramRunner`
        // reads once at init and the one-time confirmation latch
        // `ProfileView` gates the toggle on (finding 120) — without the
        // latch, a seeded run would still be one dialog away from a governed
        // segment, and no screenshot flow can dismiss it.
        defaults.set(true, forKey: ProgramRunner.heartRateControlDefaultsKey)
        defaults.set(true, forKey: "heartRateControl.confirmedOnce")
    }

    private static func insert(_ plan: Plan, into context: ModelContext) {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -plan.daysAgo, to: Date()) ?? Date()
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = plan.hour
        components.minute = plan.minute
        let start = calendar.date(from: components) ?? day

        let session = WorkoutSessionRecord(startedAt: start,
                                           // A generic name: the developer's own treadmill's BLE identifier
                                           // must not reach the public repository or the screenshots.
                                           deviceName: "SW5010CAI-0000",
                                           programName: plan.program)
        context.insert(session)

        let profile = BodyProfile(weightKg: 78, heightCm: 182, age: 41, isMale: true)
        var second = 0
        var distanceKm = 0.0
        var elevationM = 0.0
        var maxSpeed = 0.0
        var kcal = 0.0
        var hrSum = 0, hrCount = 0, hrMax = 0
        var watchSeconds = 0
        // Heart rate follows the load with a lag — without that the chart would
        // be angular and would not look like a real workout.
        var heartRate = Double(plan.restingHR)

        for segment in plan.segments {
            for _ in 0..<segment.seconds {
                let speed = segment.speed
                distanceKm += speed / 3600
                elevationM += ElevationMath.gainPerSecond(speedKmh: speed,
                                                          inclinePercent: segment.incline)
                maxSpeed = max(maxSpeed, speed)

                let effort = speed / 12.0 + Double(segment.incline) / 25.0
                let target = Double(plan.restingHR)
                    + effort * Double(plan.peakHR - plan.restingHR)
                heartRate += (target - heartRate) * 0.045
                // The body's rate keeps running through a feed dropout; what
                // stops is the recording of it, so the two are separate values.
                let bpm = plan.watchFeed.recorded(at: second) ? Int(heartRate.rounded()) : 0
                if plan.watchFeed.delivered(at: second) { watchSeconds += 1 }
                if bpm > 0 { hrSum += bpm; hrCount += 1; hrMax = max(hrMax, bpm) }
                // Integrated the same way the real recorder does it.
                kcal += CalorieEngine.kcalForSecond(speedKmh: speed,
                                                    inclinePercent: segment.incline,
                                                    heartRate: bpm,
                                                    profile: profile)

                // A sample every five seconds: plenty for the chart, and it does
                // not bloat the sample store needlessly.
                if second % 5 == 0 {
                    let inBand = plan.bandSeconds?.contains(second) ?? false
                    let sample = WorkoutSampleRecord(offsetSeconds: second,
                                                     speedKmh: speed,
                                                     inclinePercent: segment.incline,
                                                     heartRate: bpm,
                                                     distanceKm: distanceKm,
                                                     targetHrLow: inBand ? plan.bandLowBpm : 0,
                                                     targetHrHigh: inBand ? plan.bandHighBpm : 0)
                    sample.timestamp = start.addingTimeInterval(TimeInterval(second))
                    sample.session = session
                    context.insert(sample)
                }
                second += 1
            }
        }

        let movingSeconds = second
        session.endedAt = start.addingTimeInterval(TimeInterval(movingSeconds))
        session.movingSeconds = movingSeconds
        session.distanceKm = distanceKm
        session.elevationGainM = elevationM
        session.maxSpeedKmh = maxSpeed
        session.avgSpeedKmh = movingSeconds > 0
            ? distanceKm / (Double(movingSeconds) / 3600) : 0
        session.avgHeartRate = hrCount > 0 ? hrSum / hrCount : 0
        session.maxHeartRate = hrMax
        session.watchProvidedHeartRate = watchSeconds > 0
        session.watchHeartRateSeconds = watchSeconds
        session.healthKitSynced = plan.synced

        session.computedKcal = kcal
        session.padKcal = Int(kcal.rounded())
    }

    private static func seedPrograms(into context: ModelContext) {
        let intervals = CustomProgram(name: "Tuesday intervals")
        var index = 0
        func add(_ name: String, _ seconds: Int, _ speed: Double, _ incline: Int) {
            let record = CustomSegmentRecord(orderIndex: index, name: name,
                                             durationSeconds: seconds,
                                             targetSpeedKmh: speed,
                                             targetIncline: incline)
            record.program = intervals
            intervals.segments.append(record)
            index += 1
        }
        add("Warm-up", 180, 5.5, 0)
        for round in 1...5 {
            add("Fast \(round)", 60, 11.0, 1)
            add("Recovery \(round)", 60, 6.0, 0)
        }
        add("Cool-down", 180, 4.5, 0)
        context.insert(intervals)

        let hills = CustomProgram(name: "Hill steady")
        let hillSegments: [(String, Int, Double, Int)] = [
            ("Warm-up", 300, 5.5, 0),
            ("Climb 1", 600, 8.0, 4),
            ("Climb 2", 600, 8.5, 6),
            ("Descent", 420, 8.0, 3),
            ("Cool-down", 300, 4.5, 0),
        ]
        for (offset, segment) in hillSegments.enumerated() {
            let record = CustomSegmentRecord(orderIndex: offset, name: segment.0,
                                             durationSeconds: segment.1,
                                             targetSpeedKmh: segment.2,
                                             targetIncline: segment.3)
            record.program = hills
            hills.segments.append(record)
        }
        context.insert(hills)

        // A heart-rate driven program, so the feature it seeds a Watch feed
        // for has something to run in demo mode: a warm-up, a governed zone
        // segment with a sane band and a deliberately modest speed corridor
        // (`HeartRateTarget.seeded`'s own default), and a recovery segment
        // that walks until the heart rate comes down, capped by its mandatory
        // time limit — the honest shape of the feature, not a flattering one.
        let hrZone = CustomProgram(name: "Heart-rate zone")
        let warmup = CustomSegmentRecord(orderIndex: 0, name: "Warm-up",
                                         durationSeconds: 180,
                                         targetSpeedKmh: 5.0, targetIncline: 0)
        warmup.program = hrZone
        hrZone.segments.append(warmup)

        let zone = CustomSegmentRecord(orderIndex: 1, name: "Zone 3",
                                       durationSeconds: 600,
                                       targetSpeedKmh: 7.0, targetIncline: 0)
        zone.target = .heartRate(.seeded(startSpeedKmh: 7.0, startIncline: 0))
        zone.program = hrZone
        hrZone.segments.append(zone)

        let recovery = CustomSegmentRecord(orderIndex: 2, name: "Recovery",
                                           durationSeconds: 300,
                                           targetSpeedKmh: 4.5, targetIncline: 0)
        recovery.goal = .untilHeartRateBelow(
            bpm: WorkoutSegment.defaultGoalHeartRateBelowBpm, maxSeconds: 300)
        recovery.program = hrZone
        hrZone.segments.append(recovery)

        context.insert(hrZone)
    }
}

/// The seeding is hung off the top of the view hierarchy so we do not have to
/// reach into model container creation (and risk the store's location).
struct SampleDataSeeder: ViewModifier {
    @Environment(\.modelContext) private var context
    @State private var done = false

    func body(content: Content) -> some View {
        content.task {
            guard SampleData.isRequested, !done else { return }
            done = true
            SampleData.seed(into: context)
        }
    }
}

#endif
