// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Kft. — https://treadpilot.app

#if DEBUG

import Foundation
import SwiftData
import SwiftUI

/// Bemutató mintaadat képernyőképekhez (landing-kézikönyv, App Store).
///
/// Csak DEBUG buildben létezik, és ott is csak a `-seedSampleData` indítási
/// kapcsolóval fut le — így éles buildbe nem kerül bele, és fejlesztés közben
/// sem írja felül senki valódi előzményeit. Ugyanaz a parancs mindig ugyanazt
/// az állapotot állítja elő, tehát a képernyőképek megismételhetők.
///
///     xcrun simctl launch <udid> hu.backlog.treadpilot -seedSampleData
enum SampleData {

    static var isRequested: Bool {
        CommandLine.arguments.contains("-seedSampleData")
    }

    /// Egy edzés terve: ebből generálódnak a másodperces minták.
    private struct Plan {
        let daysAgo: Int
        let hour: Int
        let minute: Int
        let program: String?
        let segments: [(seconds: Int, speed: Double, incline: Int)]
        let restingHR: Int
        let peakHR: Int
        let synced: Bool
    }

    private static let plans: [Plan] = [
        // Ma reggel — intervallum, még NEM szinkronizált (az utólagos
        // Health-mentés bemutatásához).
        Plan(daysAgo: 0, hour: 7, minute: 12, program: "Tuesday intervals",
             segments: intervalSegments(rounds: 5, fast: 11.0, easy: 6.0),
             restingHR: 104, peakHR: 168, synced: false),
        Plan(daysAgo: 2, hour: 18, minute: 40, program: "Hill steady",
             segments: [(300, 5.5, 0), (600, 8.0, 4), (600, 8.5, 6),
                        (420, 8.0, 3), (300, 4.5, 0)],
             restingHR: 98, peakHR: 158, synced: true),
        Plan(daysAgo: 5, hour: 6, minute: 55, program: nil,
             segments: [(180, 5.0, 0), (900, 9.2, 1), (240, 4.5, 0)],
             restingHR: 96, peakHR: 154, synced: true),
        Plan(daysAgo: 7, hour: 19, minute: 20, program: "Tuesday intervals",
             segments: intervalSegments(rounds: 4, fast: 10.5, easy: 6.0),
             restingHR: 100, peakHR: 163, synced: true),
        Plan(daysAgo: 10, hour: 7, minute: 5, program: "Gentle test (6 min)",
             segments: [(120, 3.0, 0), (120, 5.0, 1), (120, 3.0, 0)],
             restingHR: 88, peakHR: 118, synced: true),
        Plan(daysAgo: 13, hour: 17, minute: 48, program: nil,
             segments: [(240, 5.5, 0), (1500, 9.8, 2), (300, 4.5, 0)],
             restingHR: 102, peakHR: 171, synced: true),
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

    // MARK: - Feltöltés

    static func seed(into context: ModelContext) {
        wipe(context)
        seedProfile()
        for plan in plans { insert(plan, into: context) }
        seedPrograms(into: context)
        try? context.save()
    }

    /// Ismételt futtatásnál ne duplikálódjon: a korábbi mintaadat törlődik.
    private static func wipe(_ context: ModelContext) {
        try? context.delete(model: WorkoutSampleRecord.self)
        try? context.delete(model: WorkoutSessionRecord.self)
        try? context.delete(model: CustomSegmentRecord.self)
        try? context.delete(model: CustomProgram.self)
    }

    private static func seedProfile() {
        let defaults = UserDefaults.standard
        defaults.set(78.0, forKey: "profile.weight")
        defaults.set(182.0, forKey: "profile.height")
        defaults.set(41, forKey: "profile.age")
        defaults.set(true, forKey: "profile.isMale")
        // A nyilatkozat ne takarja el a képernyőképeket.
        defaults.set(true, forKey: "disclaimer.accepted")
    }

    private static func insert(_ plan: Plan, into context: ModelContext) {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -plan.daysAgo, to: Date()) ?? Date()
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = plan.hour
        components.minute = plan.minute
        let start = calendar.date(from: components) ?? day

        let session = WorkoutSessionRecord(startedAt: start,
                                           deviceName: "SW5010CAI-2678",
                                           programName: plan.program)
        context.insert(session)

        let profile = BodyProfile(weightKg: 78, heightCm: 182, age: 41, isMale: true)
        var second = 0
        var distanceKm = 0.0
        var elevationM = 0.0
        var maxSpeed = 0.0
        var kcal = 0.0
        var hrSum = 0, hrCount = 0, hrMax = 0
        // A pulzus késleltetve követi a terhelést — enélkül a grafikon
        // szögletes lenne, és nem úgy nézne ki, mint egy valódi edzés.
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
                let bpm = Int(heartRate.rounded())
                hrSum += bpm; hrCount += 1; hrMax = max(hrMax, bpm)
                // Ugyanúgy integrálva, ahogy a valódi rögzítő teszi.
                kcal += CalorieEngine.kcalForSecond(speedKmh: speed,
                                                    inclinePercent: segment.incline,
                                                    heartRate: bpm,
                                                    profile: profile)

                // Ötmásodpercenként mentünk mintát: a grafikonhoz bőven elég,
                // és nem hizlalja fölöslegesen a mintaadatbázist.
                if second % 5 == 0 {
                    let sample = WorkoutSampleRecord(offsetSeconds: second,
                                                     speedKmh: speed,
                                                     inclinePercent: segment.incline,
                                                     heartRate: bpm,
                                                     distanceKm: distanceKm)
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
        session.watchProvidedHeartRate = true
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
    }
}

/// A feltöltést a nézethierarchia tetejére akasztjuk, hogy ne kelljen a
/// modellkonténer létrehozásába nyúlni (és kockáztatni a tárhely helyét).
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
