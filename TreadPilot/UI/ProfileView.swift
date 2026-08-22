// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import SwiftUI

/// Body data for the calorie calculation: HealthKit values with the option to override.
struct ProfileView: View {
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var runner: ProgramRunner
    @State private var showHeartRateControlConfirmation = false
    /// The "asked once" flag (spec section 4): a first switch-on is confirmed a
    /// single time for the life of the app. Finding 120: this used to gate one
    /// *start path* rather than the capability itself, so a program begun with
    /// the setting off (correctly unconfirmed) and switched on mid-workout from
    /// this screen reached a governed segment having never asked. Gating the
    /// toggle here instead means `runner.heartRateControlEnabled` cannot become
    /// true by any route without this dialog having been accepted first, so a
    /// start path can simply trust it.
    @AppStorage("heartRateControl.confirmedOnce") private var hasConfirmedHeartRateControl = false
    /// Finding 132: the disclaimer is otherwise reachable exactly once, on first
    /// launch or on upgrade to a revision that needs re-consent. This does not
    /// touch the stored acceptance — it only reopens the same view to read again,
    /// dismissing back to the profile rather than re-confirming anything.
    @State private var showDisclaimer = false
    /// The developer-toggled event log (`DiagnosticLog`). Observed rather than
    /// owned: it is the app's one instance, and this screen is the only place
    /// that switches it on or hands a file to the share sheet.
    @ObservedObject private var diagnostics = DiagnosticLog.shared
    @State private var diagnosticLogs: [DiagnosticLog.StoredLog] = []

