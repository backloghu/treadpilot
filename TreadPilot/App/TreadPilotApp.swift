// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Kft. — https://treadpilot.app

import SwiftData
import SwiftUI

@main
struct TreadPilotApp: App {
    @StateObject private var client = FitShowTreadmillClient()
    @StateObject private var runner = ProgramRunner()
    @StateObject private var recorder = SessionRecorder()
    @StateObject private var profileStore = ProfileStore()
    @StateObject private var exporter = HealthKitExporter()
    @StateObject private var watchHeartRate = WatchHeartRateManager.shared

    init() {
        // A tükrözés-átvevőt már app-induláskor regisztrálni kell: a HealthKit
        // háttérben is elindíthatja az appot egy Watch-session átadásához,
        // amikor UI (és onAppear) még nincs.
        WatchHeartRateManager.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(client)
                .environmentObject(runner)
                .environmentObject(recorder)
                .environmentObject(profileStore)
                .environmentObject(exporter)
                .environmentObject(watchHeartRate)
        }
        .modelContainer(for: [WorkoutSessionRecord.self, WorkoutSampleRecord.self,
                              CustomProgram.self, CustomSegmentRecord.self])
    }
}
