// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Kft. — https://treadpilot.app

import SwiftData
import SwiftUI

/// Az edzés Health-mentési doboza — az edzés végi összefoglaló és az
/// előzmények részletnézete közösen használja. Már mentett edzésnél jelzést,
/// nem mentettnél mentés-gombot mutat, így a sikertelen (vagy kimaradt)
/// szinkron utólag bármikor pótolható.
struct HealthSyncSection: View {
    let session: WorkoutSessionRecord
    var showsAutoSaveToggle = true

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var exporter: HealthKitExporter

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BrandEyebrow("Apple Health")

            // A session saját jelzői az elsődlegesek — az exporter állapota
            // csak a folyamatban lévő/sikertelen mentést árnyalja.
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
            // Előző edzésből maradt állapot törlése (folyamatban lévőt nem bánt).
            if !session.healthKitSynced { exporter.resetState() }
        }
    }

    /// Az exporter globális állapota csak akkor tartozik ide, ha éppen ezt a
    /// sessiont menti — másik edzés mentése ne látszódjon ebben a dobozban.
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
