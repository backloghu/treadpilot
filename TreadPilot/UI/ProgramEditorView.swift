// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import SwiftData
import SwiftUI

/// Editing a custom program: name, segment ordering, adding, deleting.
struct ProgramEditorView: View {
    @Bindable var program: CustomProgram
    @Environment(\.modelContext) private var context

    /// The editor uses the treadmill's default limits as bounds; when running,
    /// the client also clamps to the actual device limits.
    private let limits = TreadmillLimits()

    var body: some View {
        List {
            Section {
                TextField("Program name", text: $program.name)
                    .font(Brand.display(15, .semibold))
                    .foregroundStyle(.white)
                    .listRowBackground(Brand.bgElev1)
            } header: {
                BrandEyebrow(String(localized: "Name"))
            }

            Section {
                summaryRow
                    .listRowBackground(Brand.bgElev1)
            } header: {
                BrandEyebrow(String(localized: "Summary"))
            }

            Section {
                ForEach(program.sortedSegments) { segment in
                    NavigationLink {
                        SegmentEditorView(segment: segment, limits: limits)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(segment.name)
                                    .font(Brand.display(14, .semibold))
                                    .foregroundStyle(.white)
                                Text(SegmentFormat.goal(segment.goal) + " · "
                                     + SegmentFormat.target(speedKmh: segment.targetSpeedKmh,
                                                             incline: segment.targetIncline))
                                    .font(.caption)
                                    .foregroundStyle(Brand.grey)
                            }
                        }
                    }
                    .listRowBackground(Brand.bgElev1)
                    .listRowSeparatorTint(Brand.gridLine)
                    .contextMenu {
                        Button {
                            duplicate(segment)
                        } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                    }
                }
                .onMove(perform: move)
                .onDelete(perform: delete)

                Button {
                    addSegment()
                } label: {
                    Label {
                        Text("NEW SEGMENT").tracking(1.5).font(Brand.display(13, .semibold))
                    } icon: {
                        Image(systemName: "plus")
                    }
                    .foregroundStyle(Brand.accent)
                }
                .listRowBackground(Brand.bgElev1)
            } header: {
                BrandEyebrow(String(localized: "Segments"))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Brand.bgDeep)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("EDIT")
                    .font(Brand.display(12, .semibold))
                    .tracking(1.5)
                    .foregroundStyle(Brand.fgMid)
            }
            ToolbarItem(placement: .primaryAction) { EditButton() }
        }
        .toolbarBackground(Brand.bgDeep, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .onDisappear { try? context.save() }
    }

    /// Live-updating program totals: duration, distance, elevation, average speed.
    /// The distance total is always exact; the time total is only a projection
    /// whenever any segment's duration is derived rather than commanded, so it
    /// gets the `~` prefix (spec: "exact distance, ~ prefixed time").
    private var summaryRow: some View {
        let workout = program.asWorkoutProgram
        let timeValue = SessionFormat.duration(Int(workout.totalDuration))
        return HStack(spacing: 0) {
            summaryCell(String(localized: "Time"), workout.hasEstimatedDuration ? "~" + timeValue : timeValue)
            summaryCell(String(localized: "Distance"), String(format: "%.2f km", workout.totalDistanceKm))
            summaryCell(String(localized: "Elevation gain"), String(format: "%.0f m", workout.totalElevationGainM))
            summaryCell(String(localized: "Avg"), String(format: "%.1f km/h", workout.averageSpeedKmh))
        }
        .padding(.vertical, 4)
    }

    private func summaryCell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(Brand.display(9, .medium))
                .tracking(1.2)
                .foregroundStyle(Brand.grey)
            Text(value)
                .font(Brand.display(13, .semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func addSegment() {
        let segment = CustomSegmentRecord(
            orderIndex: (program.segments.map(\.orderIndex).max() ?? -1) + 1,
            name: String(localized: "Segment \(program.segments.count + 1)"),
            durationSeconds: 300,
            targetSpeedKmh: 5.0,
            targetIncline: 0
        )
        segment.program = program
        program.segments.append(segment)
        try? context.save()
    }

    private func duplicate(_ segment: CustomSegmentRecord) {
        let copy = CustomSegmentRecord(
            orderIndex: segment.orderIndex,
            name: segment.name + String(localized: " (copy)"),
            durationSeconds: segment.durationSeconds,
            targetSpeedKmh: segment.targetSpeedKmh,
            targetIncline: segment.targetIncline
        )
        // After targetSpeedKmh (set above): a distance goal derives its stored
        // planned-duration mirror from the speed. Same ordering constraint,
        // and the same reason, as CustomProgram.copy(of:) — without this the
        // duplicate of a distance segment silently reverts to a time goal.
        copy.goal = segment.goal
        copy.program = program
        program.segments.append(copy)
        reindex(program.sortedSegments)
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ordered = program.sortedSegments
        ordered.move(fromOffsets: source, toOffset: destination)
        reindex(ordered)
    }

    private func delete(at offsets: IndexSet) {
        let ordered = program.sortedSegments
        let doomed = offsets.map { ordered[$0] }
        for segment in doomed { context.delete(segment) }
        let remaining = ordered.filter { segment in !doomed.contains(where: { $0 === segment }) }
        reindex(remaining)
    }

    private func reindex(_ ordered: [CustomSegmentRecord]) {
        for (index, segment) in ordered.enumerated() {
            segment.orderIndex = index
        }
        try? context.save()
    }
}

/// Editing one segment's values.
struct SegmentEditorView: View {
    @Bindable var segment: CustomSegmentRecord
    let limits: TreadmillLimits
    @Environment(\.modelContext) private var context

    var body: some View {
        List {
            Section {
                TextField("Segment name", text: $segment.name)
                    .font(Brand.display(15, .semibold))
                    .foregroundStyle(.white)
                    .listRowBackground(Brand.bgElev1)
            } header: {
                BrandEyebrow(String(localized: "Name"))
            }

            Section {
                Picker(String(localized: "Goal"), selection: $segment.goalKind) {
                    Text(String(localized: "Time")).tag(SegmentGoal.Kind.time)
                    Text(String(localized: "Distance")).tag(SegmentGoal.Kind.distance)
                }
                .pickerStyle(.segmented)
                .tint(Brand.accent)
                .listRowBackground(Brand.bgElev1)

                if segment.goalKind == .distance {
                    Stepper(value: distanceBinding, in: WorkoutSegment.goalDistanceRangeKm,
                            step: WorkoutSegment.goalDistanceStepKm) {
                        labeled(String(localized: "Distance"), SegmentFormat.distance(segment.goalDistanceKm))
                    }
                    .listRowBackground(Brand.bgElev1)
                } else {
                    // Bounds come from the model, the same constants
                    // CustomSegmentRecord.seededGoalDurationSeconds clamps
                    // into, so the editor and the goal-seeding logic cannot
                    // drift apart.
                    Stepper(value: $segment.durationSeconds,
                            in: WorkoutSegment.goalDurationRangeSeconds,
                            step: WorkoutSegment.goalDurationStepSeconds) {
                        labeled(String(localized: "Duration"), SessionFormat.duration(segment.durationSeconds))
                    }
                    .listRowBackground(Brand.bgElev1)
                }
                Stepper(value: speedBinding,
                        in: limits.minSpeedKmh...limits.maxSpeedKmh, step: 0.1) {
                    labeled(String(localized: "Speed"), speedLabel)
                }
                .listRowBackground(Brand.bgElev1)
                Stepper(value: $segment.targetIncline,
                        in: limits.minIncline...limits.maxIncline) {
                    labeled(String(localized: "Incline"), "\(segment.targetIncline)%")
                }
                .listRowBackground(Brand.bgElev1)
            } header: {
                BrandEyebrow(String(localized: "Targets"))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Brand.bgDeep)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("SEGMENT")
                    .font(Brand.display(12, .semibold))
                    .tracking(1.5)
                    .foregroundStyle(Brand.fgMid)
            }
        }
        .toolbarBackground(Brand.bgDeep, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .onDisappear { try? context.save() }
    }

    /// A distance goal is stored exactly; re-assigning it through
    /// `CustomSegmentRecord.goal`'s setter also refreshes the planned-duration
    /// mirror (`durationSeconds`) the row and summary labels sort on.
    private var distanceBinding: Binding<Double> {
        Binding(get: { segment.goalDistanceKm },
                set: { segment.goal = .distance(km: $0) })
    }

    /// For a distance goal the planned-duration mirror also depends on speed,
    /// so a speed change has to refresh it the same way a distance change does.
    /// `refreshPlannedDuration()` is a no-op for a time goal, so this is safe
    /// to use unconditionally and keeps the time-goal editor unchanged.
    private var speedBinding: Binding<Double> {
        Binding(get: { segment.targetSpeedKmh },
                set: { newValue in
                    segment.targetSpeedKmh = newValue
                    segment.refreshPlannedDuration()
                })
    }

    /// "8.0 km/h", with the implied pace appended for a distance goal —
    /// runners think in pace.
    private var speedLabel: String {
        let speed = SegmentFormat.speed(segment.targetSpeedKmh)
        guard segment.goalKind == .distance,
              let pace = SegmentFormat.pace(speedKmh: segment.targetSpeedKmh) else {
            return speed
        }
        return speed + " · " + pace
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(Brand.fgDim).font(.subheadline)
            Spacer()
            Text(value)
                .font(Brand.display(15, .semibold))
                .foregroundStyle(.white)
        }
    }
}
