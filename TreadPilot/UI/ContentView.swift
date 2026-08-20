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
    @AppStorage("disclaimer.accepted") private var disclaimerAccepted = false
    @State private var showDisclaimer = false

    var body: some View {
        NavigationStack {
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
                    // Aktív edzésnél az edzésképernyő, egyébként a kezdőképernyő
                    // (manuális/program indítás, programok, előzmények, bontás).
                    if isWorkoutActive {
                        DashboardView(deviceName: name)
                    } else {
                        HomeView(deviceName: name)
                    }
                }
            }
        }
        .tint(Brand.accent)
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showDisclaimer) {
            DisclaimerView {
                disclaimerAccepted = true
                showDisclaimer = false
            }
            .interactiveDismissDisabled()
        }
        .onAppear {
            showDisclaimer = !disclaimerAccepted
            recorder.bind(client: client, runner: runner, context: modelContext)
            recorder.profileProvider = { [weak profileStore] in
                profileStore?.effectiveProfile ?? .fallback
            }
            recorder.externalHeartRateProvider = { [weak watchHeartRate] in
                watchHeartRate?.freshHeartRate() ?? 0
            }
            recorder.onWorkoutEnded = { [weak watchHeartRate] in
                // A rövid, eldobott edzésnél is le kell zárni a Watch-workoutot.
                watchHeartRate?.endWatchWorkout()
            }
        }
        .onReceive(recorder.$activeSession) { session in
            // A pad edzésének indulásakor a Watch-app is induljon (ha van Watch).
            // Demó edzés nem indít Watch-workoutot.
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
        // A riasztás itt él, nem az edzésképernyőn: kapcsolatvesztéskor a
        // dashboard kikerül a hierarchiából, de a figyelmeztetésnek pont akkor
        // kell látszania. Csak a felhasználó nyugtázása zárja be.
        .alert("Connection lost while running!",
               isPresented: $client.lostConnectionWhileRunning) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(String(localized: "The belt may keep running at the last set speed. Use the treadmill's Stop button or the safety key!"))
        }
    }

    /// Aktív az edzés, ha a szalag nem áll, vagy a programfuttató dolgozik
    /// (élesítve / padra várva / fut / felfüggesztve).
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
