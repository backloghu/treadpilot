// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import Charts
import SwiftData
import SwiftUI

struct HistoryView: View {
    // Closed workouts only: the session currently running cannot be deleted or
    // opened from here (deleting the recorder's live model would crash).
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
                    Text("No workouts recorded yet.")
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
                Text("HISTORY")
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
                    // Not in Health yet — can be completed from the detail view.
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
                SessionStopReasonBanners(session: session)

                SessionStatsGrid(session: session)

                // Retroactive Health sync: if the end-of-workout save failed (or
                // was turned off), it can be completed from here at any time.
                HealthSyncSection(session: session, showsAutoSaveToggle: false)

                // For a long workout the sample series is thinned out so the
                // chart is not built from thousands of points.
                let samples = downsampled(session.sortedSamples, to: 600)
                if samples.count > 1 {
                    VStack(alignment: .leading, spacing: 10) {
                        BrandEyebrow(String(localized: "Speed (km/h)"))
                        Chart(samples, id: \.offsetSeconds) { sample in
                            LineMark(
                                x: .value("s", sample.offsetSeconds),
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
                            BrandEyebrow(String(localized: "Heart rate (bpm)"))
                            // The band behind the line, drawn first so the trace sits on
                            // top of it — "so one screenshot shows whether the governor
                            // held what it promised" (spec section 4). `RectangleMark`,
                            // not an area shared with the line: it draws each run as its
                            // own independent shape, so a stretch with no band (a fixed
                            // segment, a hand-back) is a real gap and not a line
                            // interpolated straight across it.
                            Chart {
                                ForEach(TargetBandChart.runs(in: samples), id: \.startOffsetSeconds) { run in
                                    RectangleMark(
                                        xStart: .value("s", run.startOffsetSeconds),
                                        xEnd: .value("s", run.endOffsetSeconds),
                                        yStart: .value("bpm", run.lowBpm),
                                        yEnd: .value("bpm", run.highBpm)
                                    )
                                    .foregroundStyle(Brand.accent.opacity(0.15))
                                }
                                ForEach(samples.filter { $0.heartRate > 0 }, id: \.offsetSeconds) { sample in
                                    LineMark(
                                        x: .value("s", sample.offsetSeconds),
                                        y: .value("bpm", sample.heartRate)
                                    )
                                    .foregroundStyle(Brand.danger)
                                    .interpolationMethod(.monotone)
                                }
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

/// The 97% ceiling's own reason, styled identically to `SafetyStopBanner`
/// (`Theme.swift`) so the two read as one family wherever they appear
/// together. `DashboardView` renders it live from the session's own stop
/// reason (finding 142), and `SessionStopReasonBanners` below pulls it into
/// the summary sheet and the history detail too (finding 138), where it has
/// to survive past the live dashboard's own lifetime.
struct HeartRateCeilingStopBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "heart.slash.circle.fill")
            Text(Safety.heartRateCeilingStoppedTheBelt)
        }
        .font(Brand.display(12, .semibold))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Brand.danger, in: RoundedRectangle(cornerRadius: Brand.radius))
    }
}

/// The durable stop facts (findings 138/139), shown wherever a workout is
/// reviewed after the fact — the end-of-workout summary sheet and this history
/// detail — since both live banners this mirrors (`DashboardView`'s) unmount
/// with the screen that produced them. Reads `session.stopReason` /
/// `session.beltDidNotStop` rather than any live client or runner state, so it
/// renders identically whether the session closed a second ago or a month ago.
struct SessionStopReasonBanners: View {
    let session: WorkoutSessionRecord

