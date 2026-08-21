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
        #if DEBUG
        // Before anything reads them: `@StateObject`'s own construction is
        // deferred past this initializer (its `wrappedValue` autoclosure only
        // runs once SwiftUI resolves the property, after `init()` returns),
        // but `ProgramRunner.init()` still snapshots the heart-rate-control
        // flag from `UserDefaults` exactly once, so the seeded value has to
        // land before that happens — not from `ContentView.onAppear`, which
        // runs later still.
        if SampleData.isRequested { SampleData.seedDefaults() }
        #endif
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
                .task {
                    // Wired at the composition root rather than on a screen: the
                    // basis a workout freezes may not depend on which view has
                    // appeared. No workout can begin before the recorder is bound.
                    recorder.heartRateBasisProvider = { [weak profileStore] in
                        profileStore?.heartRateBasis
                    }
                }
                .modifier(HeartRateSourceWiring(client: client, runner: runner,
                                               recorder: recorder, watchHeartRate: watchHeartRate))
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

/// Rebinds the governor's heart-rate source between the Watch feed and the
/// demo plant whenever `client.demoMode` flips, so a simulator run can drive
/// and show the loop end to end while a real run keeps the Watch feed. A
/// screen must not be trusted to make this switch: it is wired here, once, at
/// the composition root, next to the rest of `GovernorHeartRateSource` wiring.
private struct HeartRateSourceWiring: ViewModifier {
    @ObservedObject var client: FitShowTreadmillClient
    let runner: ProgramRunner
    let recorder: SessionRecorder
    let watchHeartRate: WatchHeartRateManager

    /// Held strongly here: `ProgramRunner` keeps its heart-rate source as a
    /// `weak` reference (by design — see `GovernorHeartRateSource`'s doc), so
    /// something has to own the demo adapter for as long as demo mode is
    /// selected, or it is deallocated the instant it is bound and every
    /// subsequent read silently returns 0.
    @State private var demoSource: DemoHeartRateSource?

    func body(content: Content) -> some View {
        content
            .task { bind() }
            .onChange(of: client.demoMode) { _, _ in bind() }
    }

    private func bind() {
        guard client.demoMode else {
            demoSource = nil
            runner.bindHeartRateControl(source: watchHeartRate, basis: recorder)
            return
        }
        let source = demoSource ?? DemoHeartRateSource(client: client)
        demoSource = source
        runner.bindHeartRateControl(source: source, basis: recorder)
    }
}
