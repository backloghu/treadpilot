// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import SwiftUI

/// Body data for the calorie calculation: HealthKit values with the option to override.
struct ProfileView: View {
    @EnvironmentObject private var profile: ProfileStore

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