    var body: some View {
        // A failure to stop first: it is the more serious fact, and — for
        // `SummaryView` — the one finding 139 requires cannot be hidden behind
        // a "workout complete" checkmark.
        VStack(spacing: 8) {
            if session.beltDidNotStop {
                SafetyStopBanner()
            }
            if session.stopReason == .heartRateCeiling {
                HeartRateCeilingStopBanner()
            }
        }
    }
}

/// The statistics grid shared by the summary and the detail view.
struct SessionStatsGrid: View {
    let session: WorkoutSessionRecord

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                cell(String(localized: "Moving time"), SessionFormat.duration(session.movingSeconds))
                cell(String(localized: "Distance"), String(format: "%.2f km", session.distanceKm))
            }
            GridRow {
                cell(String(localized: "Avg speed"), String(format: "%.1f km/h", session.avgSpeedKmh))
                cell(String(localized: "Max speed"), String(format: "%.1f km/h", session.maxSpeedKmh))
            }
            GridRow {
                cell(String(localized: "Calories"), "\(session.displayKcal) kcal")
                cell(String(localized: "Elevation gain"), String(format: "%.0f m", session.elevationGainM))
            }
            GridRow {
                cell(String(localized: "Avg heart rate"),
                     session.avgHeartRate > 0 ? SessionFormat.bpm(session.avgHeartRate) : "–")
                cell(String(localized: "Max heart rate"),
                     session.maxHeartRate > 0 ? SessionFormat.bpm(session.maxHeartRate) : "–")
            }
            GridRow {
                // Spans both columns so it reads as one line about the heart-rate
                // cells above it, not a lone half-width cell with dead space beside it.
                cell(String(localized: "Watch heart rate coverage"), watchHeartRateCoverageText)
                    .gridCellColumns(2)
            }
            if session.pausedSeconds > 0 {
                GridRow {
                    cell(String(localized: "Paused"), SessionFormat.duration(session.pausedSeconds))
                    cell(String(localized: "Program"), session.programName ?? String(localized: "Manual"))
                }
            }
        }
    }

    /// The model already resolved the rounding rules (`watchHeartRateCoverageWholePercent`).
    private var watchHeartRateCoverageText: String {
        session.watchHeartRateCoverageWholePercent.map { "\($0)%" } ?? "–"
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
    /// Until the app's own calorie calculation is available, show the treadmill's value.
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

    /// The one call site for "N bpm", so Dashboard, History and Profile render
    /// the unit identically and the catalog gains no key beyond `%lld bpm`.
    static func bpm(_ value: Int) -> String {
        String(localized: "\(value) bpm")
    }
}

/// One contiguous stretch of samples that carried the same target band.
struct TargetBandRun: Equatable {
    let startOffsetSeconds: Int
    let endOffsetSeconds: Int
    let lowBpm: Int
    let highBpm: Int
}

/// Turns a sample series into the runs `SessionDetailView` draws behind the
/// heart-rate chart (spec section 4, "Recording and review"). Pure and
/// SwiftUI-free, so the grouping is testable without a chart.
enum TargetBandChart {
    /// Splits on every second with no band and on every change of the band
    /// itself, so a `RectangleMark` per run has a real gap for a fixed
    /// segment or a hand-back instead of one shape stretched across it — and
    /// a workout that was never governed returns no runs at all.
    static func runs(in samples: [WorkoutSampleRecord]) -> [TargetBandRun] {
        var runs: [TargetBandRun] = []
        var current: TargetBandRun?
        for sample in samples {
            guard sample.hasTargetHeartRateBand else {
                if let run = current { runs.append(run) }
                current = nil
                continue
            }
            if let run = current, run.lowBpm == sample.targetHrLow, run.highBpm == sample.targetHrHigh {
                current = TargetBandRun(startOffsetSeconds: run.startOffsetSeconds,
                                        endOffsetSeconds: sample.offsetSeconds,
                                        lowBpm: run.lowBpm, highBpm: run.highBpm)
            } else {
                if let run = current { runs.append(run) }
                current = TargetBandRun(startOffsetSeconds: sample.offsetSeconds,
                                        endOffsetSeconds: sample.offsetSeconds,
                                        lowBpm: sample.targetHrLow, highBpm: sample.targetHrHigh)
            }
        }
        if let run = current { runs.append(run) }
        return runs
    }
}