    var body: some View {
        List {
            Section {
                Stepper(value: weightBinding, in: 30...200, step: 0.5) {
                    labeled(String(localized: "Weight"), String(format: "%.1f kg", profile.effectiveProfile.weightKg),
                            overridden: profile.overrideWeightKg != nil,
                            healthValue: profile.healthWeightKg.map { String(format: "%.1f kg", $0) })
                }
                .listRowBackground(Brand.bgElev1)
                Stepper(value: heightBinding, in: 120...220, step: 1) {
                    labeled(String(localized: "Height"), String(format: "%.0f cm", profile.effectiveProfile.heightCm),
                            overridden: profile.overrideHeightCm != nil,
                            healthValue: profile.healthHeightCm.map { String(format: "%.0f cm", $0) })
                }
                .listRowBackground(Brand.bgElev1)
                Stepper(value: ageBinding, in: HeartRateZones.formulaAgeRange) {
                    labeled(String(localized: "Age"), String(localized: "\(profile.effectiveProfile.age) years"),
                            overridden: profile.overrideAge != nil,
                            healthValue: profile.healthAge.map { String(localized: "\($0) years") })
                }
                .listRowBackground(Brand.bgElev1)
                Picker(selection: sexBinding) {
                    Text("Male").tag(true)
                    Text("Female").tag(false)
                } label: {
                    labeled(String(localized: "Sex"), "",
                            overridden: profile.overrideIsMale != nil,
                            healthValue: profile.healthIsMale.map { $0 ? String(localized: "Male") : String(localized: "Female") })
                }
                .listRowBackground(Brand.bgElev1)
                Stepper(value: maxHeartRateBinding, in: HeartRateZones.maxRangeBpm) {
                    labeled(String(localized: "Maximum heart rate"),
                            SessionFormat.bpm(profile.effectiveMaxHeartRate),
                            overridden: profile.overrideMaxHeartRate != nil,
                            healthValue: profile.healthMaxHeartRate.map(SessionFormat.bpm),
                            healthValueIsEffective: healthMaxHeartRateIsEffective,
                            healthValueContradicts: profile.healthMaxHeartRateContradictingEstimate != nil)
                }
                .listRowBackground(Brand.bgElev1)
                Stepper(value: restingHeartRateBinding, in: HeartRateZones.restingRangeBpm) {
                    labeled(String(localized: "Resting heart rate"),
                            SessionFormat.bpm(profile.effectiveRestingHeartRate),
                            overridden: profile.overrideRestingHeartRate != nil,
                            healthValue: profile.healthRestingHeartRate.map(SessionFormat.bpm),
                            healthValueIsEffective: healthRestingHeartRateIsEffective)
                }
                .listRowBackground(Brand.bgElev1)
            } header: {
                BrandEyebrow(String(localized: "Body data"))
            } footer: {
                Text("Changing these values overrides the data read from Health. When heart rate data is available, calories are calculated from heart rate; otherwise the app uses a speed- and incline-based (MET) estimate.")
                    .font(.footnote)
                    .foregroundStyle(Brand.grey)
            }

            Section {
                if let zones = profile.heartRateZones {
                    ForEach(HeartRateZone.allCases, id: \.rawValue) { zone in
                        zoneRow(zone, in: zones)
                            .listRowBackground(Brand.bgElev1)
                    }
                } else {
                    Text("Raise the maximum heart rate or lower the resting heart rate to see zone ranges — the two are currently too close together.")
                        .font(.footnote)
                        .foregroundStyle(Brand.grey)
                        .listRowBackground(Brand.bgElev1)
                }
            } header: {
                BrandEyebrow(String(localized: "Heart-rate zones"))
            } footer: {
                Text("Zones are computed from your heart-rate reserve — the span between resting and maximum heart rate.")
                    .font(.footnote)
                    .foregroundStyle(Brand.grey)
            }

            Section {
                Toggle(isOn: heartRateControlBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Heart-rate control")
                            .foregroundStyle(.white)
                        Text("On a heart-rate driven segment, the app changes the belt's speed or incline by itself to hold your target zone.")
                            .font(.caption2)
                            .foregroundStyle(Brand.grey)
                    }
                }
                .tint(Brand.accent)
                .listRowBackground(Brand.bgElev1)
            } header: {
                BrandEyebrow(String(localized: "Heart-rate control"))
            } footer: {
                Text("Off by default. You can always take over by changing speed or incline at the console — control then stays yours for the rest of the segment.")
                    .font(.footnote)
                    .foregroundStyle(Brand.grey)
            }

            Section {
                Button {
                    Task { await profile.refreshFromHealthKit() }
                } label: {
                    Label {
                        Text("REFRESH FROM HEALTH").tracking(1.2).font(Brand.display(12, .semibold))
                    } icon: {
                        Image(systemName: "heart.text.square")
                    }
                    .foregroundStyle(Brand.accent)
                }
                .listRowBackground(Brand.bgElev1)
                Button {
                    profile.clearOverrides()
                } label: {
                    Label {
                        Text("CLEAR OVERRIDES").tracking(1.2).font(Brand.display(12, .semibold))
                    } icon: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .foregroundStyle(Brand.fgDim)
                }
                .listRowBackground(Brand.bgElev1)
                if let status = profile.healthKitStatus {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(Brand.accent)
                        .listRowBackground(Brand.bgElev1)
                }
            }

            Section {
                Toggle(isOn: $diagnostics.isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Diagnostic log")
                            .foregroundStyle(.white)
                        Text("Records the heart-rate loop's own decisions, every belt command and every stop of a program workout into a file on this iPhone.")
                            .font(.caption2)
                            .foregroundStyle(Brand.grey)
                    }
                }
                .tint(Brand.accent)
                .listRowBackground(Brand.bgElev1)
                if diagnosticLogs.isEmpty {
                    Text("No log yet. Switch this on, then start a program workout.")
                        .font(.footnote)
                        .foregroundStyle(Brand.grey)
                        .listRowBackground(Brand.bgElev1)
                } else {
                    ForEach(diagnosticLogs) { log in
                        ShareLink(item: log.url) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(log.name)
                                        .font(.subheadline)
                                        .foregroundStyle(.white)
                                    Text(Self.detail(of: log))
                                        .font(.caption2)
                                        .foregroundStyle(Brand.grey)
                                }
                            } icon: {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .foregroundStyle(Brand.accent)
                        }
                        .listRowBackground(Brand.bgElev1)
                    }
                }
            } header: {
                BrandEyebrow(String(localized: "Developer"))
            } footer: {
                Text("Off by default. Nothing leaves this iPhone: the app writes one JSON line per event — governor decisions with their inputs, belt commands, stops, feed gaps — and a file only goes anywhere if you share it. The ten most recent workouts are kept.")
                    .font(.footnote)
                    .foregroundStyle(Brand.grey)
            }

            Section {
                Button {
                    showDisclaimer = true
                } label: {
                    Label {
                        Text(String(localized: "Safety information").uppercased())
                            .tracking(1.2).font(Brand.display(12, .semibold))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .foregroundStyle(Brand.fgDim)
                }
                .listRowBackground(Brand.bgElev1)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Brand.bgDeep)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("PROFILE")
                    .font(Brand.display(12, .semibold))
                    .tracking(1.5)
                    .foregroundStyle(Brand.fgMid)
            }
        }
        .toolbarBackground(Brand.bgDeep, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task { await profile.refreshFromHealthKit() }
        // Flushed before it is listed, so what the share sheet offers is what has
        // actually happened — the log buffers and writes off the hot path.
        .task { await refreshDiagnosticLogs() }
        .onChange(of: diagnostics.isEnabled) { _, _ in
            Task { await refreshDiagnosticLogs() }
        }
        // Gates the capability itself (finding 120), not a start path: accepting
        // this only proceeds to actually switching the toggle on, the same
        // shape `HomeView`'s own one-time gates use elsewhere in this feature.
        .confirmationDialog("Heart-rate control changes belt speed by itself",
                            isPresented: $showHeartRateControlConfirmation,
                            titleVisibility: .visible) {
            Button("I understand") {
                hasConfirmedHeartRateControl = true
                runner.heartRateControlEnabled = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Safety.heartRateControlConfirmation)
        }
        .fullScreenCover(isPresented: $showDisclaimer) {
            DisclaimerView { showDisclaimer = false }
        }
    }

    /// Turning the toggle on is only ever visible once this dialog has been
    /// accepted — turning it off always takes effect at once, matching
    /// `ProgramRunner.heartRateControlEnabled`'s own didSet, which only ever
    /// *stops* writes synchronously. Rejecting the dialog leaves
    /// `runner.heartRateControlEnabled` untouched, so the switch visibly snaps
    /// back to off.
    private var heartRateControlBinding: Binding<Bool> {
        Binding(
            get: { runner.heartRateControlEnabled },
            set: { newValue in
                guard newValue else {
                    runner.heartRateControlEnabled = false
                    return
                }
                if hasConfirmedHeartRateControl {
                    runner.heartRateControlEnabled = true
                } else {
                    showHeartRateControlConfirmation = true
                }
            })
    }

    private func refreshDiagnosticLogs() async {
        await diagnostics.flush()
        diagnosticLogs = diagnostics.recentLogs()
    }

    /// A log file's size and time, from the system's own formatters — there is
    /// nothing here to translate, so it does not go through the catalog.
    private static func detail(of log: DiagnosticLog.StoredLog) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(log.sizeBytes),
                                             countStyle: .file)
        return "\(size) · \(log.modifiedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    /// - Parameter healthValueIsEffective: False when resolution rejected the
    ///   present Health reading in favor of a fallback, so "From Health" is
    ///   not printed next to a number it did not produce.
    /// - Parameter healthValueContradicts: True only for the maximum heart rate,
    ///   when Health holds a plausible ceiling *below* the age formula (spec
    ///   section 4) — the caption then prompts toward an override instead of
    ///   reading like ordinary unused evidence.
    private func labeled(_ title: String, _ value: String,
                         overridden: Bool, healthValue: String?,
                         healthValueIsEffective: Bool = true,
                         healthValueContradicts: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).foregroundStyle(Brand.fgDim).font(.subheadline)
                if !value.isEmpty {
                    Text(value)
                        .font(Brand.display(15, .semibold))
                        .foregroundStyle(.white)
                }
            }
            if overridden {
                Text(healthValue.map { String(localized: "overridden — Health: \($0)") } ?? String(localized: "manual value"))
                    .font(.caption2)
                    .foregroundStyle(Brand.accent)
            } else if let healthValue, healthValueIsEffective {
                Text("From Health: \(healthValue)")
                    .font(.caption2)
                    .foregroundStyle(Brand.grey)
            } else if let healthValue, healthValueContradicts {
                Text(String(localized: "Health: \(healthValue) — lower than the estimate; consider an override"))
                    .font(.caption2)
                    .foregroundStyle(Brand.accent)
            } else if let healthValue {
                Text(String(localized: "Health: \(healthValue) — not used"))
                    .font(.caption2)
                    .foregroundStyle(Brand.grey)
            } else {
                Text("default — no Health data")
                    .font(.caption2)
                    .foregroundStyle(Brand.grey)
            }
        }
    }

    private func zoneRow(_ zone: HeartRateZone, in zones: HeartRateZones) -> some View {
        HStack {
            Text(zone.shortLabel).foregroundStyle(Brand.fgDim).font(.subheadline)
            Spacer()
            Text(zoneRangeText(zone, in: zones))
                .font(Brand.display(15, .semibold))
                .foregroundStyle(.white)
        }
    }

    /// "138–152 bpm", or "185+ bpm" for zone five, which has no upper edge
    /// (`HeartRateZone.next` is nil — see `HeartRateZones.boundsBpm`).
    private func zoneRangeText(_ zone: HeartRateZone, in zones: HeartRateZones) -> String {
        let bounds = zones.boundsBpm(of: zone)
        if let upper = bounds.upper {
            return String(localized: "\(bounds.lower)–\(upper) bpm")
        }
        return String(localized: "\(bounds.lower)+ bpm")
    }

    // The stepper always steps from the effective value and saves as an override.
    private var weightBinding: Binding<Double> {
        Binding(get: { profile.effectiveProfile.weightKg },
                set: { profile.overrideWeightKg = $0 })
    }
    private var heightBinding: Binding<Double> {
        Binding(get: { profile.effectiveProfile.heightCm },
                set: { profile.overrideHeightCm = $0 })
    }
    private var ageBinding: Binding<Int> {
        Binding(get: { profile.effectiveProfile.age },
                set: { profile.overrideAge = $0 })
    }
    private var sexBinding: Binding<Bool> {
        Binding(get: { profile.effectiveProfile.isMale },
                set: { profile.overrideIsMale = $0 })
    }
    private var maxHeartRateBinding: Binding<Int> {
        Binding(get: { profile.effectiveMaxHeartRate },
                set: { profile.overrideMaxHeartRate = $0 })
    }
    private var restingHeartRateBinding: Binding<Int> {
        Binding(get: { profile.effectiveRestingHeartRate },
                set: { profile.overrideRestingHeartRate = $0 })
    }

    // Named by the resolver's own verdict, not by guessing from equal numbers
    // (an observed max can legitimately equal the age formula's answer).
    private var healthMaxHeartRateIsEffective: Bool {
        profile.resolvedMaxHeartRate.source == .healthObserved
    }
    private var healthRestingHeartRateIsEffective: Bool {
        profile.resolvedRestingHeartRate.source == .health
    }
}
