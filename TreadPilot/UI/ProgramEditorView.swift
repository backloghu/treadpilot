// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import SwiftData
import SwiftUI

/// Editing a custom program: name, segment ordering, adding, deleting.
struct ProgramEditorView: View {
    @Bindable var program: CustomProgram
    @Environment(\.modelContext) private var context
    /// Always in the environment from the app's composition root, whatever the
    /// connection phase — this screen is reachable before ever connecting (from
    /// the scan screen), so `client.limits` is the plausible default until a
    /// device is actually found, and the real device's limits once one is.
    @EnvironmentObject private var client: FitShowTreadmillClient

    /// The editor's own bounds: the connected device's limits narrowed further
    /// to the plausible default range (finding 119, "one source of truth").
    /// Not simply `client.limits` — see `HeartRateTarget.isUsable(within:)`'s
    /// doc comment: every existing usability check in this codebase still
    /// measures a heart-rate segment against the hardcoded default, so a device
    /// *wider* than the default could otherwise let this editor seed a start
    /// command or a corridor edge that check then rejects, silently reverting
    /// the segment to fixed on that exact hardware. Narrowing here rather than
    /// widening that check's call sites is the fix this packet can make without
    /// touching `ProgramRunner.swift`. A device *narrower* than the default is
    /// handled by the same intersection, from the other side.
    private var limits: TreadmillLimits { TreadmillLimits.narrower(client.limits, TreadmillLimits()) }

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
                                     + SegmentFormat.target(segment.target))
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

    /// The assembly itself lives on the model (`CustomProgram.duplicate(_:)`,
    /// finding 86): a heart-rate segment's band, actuator, bounds and fallback
    /// used to be dropped here because this call site was assembled by hand a
    /// second time, and a model method is also what a unit test can exercise
    /// without a `View` and its missing `ModelContext`. This is left doing only
    /// the reindex and the save.
    private func duplicate(_ segment: CustomSegmentRecord) {
        program.duplicate(segment)
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

/// Editing one segment's values: the goal (Time / Distance / Recovery) and the
/// target (Fixed / Heart rate). Finding 104: every range and step below comes
/// from a named constant on `WorkoutSegment` / `HeartRateTarget` /
/// `HeartRateGovernor` — never a literal — so this editor cannot represent a
/// value those types would reject, the bug that shipped twice already.
struct SegmentEditorView: View {
    @Bindable var segment: CustomSegmentRecord
    let limits: TreadmillLimits
    @Environment(\.modelContext) private var context
    /// Only `holdableBandRangeBpm(for:)` reads this — the live basis, not a
    /// frozen one: a running workout freezes its own basis elsewhere, and this
    /// screen is not that, it only keeps the editor from offering a band this
    /// profile's own force-down ceiling would refuse.
    @EnvironmentObject private var profile: ProfileStore

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
                    Text(String(localized: "Recovery")).tag(SegmentGoal.Kind.untilHeartRateBelow)
                }
                .pickerStyle(.segmented)
                .tint(Brand.accent)
                .listRowBackground(Brand.bgElev1)

                switch segment.goalKind {
                case .distance:
                    Stepper(value: distanceBinding, in: WorkoutSegment.goalDistanceRangeKm,
                            step: WorkoutSegment.goalDistanceStepKm) {
                        labeled(String(localized: "Distance"), SegmentFormat.distance(segment.goalDistanceKm))
                    }
                    .listRowBackground(Brand.bgElev1)
                case .untilHeartRateBelow:
                    Stepper(value: recoveryThresholdBinding,
                            in: WorkoutSegment.goalHeartRateBelowRangeBpm,
                            step: WorkoutSegment.goalHeartRateBelowStepBpm) {
                        labeled(String(localized: "Threshold"), SessionFormat.bpm(segment.goalHeartRateBelow))
                    }
                    .listRowBackground(Brand.bgElev1)
                    // The same stepper and grid as a time goal's duration —
                    // spec section 4: "reuses goalDurationRangeSeconds and its
                    // step", so the cap can never seed a value this editor's
                    // own Time tab could not represent.
                    Stepper(value: recoveryCapBinding,
                            in: WorkoutSegment.goalDurationRangeSeconds,
                            step: WorkoutSegment.goalDurationStepSeconds) {
                        labeled(String(localized: "Time cap"), SessionFormat.duration(segment.goalMaxSeconds))
                    }
                    .listRowBackground(Brand.bgElev1)
                case .time:
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

                Picker(String(localized: "Control"), selection: $segment.targetKind) {
                    Text(String(localized: "Fixed")).tag(SegmentTarget.Kind.fixed)
                    Text(String(localized: "Heart rate")).tag(SegmentTarget.Kind.heartRate)
                }
                .pickerStyle(.segmented)
                .tint(Brand.accent)
                .listRowBackground(Brand.bgElev1)

                if segment.targetKind == .fixed {
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
                }
            } header: {
                BrandEyebrow(String(localized: "Targets"))
            }

            if segment.targetKind == .heartRate {
                heartRateSection
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

    // MARK: - Heart-rate target

    @ViewBuilder
    private var heartRateSection: some View {
        Section {
            Picker(String(localized: "Steer with"), selection: actuatorBinding) {
                Text(String(localized: "Speed")).tag(HeartRateActuator.speed)
                Text(String(localized: "Incline")).tag(HeartRateActuator.incline)
            }
            .pickerStyle(.segmented)
            .tint(Brand.accent)
            .listRowBackground(Brand.bgElev1)

            if segment.hrActuator == .speed {
                Stepper(value: speedBinding, in: actuatedSpeedStartRange,
                        step: HeartRateTarget.speedStepKmh) {
                    labeled(String(localized: "Start speed"), SegmentFormat.speed(segment.targetSpeedKmh))
                }
                .listRowBackground(Brand.bgElev1)
                Stepper(value: $segment.targetIncline, in: limits.minIncline...limits.maxIncline) {
                    labeled(String(localized: "Start incline"), "\(segment.targetIncline)%")
                }
                .listRowBackground(Brand.bgElev1)
            } else {
                Stepper(value: speedBinding, in: limits.minSpeedKmh...limits.maxSpeedKmh, step: 0.1) {
                    labeled(String(localized: "Start speed"), SegmentFormat.speed(segment.targetSpeedKmh))
                }
                .listRowBackground(Brand.bgElev1)
                Stepper(value: $segment.targetIncline, in: actuatedInclineStartRange) {
                    labeled(String(localized: "Start incline"), "\(segment.targetIncline)%")
                }
                .listRowBackground(Brand.bgElev1)
            }

            Stepper(value: lowBpmBinding,
                    in: HeartRateTarget.lowBpmEditingRange(highBpm: segment.hrHighBpm,
                                                           holdableRange: holdableBandRangeBpm),
                    step: HeartRateTarget.bandStepBpm) {
                labeled(String(localized: "Band low"), SessionFormat.bpm(segment.hrLowBpm))
            }
            .listRowBackground(Brand.bgElev1)
            Stepper(value: highBpmBinding,
                    in: HeartRateTarget.highBpmEditingRange(lowBpm: segment.hrLowBpm,
                                                            holdableRange: holdableBandRangeBpm),
                    step: HeartRateTarget.bandStepBpm) {
                labeled(String(localized: "Band high"), SessionFormat.bpm(segment.hrHighBpm))
            }
            .listRowBackground(Brand.bgElev1)

            // Directly under the two steppers whose values it is about, and only
            // when there is something to say. See `SegmentBandFit`.
            if let adjustment = unholdableBandAdjustment {
                unholdableBandNotice(adjustment)
                    .listRowBackground(Brand.bgElev1)
            }

            if segment.hrActuator == .speed {
                Stepper(value: minSpeedCorridorBinding,
                        in: HeartRateTarget.minSpeedEditingRange(maxSpeedKmh: segment.hrMaxSpeedKmh,
                                                                 limits: limits),
                        step: HeartRateTarget.speedStepKmh) {
                    labeled(String(localized: "Min speed"), SegmentFormat.speed(segment.hrMinSpeedKmh))
                }
                .listRowBackground(Brand.bgElev1)
                Stepper(value: maxSpeedCorridorBinding,
                        in: HeartRateTarget.maxSpeedEditingRange(minSpeedKmh: segment.hrMinSpeedKmh,
                                                                 limits: limits),
                        step: HeartRateTarget.speedStepKmh) {
                    labeled(String(localized: "Max speed"), SegmentFormat.speed(segment.hrMaxSpeedKmh))
                }
                .listRowBackground(Brand.bgElev1)
                Stepper(value: fallbackSpeedBinding,
                        in: limits.minSpeedKmh...limits.maxSpeedKmh, step: HeartRateTarget.speedStepKmh) {
                    labeled(String(localized: "Fallback speed"), SegmentFormat.speed(fallbackSpeedBinding.wrappedValue))
                }
                .listRowBackground(Brand.bgElev1)
            } else {
                Stepper(value: minInclineCorridorBinding,
                        in: HeartRateTarget.minInclineEditingRange(maxIncline: segment.hrMaxIncline,
                                                                   limits: limits)) {
                    labeled(String(localized: "Min incline"), "\(segment.hrMinIncline)%")
                }
                .listRowBackground(Brand.bgElev1)
                Stepper(value: maxInclineCorridorBinding,
                        in: HeartRateTarget.maxInclineEditingRange(minIncline: segment.hrMinIncline,
                                                                   limits: limits)) {
                    labeled(String(localized: "Max incline"), "\(segment.hrMaxIncline)%")
                }
                .listRowBackground(Brand.bgElev1)
            }
        } header: {
            BrandEyebrow(String(localized: "Heart-rate target"))
        } footer: {
            Text(segment.hrActuator == .speed
                 ? String(localized: "The app holds the band by moving speed inside this corridor. If the heart-rate feed is lost for too long, it drops to the fallback speed and holds it.")
                 : String(localized: "The app holds the band by moving incline inside this corridor. If the heart-rate feed is lost for too long, incline drops to the treadmill's own minimum."))
                .font(.footnote)
                .foregroundStyle(Brand.grey)
        }
        // Finding 118: a stored band that was valid when it was seeded can
        // outlive the profile it was seeded against — a lower maximum-heart-rate
        // override typed in afterwards shrinks `holdableBandRangeBpm` under a
        // band that was fine when it was saved. The steppers above can no longer
        // trap on this (their ranges are inversion-proof either way).
        //
        // There is deliberately **no** `.onAppear` repair here any more. That is
        // finding 118's second round: pulling the stored band inside
        // `holdableBandRangeBpm` on appearing wrote the new pair straight onto the
        // `@Model` record and `.onDisappear`'s save made it permanent, with
        // nothing on screen saying so — merely opening a 150–165 segment after a
        // 130 bpm maximum override turned it into 114–119 and backing out kept it.
        // The band is now left exactly as the user saved it and the notice above
        // states the mismatch; the only thing that rewrites it is the user tapping
        // the adjustment. See `SegmentBandFit`.
    }

    /// The band this profile could actually hold, when the stored one no longer
    /// fits — nil in every ordinary case, which is also the notice's own
    /// visibility condition. The decision itself is pure and lives in
    /// `SegmentBandFit`; this only feeds it the two stored columns and the live
    /// holdable range.
    private var unholdableBandAdjustment: ClosedRange<Int>? {
        SegmentBandFit.adjustment(forStoredLowBpm: segment.hrLowBpm,
                                  highBpm: segment.hrHighBpm,
                                  holdable: holdableBandRangeBpm)
    }

    /// The visible statement the hard rule asks for: the stored band is above
    /// what this profile's own force-down ceiling allows the loop to chase, said
    /// where the band is edited, plus the adjustment as a one-tap action rather
    /// than a thing that already happened.
    ///
    /// "Above" rather than "outside" is exact: a heart-rate section is only ever
    /// shown for a target `CustomSegmentRecord.target` found usable, so the
    /// stored band is inside `HeartRateTarget.bandRangeBpm` (low >= 60), while
    /// `holdableBandRangeBpm`'s own lower bound is never above 60. Every possible
    /// mismatch is therefore an upward one.
    ///
    /// The wording mirrors the dashboard's own vocabulary for the same rule
    /// ("Band not reachable — running fixed", the "(reduced)" chip), because it
    /// is the same rule seen from the plan side.
    private func unholdableBandNotice(_ adjustment: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("This band is above what your current heart-rate basis can hold, so the app will not steer it — the segment would run fixed at its start command. Nothing has been changed.")
            }
            .font(.footnote)
            .foregroundStyle(Brand.danger)
            Button {
                applyBandAdjustment(adjustment)
            } label: {
                Text(String(localized: "Adjust the band to \(adjustment.lowerBound)–\(adjustment.upperBound) bpm"))
                    .font(Brand.display(12, .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Brand.accent)
            }
            // The hit area is the label, not the row. A List row that also holds
            // explanatory text must not turn a tap on that text into an edit of
            // the plan — the whole point of this notice is that the change happens
            // only when the user aims at the sentence that names both values.
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    /// The adjustment, applied because the user asked for it. Saved at once
    /// rather than left to `.onDisappear`: this is the one write on this screen
    /// the user made by tapping a label that named both new values, so it is the
    /// one write that has earned being durable immediately.
    private func applyBandAdjustment(_ adjustment: ClosedRange<Int>) {
        segment.hrLowBpm = adjustment.lowerBound
        segment.hrHighBpm = adjustment.upperBound
        try? context.save()
    }

    /// The bpm a band may be asked for on the live profile basis — the
    /// governor's own `holdableBandRangeBpm`, which already stops one bpm
    /// short of the force-down ceiling, so this editor cannot offer a band the
    /// loop is forbidden to chase (spec section 4, "A band above the
    /// force-down ceiling is not a band the governor may chase").
    private var holdableBandRangeBpm: ClosedRange<Int> {
        HeartRateGovernor.holdableBandRangeBpm(for: profile.heartRateBasis)
    }

    /// Where the actuated axis's start command may sit: the corridor being
    /// edited, not the whole device range — `HeartRateTarget.isUsable`
    /// requires the start command to be inside the corridor it steers in, and
    /// a stepper that could set it outside that corridor is the exact bug
    /// finding 104 reported (a value the editor could represent but the model
    /// would then read back as a plain fixed segment).
    private var actuatedSpeedStartRange: ClosedRange<Double> {
        min(segment.hrMinSpeedKmh, segment.hrMaxSpeedKmh)...max(segment.hrMinSpeedKmh, segment.hrMaxSpeedKmh)
    }

    private var actuatedInclineStartRange: ClosedRange<Int> {
        min(segment.hrMinIncline, segment.hrMaxIncline)...max(segment.hrMinIncline, segment.hrMaxIncline)
    }

    private var lowBpmBinding: Binding<Int> {
        Binding(get: { segment.hrLowBpm }, set: { segment.hrLowBpm = $0 })
    }

    private var highBpmBinding: Binding<Int> {
        Binding(get: { segment.hrHighBpm }, set: { segment.hrHighBpm = $0 })
    }

    /// Switching axis can leave the axis just switched *to* stale: it was not
    /// checked while it was not the actuated one, so its corridor or its start
    /// command may no longer agree. The start command is pulled back inside
    /// the corridor rather than left to fail `isUsable` silently the moment
    /// this picker moves (finding 104).
    private var actuatorBinding: Binding<HeartRateActuator> {
        Binding(get: { segment.hrActuator }, set: { newValue in
            segment.hrActuator = newValue
            switch newValue {
            case .speed:
                let clamped = HeartRateTarget.quantizedSpeed(
                    min(max(segment.targetSpeedKmh, actuatedSpeedStartRange.lowerBound),
                        actuatedSpeedStartRange.upperBound))
                if clamped != segment.targetSpeedKmh {
                    segment.targetSpeedKmh = clamped
                    segment.refreshPlannedDuration()
                }
            case .incline:
                segment.targetIncline = min(max(segment.targetIncline, actuatedInclineStartRange.lowerBound),
                                            actuatedInclineStartRange.upperBound)
            }
        })
    }

    /// Moving a corridor bound past the current start command pulls the start
    /// command back inside rather than leaving it stranded outside — the same
    /// reasoning as `actuatorBinding`.
    private var minSpeedCorridorBinding: Binding<Double> {
        Binding(get: { segment.hrMinSpeedKmh }, set: { newValue in
            let low = HeartRateTarget.quantizedSpeed(newValue)
            segment.hrMinSpeedKmh = low
            guard segment.targetSpeedKmh < low else { return }
            segment.targetSpeedKmh = low
            segment.refreshPlannedDuration()
        })
    }

    private var maxSpeedCorridorBinding: Binding<Double> {
        Binding(get: { segment.hrMaxSpeedKmh }, set: { newValue in
            let high = HeartRateTarget.quantizedSpeed(newValue)
            segment.hrMaxSpeedKmh = high
            guard segment.targetSpeedKmh > high else { return }
            segment.targetSpeedKmh = high
            segment.refreshPlannedDuration()
        })
    }

    private var minInclineCorridorBinding: Binding<Int> {
        Binding(get: { segment.hrMinIncline }, set: { newValue in
            segment.hrMinIncline = newValue
            if segment.targetIncline < newValue { segment.targetIncline = newValue }
        })
    }

    private var maxInclineCorridorBinding: Binding<Int> {
        Binding(get: { segment.hrMaxIncline }, set: { newValue in
            segment.hrMaxIncline = newValue
            if segment.targetIncline > newValue { segment.targetIncline = newValue }
        })
    }

    /// The stored fallback reads as the device's own minimum walking speed
    /// when it is 0 (`HeartRateTarget`'s own documented clamp) — shown and
    /// stepped from that floor rather than from a confusing on-screen 0.0.
    private var fallbackSpeedBinding: Binding<Double> {
        Binding(get: { HeartRateTarget.quantizedSpeed(segment.hrFallbackSpeedKmh) },
                set: { segment.hrFallbackSpeedKmh = HeartRateTarget.quantizedSpeed($0) })
    }

    // MARK: - Recovery goal

    private var recoveryThresholdBinding: Binding<Int> {
        Binding(get: { segment.goalHeartRateBelow },
                set: { segment.goal = .untilHeartRateBelow(bpm: $0, maxSeconds: segment.goalMaxSeconds) })
    }

    private var recoveryCapBinding: Binding<Int> {
        Binding(get: { segment.goalMaxSeconds },
                set: { segment.goal = .untilHeartRateBelow(bpm: segment.goalHeartRateBelow, maxSeconds: $0) })
    }

    // MARK: - Shared bindings

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

/// Does a stored heart-rate band still fit the profile it is being edited
/// against, and what would fit instead? Pure, SwiftUI-free and free of any
/// `@Model`, so the ruling can be tested without a `View`, a `ModelContext` or a
/// `ProfileStore` — the same shape, and for the same reason, as
/// `TargetBandChart.runs(in:)`.
///
/// **The editor states the reduction; it does not perform it** (spec section 4,
/// "A band above the force-down ceiling is not a band the governor may chase").
/// The earlier version of this rule ran the adjustment itself in `.onAppear` and
/// let `.onDisappear`'s save make it permanent: a 150–165 band built while the
/// maximum resolved to 200 became 114–119 the moment a 130 bpm override was
/// typed into the profile and the segment was merely opened, with no notice, no
/// undo, and the number on screen no longer the number the user set. Everywhere
/// else this feature surfaces the same reduction rather than acting on it — the
/// dashboard's "(reduced)" chip, the `bandNotSteerable` status line, the
/// profile's own "lower than the estimate; consider an override" — and nothing is
/// lost by asking instead of acting: the runner arbitrates the *stored* band
/// against the frozen basis at run time (`HeartRateGovernor.arbitration(for:
/// basis:)`), so an unholdable band is refused, the segment runs fixed and says
/// so. Persisting the repair was never a safety requirement; it was only a
/// silent edit of somebody's plan.
enum SegmentBandFit {
    /// The band this profile's holdable range would accept instead, or nil when
    /// the stored band already fits and there is nothing to say.
    ///
    /// The comparison is against the *normalised* stored pair, because the
    /// governor normalises too (`HeartRateGovernor.band(for:)`): a pair stored in
    /// the wrong order is not by itself unholdable, and reporting it here would
    /// be a notice about a problem the loop does not have.
    static func adjustment(forStoredLowBpm low: Int, highBpm high: Int,
                           holdable: ClosedRange<Int>) -> ClosedRange<Int>? {
        let stored = min(low, high)...max(low, high)
        let adjusted = HeartRateTarget.repairedBand(stored, within: holdable)
        return adjusted == stored ? nil : adjusted
    }
}
