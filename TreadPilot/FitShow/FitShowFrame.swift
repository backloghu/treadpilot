// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import Foundation

/// FitShow BLE soros keret: `0x02 | CMD | DATA… | FCS | 0x03`,
/// where FCS is the XOR of the CMD + DATA bytes. Every multi-byte value is little-endian.
///
/// Incoming frames must be split on notification boundaries: the FCS value can
/// legitimately be 0x03 (for example for the 8.0 km/h + 2% command), so scanning
/// for the 0x03 byte is a faulty framing strategy.
enum FitShowFrame {
    static let header: UInt8 = 0x02
    static let footer: UInt8 = 0x03

    /// Wraps the payload (CMD + data bytes) into a frame.
    static func encode(_ payload: [UInt8]) -> Data {
        var fcs: UInt8 = 0
        for byte in payload { fcs ^= byte }
        return Data([header] + payload + [fcs, footer])
    }

    /// Unpacks one complete incoming notification; nil for an invalid frame.
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
