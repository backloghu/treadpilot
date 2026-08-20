// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject private var workout: WatchWorkoutManager

    var body: some View {
        VStack(spacing: 8) {
            Text(workout.isActive && workout.heartRate > 0 ? "\(workout.heartRate)" : "–")
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .foregroundStyle(.yellow)
                .contentTransition(.numericText())
            Text("BPM")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let status = workout.statusText {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button {
                if workout.isActive {
                    workout.end()
                } else {
                    workout.start()
                }
            } label: {
                Text(workout.isActive ? "End" : "Start")
            }
            .tint(workout.isActive ? .red : .yellow)
        }
        .task {
            #if DEBUG
            // In demo mode there is no real sensor, so we do not ask for
            // permission either — the system dialog would otherwise cover
            // the screenshot.
            if workout.startSampleState() { return }
            #endif
            await workout.requestAuthorization()
        }
    }
}
