// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var client: FitShowTreadmillClient
    @EnvironmentObject private var runner: ProgramRunner
    @EnvironmentObject private var recorder: SessionRecorder
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var exporter: HealthKitExporter
    @EnvironmentObject private var watchHeartRate: WatchHeartRateManager
    @Environment(\.modelContext) private var modelContext
    /// Finding 132: versioned, not a plain `Bool`, so a disclaimer revision that
    /// needs re-consent (the medical-device sentence, `DisclaimerView
    /// .currentVersion`) is reachable for everyone already running the app —
    /// including a user upgrading from 1.0, whose old `disclaimer.accepted` Bool
    /// lived at a different key and is simply left behind: this one defaults to
    /// 0 for them exactly as it does for a fresh install, so they see the notice
    /// again once, same as anyone who has never accepted the current revision.
    @AppStorage("disclaimer.acceptedVersion") private var disclaimerAcceptedVersion = 0
    @State private var showDisclaimer = false

    var body: some View {
        NavigationStack {
            // Finding 121: hoisted above the phase switch below, so it renders in
            // every phase rather than only the two screens that require a ready
            // connection. The producer (`FitShowTreadmillClient.stopNotObeyed`)
            // is set from disconnect, from a failed reconnect and from radio
            // loss — every one of which lands in the idle or bluetooth-off
            // phase, i.e. the scan screen or the connecting spinner, neither of
            // which used to render it: the one visible failure in this feature
            // was invisible on exactly the screens it is raised from.
            VStack(spacing: 0) {
                if client.stopNotObeyed {
                    SafetyStopBanner()
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                }
                Group {
                    switch client.phase {
                    case .idle, .scanning, .bluetoothOff:
                        ScanView()
                    case .connecting(let name), .preparing(let name):
                        VStack(spacing: 20) {
                            ProgressView()
                                .tint(Brand.accent)
                            Text("CONNECTING: \(name.uppercased())…")
                                .font(Brand.display(12, .medium))
                                .tracking(1.5)
                                .foregroundStyle(Brand.fgDim)
                            Button { client.disconnect() } label: {
                                Text("CANCEL").tracking(1.5)
                            }
                            .buttonStyle(BrandStrokeStyle())
                            .frame(width: 160)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Brand.bgDeep)
                        .toolbar {
                            ToolbarItem(placement: .principal) { BrandWordmark() }
                        }
                    case .ready(let name):
                        // The workout screen during an active workout, otherwise the home
                        // screen (manual/program start, programs, history, disconnect).
                        if isWorkoutActive {
                            DashboardView(deviceName: name)
                        } else {
                            HomeView(deviceName: name)
                        }
                    }
                }
            }
            .background(Brand.bgDeep)
        }
        .tint(Brand.accent)
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showDisclaimer) {
            DisclaimerView {
                disclaimerAcceptedVersion = DisclaimerView.currentVersion
                showDisclaimer = false
            }
            .interactiveDismissDisabled()
        }
        .onAppear {
            showDisclaimer = disclaimerAcceptedVersion < DisclaimerView.currentVersion
            recorder.bind(client: client, runner: runner, context: modelContext)
            recorder.profileProvider = { [weak profileStore] in
                profileStore?.effectiveProfile ?? .fallback
            }
            recorder.externalHeartRateProvider = { [weak watchHeartRate] in
                watchHeartRate?.freshHeartRate() ?? 0
            }
            recorder.onWorkoutEnded = { [weak watchHeartRate] in
                // The Watch workout must be closed even for a short, discarded workout.
                watchHeartRate?.endWatchWorkout()
            }
        }
        .onReceive(recorder.$activeSession) { session in
            // When the treadmill workout starts, start the Watch app too (if there
            // is a Watch). A demo workout does not start a Watch workout.
            guard session != nil, !client.demoMode else { return }
            Task { await watchHeartRate.startWatchWorkout() }
        }
        .sheet(item: $recorder.finishedSession) { session in
            SummaryView(session: session)
        }
        .onReceive(recorder.$finishedSession) { session in
            guard let session else { return }
            guard exporter.autoSave, !session.healthKitSynced, !session.isDemo else { return }
            Task {
                await exporter.export(session)
                try? modelContext.save()
            }
        }
        // The alert lives here rather than on the workout screen: on connection
        // loss the dashboard leaves the hierarchy, but that is exactly when the
        // warning has to be visible. Only the user's acknowledgement dismisses it.
        .alert("Connection lost while running!",
               isPresented: $client.lostConnectionWhileRunning) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(String(localized: "The belt may keep running at the last set speed. Use the treadmill's Stop button or the safety key!"))
        }
    }

    /// The workout is active if the belt is not stopped, or the program runner is
    /// working (armed / waiting for the treadmill / running / suspended).
    private var isWorkoutActive: Bool {
        switch runner.runnerState {
        case .armed, .waitingForBelt, .running, .suspended:
            return true
        case .idle, .finished:
            break
        }
        switch client.state.status {
        case .idle, .end:
            return false
        default:
            return true
        }
    }
}
