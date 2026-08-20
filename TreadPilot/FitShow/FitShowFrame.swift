// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import Foundation

/// FitShow BLE soros keret: `0x02 | CMD | DATA… | FCS | 0x03`,
/// ahol az FCS a CMD + DATA bájtok XOR-ja. Minden többbájtos érték little-endian.
///
/// A bejövő kereteket notification-határ szerint kell darabolni: az FCS értéke
/// legitim módon lehet 0x03 (pl. a 8,0 km/h + 2% parancsnál), ezért a 0x03
/// bájt keresése hibás keretezési stratégia.
enum FitShowFrame {
    static let header: UInt8 = 0x02
    static let footer: UInt8 = 0x03

    /// Keretbe csomagolja a payloadot (CMD + adatbájtok).
    static func encode(_ payload: [UInt8]) -> Data {
        var fcs: UInt8 = 0
        for byte in payload { fcs ^= byte }
        return Data([header] + payload + [fcs, footer])
    }

    /// Egy teljes bejövő notificationt bont ki; érvénytelen keretre nil.
    static func decode(_ data: Data) -> [UInt8]? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4,
              bytes.first == header,
              bytes.last == footer else { return nil }
        let payload = Array(bytes[1..<(bytes.count - 2)])
        let fcs = bytes[bytes.count - 2]
        var check: UInt8 = 0
        for byte in payload { check ^= byte }
        guard check == fcs else { return nil }
        return payload
    }
}
