import SwiftData
import SwiftUI

/// Egy saját program szerkesztése: név, szegmensek sorrendezése, hozzáadás, törlés.
struct ProgramEditorView: View {
    @Bindable var program: CustomProgram
    @Environment(\.modelContext) private var context

    /// A szerkesztő a pad alapértelmezett limitjeit használja korlátnak;
    /// futtatáskor a kliens a tényleges eszköz-limitekre is clampel.
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
                                Text(SessionFormat.duration(segment.durationSeconds)
                                     + String(format: " · %.1f km/h · %d%%",
                                              segment.targetSpeedKmh, segment.targetIncline))
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

    /// Élőben frissülő program-összesítés: idő, táv, emelkedés, átlagsebesség.
    private var summaryRow: some View {
        let workout = program.asWorkoutProgram
        return HStack(spacing: 0) {
            summaryCell(String(localized: "Time"), SessionFormat.duration(Int(workout.totalDuration)))
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

/// Egy szegmens értékeinek szerkesztése.
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
                Stepper(value: $segment.durationSeconds, in: 15...7200, step: 15) {
                    labeled(String(localized: "Duration"), SessionFormat.duration(segment.durationSeconds))
                }
                .listRowBackground(Brand.bgElev1)
                Stepper(value: $segment.targetSpeedKmh,
                        in: limits.minSpeedKmh...limits.maxSpeedKmh, step: 0.1) {
                    labeled(String(localized: "Speed"), String(format: "%.1f km/h", segment.targetSpeedKmh))
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
