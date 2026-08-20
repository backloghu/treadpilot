// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import SwiftData
import SwiftUI

/// The workout's Health-save box — shared by the end-of-workout summary and the
/// history detail view. For an already saved workout it shows an indicator, for
/// an unsaved one a save button, so a failed (or missed) sync can be completed
/// afterwards at any time.
struct HealthSyncSection: View {
    let session: WorkoutSessionRecord
    var showsAutoSaveToggle = true

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var exporter: HealthKitExporter

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BrandEyebrow("Apple Health")

            // The session's own flags take precedence — the exporter's state only
            // qualifies an in-progress or failed save.
            if session.isDemo {
                HStack(spacing: 6) {
                    Image(systemName: "play.rectangle")
                    Text("DEMO WORKOUT — NOT SAVED TO HEALTH").tracking(1)
                }
                .font(Brand.display(11, .semibold))
                .foregroundStyle(Brand.grey)
            } else if session.healthKitSynced {
                HStack(spacing: 6) {
                    Image(systemName: "heart.fill")
                    Text("SAVED TO HEALTH").tracking(1.2)
                }
                .font(Brand.display(12, .semibold))
                .foregroundStyle(Brand.accent)
            } else {
                switch stateForThisSession {
                case .saving:
                    HStack(spacing: 10) {
                        ProgressView().tint(Brand.accent)
                        Text("SAVING…").tracking(1.2)
                            .font(Brand.display(12, .semibold))
                            .foregroundStyle(Brand.fgMid)
                    }
                case .failed(let message):
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Brand.danger)
                    saveButton
                case .idle, .saved:
                    saveButton
                }
            }

            if showsAutoSaveToggle {
                Toggle(isOn: $exporter.autoSave) {
                    Text("Automatically save after every workout")
                        .font(.subheadline)
                        .foregroundStyle(Brand.fgDim)
                }
                .tint(Brand.accent)
            }
        }
        .brandBox()
        .onAppear {
            // Clear state left over from a previous workout (leaves an in-progress one alone).
            if !session.healthKitSynced { exporter.resetState() }
        }
    }

    /// The exporter's global state only belongs here if it is saving this very
    /// session — saving another workout must not show up in this box.
    private var stateForThisSession: HealthKitExporter.ExportState {
        exporter.currentSessionID == session.persistentModelID ? exporter.state : .idle
    }

    private var saveButton: some View {
        Button {
            Task {
                await exporter.export(session)
                try? modelContext.save()
            }
        } label: {
            HStack { Image(systemName: "heart"); Text("SAVE TO HEALTH").tracking(1.5) }
        }
        .buttonStyle(BrandStrokeStyle(color: Brand.accent))
    }
}
