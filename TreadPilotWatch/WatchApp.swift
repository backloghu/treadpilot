// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import HealthKit
import SwiftUI
import WatchKit

/// The iPhone's `startWatchApp(toHandle:)` call hands over the workout
/// configuration through this delegate — without it the automatic Watch start
/// triggered from the phone would not work.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        Task { @MainActor in
            WatchWorkoutManager.shared.start()
        }
    }
}

@main
struct TreadPilotWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
    @StateObject private var workout = WatchWorkoutManager.shared

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(workout)
        }
    }
}
