import SwiftData
import SwiftUI

/// Edzés végi összefoglaló — a rögzítő a session lezárásakor nyitja fel.
struct SummaryView: View {
    let session: WorkoutSessionRecord
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var exporter: HealthKitExporter

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("EDZÉS KÉSZ").tracking(1.5)
                    }
                    .font(Brand.display(14, .semibold))
                    .foregroundStyle(Brand.accent)

                    SessionStatsGrid(session: session)

                    healthSection

                    Button {
                        dismiss()
                    } label: {
                        Text("BEZÁRÁS").tracking(1.5)
                    }
                    .buttonStyle(BrandStrokeStyle())
                }
                .padding(20)
            }
            .background(Brand.bgDeep)
            .toolbar {
                ToolbarItem(placement: .principal) { BrandWordmark() }
            }
            .toolbarBackground(Brand.bgDeep, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // Előző edzésből maradt állapot törlése (folyamatban lévőt nem bánt).
            if !session.healthKitSynced { exporter.resetState() }
        }
    }

    private var healthSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BrandEyebrow("Apple Health")

            // A session saját jelzői az elsődlegesek — az exporter állapota
            // csak a folyamatban lévő/sikertelen mentést árnyalja.
            if session.healthKitSynced {
                HStack(spacing: 6) {
                    Image(systemName: "heart.fill")
                    Text("MENTVE A HEALTHBE").tracking(1.2)
                }
                .font(Brand.display(12, .semibold))
                .foregroundStyle(Brand.accent)
            } else if session.watchProvidedHeartRate {
                HStack(spacing: 6) {
                    Image(systemName: "applewatch")
                    Text("A WATCH MENTI A HEALTHBE").tracking(1.2)
                }
                .font(Brand.display(12, .semibold))
                .foregroundStyle(Brand.accent)
            } else {
                switch exporter.state {
                case .saving:
                    HStack(spacing: 10) {
                        ProgressView().tint(Brand.accent)
                        Text("MENTÉS…").tracking(1.2)
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

            Toggle(isOn: $exporter.autoSave) {
                Text("Automatikus mentés minden edzés után")
                    .font(.subheadline)
                    .foregroundStyle(Brand.fgDim)
            }
            .tint(Brand.accent)
        }
        .brandBox()
    }

    private var saveButton: some View {
        Button {
            Task {
                await exporter.export(session)
                try? modelContext.save()
            }
        } label: {
            HStack { Image(systemName: "heart"); Text("MENTÉS A HEALTHBE").tracking(1.5) }
        }
        .buttonStyle(BrandStrokeStyle(color: Brand.accent))
    }
}
