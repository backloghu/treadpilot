// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import HealthKit
import SwiftUI
import WatchKit

/// Az iPhone `startWatchApp(toHandle:)` hívása ezen a delegate-en keresztül
/// adja át az edzés-konfigurációt — enélkül a telefonról indított automatikus
/// Watch-indítás nem működne.
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
