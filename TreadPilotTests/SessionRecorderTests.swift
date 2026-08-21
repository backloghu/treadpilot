// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import XCTest
@testable import TreadPilot

final class SessionRecorderTests: XCTestCase {

    // MARK: - Which source a recorded second is credited to

    func testAWatchReadingWinsAndIsCreditedToTheWatch() {
        let resolved = SessionRecorder.resolveHeartRate(watchBpm: 141, handlebarBpm: 148)
        XCTAssertEqual(resolved.bpm, 141)
        XCTAssertTrue(resolved.fromWatch)
    }

    func testAHandlebarReadingIsRecordedButNeverCreditedToTheWatch() {
        // The Watch app failed to launch, the user holds the grips: the second
        // has a heart rate to record and no Watch coverage to claim.
        let resolved = SessionRecorder.resolveHeartRate(watchBpm: 0, handlebarBpm: 148)
        XCTAssertEqual(resolved.bpm, 148)
        XCTAssertFalse(resolved.fromWatch)
    }

    func testASecondWithNoReadingAtAllIsCreditedToNothing() {
        // Both sources say 0 — the handlebar one also once its frame has expired.
        let resolved = SessionRecorder.resolveHeartRate(watchBpm: 0, handlebarBpm: 0)
        XCTAssertEqual(resolved.bpm, 0)
        XCTAssertFalse(resolved.fromWatch)
    }
}
