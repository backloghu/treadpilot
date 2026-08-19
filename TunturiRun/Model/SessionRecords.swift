import Foundation
import SwiftData

/// Egy rögzített edzés. A mintákat kaszkád törléssel birtokolja.
@Model
final class WorkoutSessionRecord {
    var startedAt: Date
    var endedAt: Date?
    var deviceName: String
    var programName: String?
    /// Tényleges mozgásidő (mp) — a szünet külön számolódik.
    var movingSeconds: Int
    var pausedSeconds: Int
    var distanceKm: Double
    /// A pad saját kalóriaértéke (nyers, testadatok nélküli becslés).
    var padKcal: Int
    /// Az app saját számítása (a kalória-task tölti értelmes tartalommal).
    var computedKcal: Double
    var avgSpeedKmh: Double
    var maxSpeedKmh: Double
    var avgHeartRate: Int
    var maxHeartRate: Int
    var healthKitSynced: Bool
    /// Volt-e aktív Watch-session az edzés alatt — ilyenkor a Watch menti a
    /// workoutot a Healthbe, az iPhone-oldali export kihagyandó (duplikáció).
    var watchProvidedHeartRate: Bool = false
    /// Összes megtett emelkedés méterben (sebesség × pozitív dőlés integrálja).
    var elevationGainM: Double = 0

    @Relationship(deleteRule: .cascade, inverse: \WorkoutSampleRecord.session)
    var samples: [WorkoutSampleRecord]

    init(startedAt: Date, deviceName: String, programName: String?) {
        self.startedAt = startedAt
        self.endedAt = nil
        self.deviceName = deviceName
        self.programName = programName
        self.movingSeconds = 0
        self.pausedSeconds = 0
        self.distanceKm = 0
        self.padKcal = 0
        self.computedKcal = 0
        self.avgSpeedKmh = 0
        self.maxSpeedKmh = 0
        self.avgHeartRate = 0
        self.maxHeartRate = 0
        self.healthKitSynced = false
        self.samples = []
    }

    var totalSeconds: Int { movingSeconds + pausedSeconds }

    var sortedSamples: [WorkoutSampleRecord] {
        samples.sorted { $0.offsetSeconds < $1.offsetSeconds }
    }
}

/// Egy másodpercenkénti minta az edzésből.
@Model
final class WorkoutSampleRecord {
    var offsetSeconds: Int
    /// Valós idejű időbélyeg — a Health-exporthoz kell, mert a mozgásidő-offset
    /// szünetek után elcsúszna a fali órától.
    var timestamp: Date = Date.distantPast
    var speedKmh: Double
    var inclinePercent: Int
    var heartRate: Int
    var distanceKm: Double
    var session: WorkoutSessionRecord?

    init(offsetSeconds: Int, speedKmh: Double, inclinePercent: Int,
         heartRate: Int, distanceKm: Double) {
        self.offsetSeconds = offsetSeconds
        self.timestamp = Date()
        self.speedKmh = speedKmh
        self.inclinePercent = inclinePercent
        self.heartRate = heartRate
        self.distanceKm = distanceKm
    }
}
