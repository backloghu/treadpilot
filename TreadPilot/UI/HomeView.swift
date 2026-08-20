// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import SwiftData
import SwiftUI

/// Home screen after connecting: a manual workout or a workout program starts
/// from here, and program management, history, the profile and disconnecting are
/// reachable here. The workout screen is only shown during an active workout.
struct HomeView: View {
    let deviceName: String

    @EnvironmentObject private var client: FitShowTreadmillClient
    @EnvironmentObject private var runner: ProgramRunner
    @Query(sort: \CustomProgram.createdAt) private var customPrograms: [CustomProgram]
    @State private var selectedProgramId: UUID = WorkoutProgram.builtIn[0].id
    @State private var showManualStartConfirmation = false
    @State private var showProgramStartConfirmation = false

    private var programOptions: [WorkoutProgram] {
        WorkoutProgram.builtIn + customPrograms.map(\.asWorkoutProgram)
    }

    private var selectedProgram: WorkoutProgram {
        programOptions.first(where: { $0.id == selectedProgramId }) ?? WorkoutProgram.builtIn[0]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                deviceBox
                manualStartBox
                programBox
                navigationRow

                Button {
                    runner.stop()
                    client.disconnect()
                } label: {
                    Text("DISCONNECT").tracking(1.5)
                }
                .buttonStyle(BrandStrokeStyle(color: Brand.fgDim))
            }
            .padding(20)
        }
        .background(Brand.bgDeep)
        .toolbar {
            ToolbarItem(placement: .principal) { BrandWordmark() }
        }
        .toolbarBackground(Brand.bgDeep, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .onAppear {
            // Do not let a finished program's leftovers live on on the home screen.
            if case .finished = runner.runnerState { runner.stop() }
        }
        .confirmationDialog("Start the belt?",
                            isPresented: $showManualStartConfirmation,
                            titleVisibility: .visible) {
            Button("Start at \(client.targetSpeedKmh, specifier: "%.1f") km/h") {
                client.userConfirmedStart()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Safety.standClear)
        }
        .confirmationDialog("Start a program?",
                            isPresented: $showProgramStartConfirmation,
                            titleVisibility: .visible) {
            Button("Start \(selectedProgram.name)") {
                runner.arm(selectedProgram, on: client)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let first = selectedProgram.segments.first {
                // One sentence from one key: this gives the translator context,
                // and the word order can be rearranged freely per language.
                Text("The belt starts on its own after a \(ProgramRunner.armCountdownSeconds)-second countdown. First segment: \(first.targetSpeedKmh, specifier: "%.1f") km/h at \(first.targetIncline)% incline. \(Safety.standClear)")
            }
        }
    }

    private var deviceBox: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                BrandEyebrow(String(localized: "Connected"))
                Text(deviceName)
                    .font(Brand.display(16, .semibold))
                    .foregroundStyle(.white)
            }
            Spacer()
            if !client.limits.fromDevice {
                Text("DEFAULT LIMITS")
                    .font(Brand.display(9, .medium))
                    .tracking(1.2)
                    .foregroundStyle(Brand.grey)
            }
        }
        .brandBox()
    }

    private var manualStartBox: some View {
        VStack(alignment: .leading, spacing: 12) {
            BrandEyebrow(String(localized: "Manual workout"))
            Text("You set the speed and the incline during the workout.")
                .font(.footnote)
                .foregroundStyle(Brand.fgDim)
            Button {
                showManualStartConfirmation = true
            } label: {
                HStack { Image(systemName: "play.fill"); Text("MANUAL START").tracking(1.5) }
            }
            .buttonStyle(BrandCTAStyle())
        }
        .brandBox()
    }

    private var programBox: some View {
        VStack(alignment: .leading, spacing: 12) {
            BrandEyebrow(String(localized: "Program"))
            Menu {
                ForEach(programOptions) { program in
                    Button(program.name) { selectedProgramId = program.id }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(selectedProgram.name)
                        .font(Brand.display(14, .semibold))
                        .foregroundStyle(Brand.accent)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Brand.accent)
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(Brand.bgElev2, in: RoundedRectangle(cornerRadius: Brand.radius))
                .overlay(RoundedRectangle(cornerRadius: Brand.radius).stroke(Brand.gridLine))
            }
            Text((selectedProgram.hasEstimatedDuration ? "~" : "")
                 + SessionFormat.duration(Int(selectedProgram.totalDuration))
                 // The segment count is a separate key, with a plural variation
                 // in the String Catalog — so it never reads "1 segments".
                 + " · " + String(localized: "\(selectedProgram.segments.count) segments")
                 + String(format: " · %.2f km", selectedProgram.totalDistanceKm)
                 + String(format: String(localized: " · %.0f m elevation gain"), selectedProgram.totalElevationGainM)
                 + String(format: " · ⌀ %.1f km/h", selectedProgram.averageSpeedKmh))
                .font(.caption)
                .foregroundStyle(Brand.grey)
            Button {
                showProgramStartConfirmation = true
            } label: {
                HStack { Image(systemName: "list.bullet"); Text("START PROGRAM").tracking(1.5) }
            }
            .buttonStyle(BrandStrokeStyle(color: Brand.accent))
        }
        .brandBox()
    }

    private var navigationRow: some View {
        HStack(spacing: 10) {
            navBox(String(localized: "History"), icon: "clock.arrow.circlepath") { HistoryView() }
            navBox(String(localized: "Programs"), icon: "list.bullet.rectangle") { ProgramListView() }
            navBox(String(localized: "Profile"), icon: "person.crop.circle") { ProfileView() }
        }
    }

    private func navBox<Destination: View>(_ title: String, icon: String,
                                           @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(Brand.accent)
                Text(title.uppercased())
                    .font(Brand.display(9, .semibold))
                    .tracking(1)
                    .foregroundStyle(Brand.fgMid)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Brand.bgElev1, in: RoundedRectangle(cornerRadius: Brand.radius))
            .overlay(RoundedRectangle(cornerRadius: Brand.radius).stroke(Brand.gridLine))
        }
    }
}
