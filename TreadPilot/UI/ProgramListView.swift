import SwiftData
import SwiftUI

/// Edzésprogramok kezelése: saját programok szerkesztése, beépítettek duplikálása.
struct ProgramListView: View {
    @Query(sort: \CustomProgram.createdAt) private var customPrograms: [CustomProgram]
    @Environment(\.modelContext) private var context

    var body: some View {
        List {
            Section {
                if customPrograms.isEmpty {
                    Text("No custom programs yet — create a new one, or duplicate a built-in.")
                        .font(.footnote)
                        .foregroundStyle(Brand.fgDim)
                        .listRowBackground(Brand.bgElev1)
                }
                ForEach(customPrograms) { program in
                    NavigationLink {
                        ProgramEditorView(program: program)
                    } label: {
                        row(name: program.name,
                            seconds: program.totalSeconds,
                            count: program.segments.count)
                    }
                    .listRowBackground(Brand.bgElev1)
                    .listRowSeparatorTint(Brand.gridLine)
                    .contextMenu {
                        Button {
                            duplicate(program.asWorkoutProgram)
                        } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets { context.delete(customPrograms[index]) }
                    try? context.save()
                }

                Button {
                    createNew()
                } label: {
                    Label {
                        Text("NEW PROGRAM").tracking(1.5).font(Brand.display(13, .semibold))
                    } icon: {
                        Image(systemName: "plus")
                    }
                    .foregroundStyle(Brand.accent)
                }
                .listRowBackground(Brand.bgElev1)
            } header: {
                BrandEyebrow(String(localized: "Custom programs"))
            }

            Section {
                ForEach(WorkoutProgram.builtIn) { program in
                    HStack {
                        row(name: program.name,
                            seconds: Int(program.totalDuration),
                            count: program.segments.count)
                        Spacer()
                        Button {
                            duplicate(program)
                        } label: {
                            Image(systemName: "plus.square.on.square")
                                .foregroundStyle(Brand.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    .listRowBackground(Brand.bgElev1)
                    .listRowSeparatorTint(Brand.gridLine)
                }
            } header: {
                BrandEyebrow(String(localized: "Built-in programs — duplicate to edit"))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Brand.bgDeep)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("PROGRAMS")
                    .font(Brand.display(12, .semibold))
                    .tracking(1.5)
                    .foregroundStyle(Brand.fgMid)
            }
        }
        .toolbarBackground(Brand.bgDeep, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private func row(name: String, seconds: Int, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(Brand.display(14, .semibold))
                .foregroundStyle(.white)
            Text(SessionFormat.duration(seconds) + " · " + String(localized: "\(count) segments"))
                .font(.caption)
                .foregroundStyle(Brand.grey)
        }
        .padding(.vertical, 2)
    }

    private func createNew() {
        let program = CustomProgram(name: String(localized: "New program"))
        let segment = CustomSegmentRecord(orderIndex: 0, name: String(localized: "Segment 1"),
                                          durationSeconds: 300,
                                          targetSpeedKmh: 5.0, targetIncline: 0)
        segment.program = program
        program.segments.append(segment)
        context.insert(program)
        try? context.save()
    }

    private func duplicate(_ program: WorkoutProgram) {
        let copy = CustomProgram.copy(of: program, name: program.name + String(localized: " (copy)"))
        context.insert(copy)
        try? context.save()
    }
}
