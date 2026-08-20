import Charts
import SwiftData
import SwiftUI

struct HistoryView: View {
    // Csak a lezárt edzések: az épp futó session nem törölhető/nyitható meg
    // innen (a rögzítő élő modelljének törlése összeomlást okozna).
    @Query(filter: #Predicate<WorkoutSessionRecord> { $0.endedAt != nil },
           sort: \WorkoutSessionRecord.startedAt, order: .reverse)
    private var sessions: [WorkoutSessionRecord]
    @Environment(\.modelContext) private var context

    var body: some View {
        Group {
            if sessions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "figure.run")
                        .font(.system(size: 40))
                        .foregroundStyle(Brand.grey)
                    Text("Még nincs rögzített edzés.")
                        .font(.subheadline)
                        .foregroundStyle(Brand.fgDim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Brand.bgDeep)
            } else {
                List {
                    ForEach(sessions) { session in
                        NavigationLink {
                            SessionDetailView(session: session)
                        } label: {
                            SessionRow(session: session)
                        }
                        .listRowBackground(Brand.bgElev1)
                        .listRowSeparatorTint(Brand.gridLine)
                    }
                    .onDelete { offsets in
                        for index in offsets { context.delete(sessions[index]) }
                        try? context.save()
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Brand.bgDeep)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("ELŐZMÉNYEK")
                    .font(Brand.display(12, .semibold))
                    .tracking(1.5)
                    .foregroundStyle(Brand.fgMid)
            }
        }
        .toolbarBackground(Brand.bgDeep, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

private struct SessionRow: View {
    let session: WorkoutSessionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(session.startedAt, format: .dateTime.year().month().day().hour().minute())
                    .font(Brand.display(14, .semibold))
                    .foregroundStyle(.white)
                Spacer()
                if session.healthKitSynced {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(Brand.accent)
                } else if !session.isDemo {
                    // Még nincs a Healthben — a részletnézetből pótolható.
                    Image(systemName: "heart")
                        .font(.caption2)
                        .foregroundStyle(Brand.grey)
                }
                if let program = session.programName {
                    Text(program)
                        .font(.caption)
                        .foregroundStyle(Brand.accent)
                }
            }
            HStack(spacing: 14) {
                metric("⏱", SessionFormat.duration(session.movingSeconds))
                metric("📏", String(format: "%.2f km", session.distanceKm))
                metric("⌀", String(format: "%.1f km/h", session.avgSpeedKmh))
                metric("🔥", "\(session.displayKcal) kcal")
            }
        }
        .padding(.vertical, 4)
    }

    private func metric(_ icon: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(icon).font(.caption2)
            Text(value)
                .font(Brand.display(12, .regular))
                .foregroundStyle(Brand.fgDim)
        }
    }
}

struct SessionDetailView: View {
    let session: WorkoutSessionRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SessionStatsGrid(session: session)

                // Utólagos Health-szinkron: ha az edzés végi mentés nem
                // sikerült (vagy ki volt kapcsolva), innen bármikor pótolható.
                HealthSyncSection(session: session, showsAutoSaveToggle: false)

                // Hosszú edzésnél ritkított mintasor, hogy a grafikon ne
                // épüljön több ezer pontból.
                let samples = downsampled(session.sortedSamples, to: 600)
                if samples.count > 1 {
                    VStack(alignment: .leading, spacing: 10) {
                        BrandEyebrow("Sebesség (km/h)")
                        Chart(samples, id: \.offsetSeconds) { sample in
                            LineMark(
                                x: .value("mp", sample.offsetSeconds),
                                y: .value("km/h", sample.speedKmh)
                            )
                            .foregroundStyle(Brand.accent)
                            .interpolationMethod(.monotone)
                        }
                        .chartXAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Brand.gridLine); AxisValueLabel().foregroundStyle(Brand.grey) } }
                        .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Brand.gridLine); AxisValueLabel().foregroundStyle(Brand.grey) } }
                        .frame(height: 160)
                    }
                    .brandBox()

                    if samples.contains(where: { $0.heartRate > 0 }) {
                        VStack(alignment: .leading, spacing: 10) {
                            BrandEyebrow("Pulzus (bpm)")
                            Chart(samples.filter { $0.heartRate > 0 }, id: \.offsetSeconds) { sample in
                                LineMark(
                                    x: .value("mp", sample.offsetSeconds),
                                    y: .value("bpm", sample.heartRate)
                                )
                                .foregroundStyle(Brand.danger)
                                .interpolationMethod(.monotone)
                            }
                            .chartXAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Brand.gridLine); AxisValueLabel().foregroundStyle(Brand.grey) } }
                            .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Brand.gridLine); AxisValueLabel().foregroundStyle(Brand.grey) } }
                            .frame(height: 160)
                        }
                        .brandBox()
                    }
                }
            }
            .padding(20)
        }
        .background(Brand.bgDeep)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(session.startedAt, format: .dateTime.month().day().hour().minute())
                    .font(Brand.display(12, .semibold))
                    .tracking(1.5)
                    .foregroundStyle(Brand.fgMid)
            }
        }
        .toolbarBackground(Brand.bgDeep, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private func downsampled(_ samples: [WorkoutSampleRecord], to limit: Int) -> [WorkoutSampleRecord] {
        guard samples.count > limit else { return samples }
        let step = samples.count / limit + 1
        return samples.enumerated().compactMap { $0.offset % step == 0 ? $0.element : nil }
    }
}

/// Az összefoglaló és a részletnézet közös statisztika-rácsa.
struct SessionStatsGrid: View {
    let session: WorkoutSessionRecord

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                cell("Mozgásidő", SessionFormat.duration(session.movingSeconds))
                cell("Táv", String(format: "%.2f km", session.distanceKm))
            }
            GridRow {
                cell("Átlagsebesség", String(format: "%.1f km/h", session.avgSpeedKmh))
                cell("Max sebesség", String(format: "%.1f km/h", session.maxSpeedKmh))
            }
            GridRow {
                cell("Kalória", "\(session.displayKcal) kcal")
                cell("Átlagpulzus", session.avgHeartRate > 0 ? "\(session.avgHeartRate) bpm" : "–")
            }
            GridRow {
                cell("Szint fel", String(format: "%.0f m", session.elevationGainM))
                cell("Max pulzus", session.maxHeartRate > 0 ? "\(session.maxHeartRate) bpm" : "–")
            }
            if session.pausedSeconds > 0 {
                GridRow {
                    cell("Szünet", SessionFormat.duration(session.pausedSeconds))
                    cell("Program", session.programName ?? "kézi")
                }
            }
        }
    }

    private func cell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            BrandEyebrow(title)
            Text(value)
                .font(Brand.display(18, .semibold))
                .foregroundStyle(.white)
        }
        .brandBox(padding: 12)
    }
}

extension WorkoutSessionRecord {
    /// Amíg nincs saját kalóriaszámítás, a pad értékét mutatjuk.
    var displayKcal: Int {
        computedKcal > 0 ? Int(computedKcal.rounded()) : padKcal
    }
}

enum SessionFormat {
    static func duration(_ seconds: Int) -> String {
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
