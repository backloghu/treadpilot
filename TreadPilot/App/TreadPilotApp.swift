// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

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
        // The mirroring receiver has to be registered at app launch: HealthKit
        // can launch the app in the background to hand over a Watch session,
        // when there is no UI (and no onAppear) yet.
        WatchHeartRateManager.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            contentRoot
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

    /// In a DEBUG build the `-seedSampleData` flag fills the app with demo
    /// history (for screenshots) — see SampleData.
    @ViewBuilder
    private var contentRoot: some View {
        #if DEBUG
        ContentView().modifier(SampleDataSeeder())
        #else
        ContentView()
        #endif
    }
}
