import Foundation

/// A FitShow futópad-protokoll parancsai és állapotkódjai.
/// Források: FitShow gyártói doksi (futópad-protokoll v1.1),
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
        /// AnyRun-konzolok kiterjesztett limit-lekérdezése (a 0x02/0x03-ra nem válaszolnak).
        case extended = 0x05
    }

    enum ControlSub: UInt8 {
        case user = 0x00
        case start = 0x01
        case target = 0x02
        case stop = 0x03
        /// A QZ 0x06-ot küld pause-ként; a gyártói doksi szerint a 0x0A a pause
        /// és a 0x09 a start/resume — eszközön tesztelendő, melyiket érti a konzol.
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

/// A FitShow futásadat-keret két tájolási variánsa. Ugyanaz a keretszerkezet,
/// de az AnyRun-családú konzolok (pl. a 2019-es Tunturi T40, „SW…CAI” nevek)
/// az időt (perc, másodperc) bájtpárként, a többi szót big-endianben küldik.
/// Forrás: qdomyos-zwift fitshowtreadmill.cpp (fitshow_anyrun ág).
enum FitShowVariant: String {
    case standard  // szavak little-endian, idő = u16 másodperc
    case anyRun    // szavak big-endian, idő = (perc, másodperc)
}

/// Automatikus variáns-felismerés futás közben az idő-bájtpárból: standardnál
/// a keret 4. payload-bájtja lép másodpercenként (u16le alsó bájt), AnyRunnál
/// az 5. (a másodperc-bájt). Két egymást követő futó keretből eldönthető;
/// a perchatár-átfordulást (mindkét bájt változik) kihagyja.
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

/// A pad sebesség- és dőléskorlátai. A 2019-es Tunturi konzolok jellemzően nem
/// válaszolnak a SYS_INFO lekérdezésekre, ezért alapértelmezésekkel indulunk
/// (Competence T40 gyári specifikáció: 16 km/h, 12 dőlésszint), és csak akkor
/// írjuk felül, ha a pad mégis válaszol.
struct TreadmillLimits: Equatable {
    /// 0,1 km/h egységben.
    var minSpeedRaw: Int = 8
    var maxSpeedRaw: Int = 160
    var minIncline: Int = 0
    var maxIncline: Int = 12
    var fromDevice = false

    var minSpeedKmh: Double { Double(minSpeedRaw) / 10 }
    var maxSpeedKmh: Double { Double(maxSpeedRaw) / 10 }
}

/// Parancsépítők. Minden függvény a keretezetlen payloadot adja vissza
/// (CMD + adatbájtok); a keretezést a FitShowFrame.encode végzi.
enum FitShowCommands {
    /// `02 51 51 03` — státusz-poll, ez a protokoll szívverése (~200 ms-onként).
    static let statusPoll: [UInt8] = [FitShow.Command.sysStatus.rawValue]

    /// `02 53 01 00×8 52 03` — indítás; a konzol visszaszámlálással indul.
    /// A 8 nulla: sportID (u32) + mód (u8) + szegmensszám (u8) + módérték (u16).
    static let start: [UInt8] =
        [FitShow.Command.sysControl.rawValue, FitShow.ControlSub.start.rawValue]
        + Array(repeating: 0, count: 8)

    /// `02 53 03 50 03` — a szalag lelassul és megáll.
    static let stop: [UInt8] =
        [FitShow.Command.sysControl.rawValue, FitShow.ControlSub.stop.rawValue]

    /// `02 53 0A 59 03` — szünet a GYÁRTÓI doksi szerint (CONTROL_PAUSE = 0x0A).
    /// A QZ-féle 0x06 a vendor-táblában státuszkód (safety/disable): a T40-en
    /// beragadó, nem folytatható állapotot okozott — élő teszt igazolta (#181).
    static let pause: [UInt8] =
        [FitShow.Command.sysControl.rawValue, FitShow.ControlSub.pauseVendor.rawValue]

    /// Sebesség és dőlés egyetlen közös parancs: dőlésváltáshoz az aktuális
    /// sebességet küldjük újra az új dőlésbájttal.
    static func setTarget(speedKmh: Double, inclinePercent: Int, limits: TreadmillLimits) -> [UInt8] {
        let rawSpeed = Int((speedKmh * 10).rounded())
        let speed = UInt8(clamping: min(max(rawSpeed, limits.minSpeedRaw), limits.maxSpeedRaw))
        let incline = Int8(clamping: min(max(inclinePercent, limits.minIncline), limits.maxIncline))
        return [FitShow.Command.sysControl.rawValue, FitShow.ControlSub.target.rawValue,
                speed, UInt8(bitPattern: incline)]
    }

    /// Opcionális felhasználó-inicializálás (a tyge68-kliens e nélkül is működik).
    static func userInit(userId: UInt16 = 0, weightKg: UInt8 = 75) -> [UInt8] {
        [FitShow.Command.sysControl.rawValue, FitShow.ControlSub.user.rawValue,
         UInt8(userId & 0xFF), UInt8(userId >> 8), 110, 30, weightKg]
    }

    /// `02 50 02 52 03` — max/min sebesség lekérése.
    static let infoSpeed: [UInt8] =
        [FitShow.Command.sysInfo.rawValue, FitShow.InfoSub.speed.rawValue]

    /// `02 50 03 53 03` — max/min dőlés lekérése.
    static let infoIncline: [UInt8] =
        [FitShow.Command.sysInfo.rawValue, FitShow.InfoSub.incline.rawValue]

    /// `02 50 05 55 03` — kiterjesztett limitek (AnyRun-konzolok válaszolnak rá).
    static let infoExtended: [UInt8] =
        [FitShow.Command.sysInfo.rawValue, FitShow.InfoSub.extended.rawValue]

    /// `02 52 00 52 03` — kumulatív számlálók, amikor a gép nem fut.
    static let sportData: [UInt8] =
        [FitShow.Command.sysData.rawValue, 0x00]
}

/// A futó gép 17 bájtos állapotkeretének tartalma.
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

/// A padtól érkező, már kibontott payloadok értelmezett eseményei.
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
        // Az idle kizárólag az explicit 0x00 státuszbájtú válasz (02 51 00 51 03);
        // egy csupasz 0x51-visszhang nem jelentheti azt, hogy a szalag áll.
        guard payload.count > 1 else { return .other(command: payload[0], data: []) }
        let status = FitShow.Status(rawValue: payload[1])

        if status == .idle { return .idle }
        if status == .countdown {
            return .countdown(seconds: payload.count > 2 ? Int(payload[2]) : 0)
        }
        // Teljes futásadat-keret: 02 51 st spd incl idő16 táv16 kcal16 lépés16 HR szegm FCS 03
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
            // Egyes konzolok a lépésszámot a variánssal ellentétes bájtsorrendben
            // küldik — a fiziológiailag hihető olvasatot választjuk.
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

    /// Lépésszám hihetőség-választása: futásnál legfeljebb ~5 lépés/mp reális.
    /// Ha az elsődleges (variáns szerinti) olvasat túl nagy, a bájtcserés
    /// olvasatot használjuk; ha az sem hihető, 0 (a UI kötőjelet mutat).
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
            // Rövid válasz = a gép nem támogat dőlésvezérlést.
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
