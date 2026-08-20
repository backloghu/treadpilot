import SwiftData
import SwiftUI

/// Edzés végi összefoglaló — a rögzítő a session lezárásakor nyitja fel.
struct SummaryView: View {
    let session: WorkoutSessionRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("WORKOUT COMPLETE").tracking(1.5)
                    }
                    .font(Brand.display(14, .semibold))
                    .foregroundStyle(Brand.accent)

                    SessionStatsGrid(session: session)

                    HealthSyncSection(session: session)

                    Button {
                        dismiss()
                    } label: {
                        Text("CLOSE").tracking(1.5)
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
    }
}
