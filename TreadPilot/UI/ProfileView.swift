import SwiftUI

/// Testadatok a kalóriaszámításhoz: HealthKit-értékek felülírási lehetőséggel.
struct ProfileView: View {
    @EnvironmentObject private var profile: ProfileStore

    var body: some View {
        List {
            Section {
                Stepper(value: weightBinding, in: 30...200, step: 0.5) {
                    labeled("Testsúly", String(format: "%.1f kg", profile.effectiveProfile.weightKg),
                            overridden: profile.overrideWeightKg != nil,
                            healthValue: profile.healthWeightKg.map { String(format: "%.1f kg", $0) })
                }
                .listRowBackground(Brand.bgElev1)
                Stepper(value: heightBinding, in: 120...220, step: 1) {
                    labeled("Magasság", String(format: "%.0f cm", profile.effectiveProfile.heightCm),
                            overridden: profile.overrideHeightCm != nil,
                            healthValue: profile.healthHeightCm.map { String(format: "%.0f cm", $0) })
                }
                .listRowBackground(Brand.bgElev1)
                Stepper(value: ageBinding, in: 10...100) {
                    labeled("Életkor", "\(profile.effectiveProfile.age) év",
                            overridden: profile.overrideAge != nil,
                            healthValue: profile.healthAge.map { "\($0) év" })
                }
                .listRowBackground(Brand.bgElev1)
                Picker(selection: sexBinding) {
                    Text("Férfi").tag(true)
                    Text("Nő").tag(false)
                } label: {
                    labeled("Biológiai nem", "",
                            overridden: profile.overrideIsMale != nil,
                            healthValue: profile.healthIsMale.map { $0 ? "férfi" : "nő" })
                }
                .listRowBackground(Brand.bgElev1)
            } header: {
                BrandEyebrow("Testadatok")
            } footer: {
                Text("Az értékek módosítása felülírja a HealthKitből olvasottakat. "
                     + "A kalóriaszámítás pulzus birtokában pulzusalapú, anélkül "
                     + "sebesség- és dőlésalapú (MET) becslés.")
                    .font(.footnote)
                    .foregroundStyle(Brand.grey)
            }

            Section {
                Button {
                    Task { await profile.refreshFromHealthKit() }
                } label: {
                    Label {
                        Text("FRISSÍTÉS HEALTHKITBŐL").tracking(1.2).font(Brand.display(12, .semibold))
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
                        Text("FELÜLÍRÁSOK TÖRLÉSE").tracking(1.2).font(Brand.display(12, .semibold))
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
                Text("PROFIL")
                    .font(Brand.display(12, .semibold))
                    .tracking(1.5)
                    .foregroundStyle(Brand.fgMid)
            }
        }
        .toolbarBackground(Brand.bgDeep, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task { await profile.refreshFromHealthKit() }
    }

    private func labeled(_ title: String, _ value: String,
                         overridden: Bool, healthValue: String?) -> some View {
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
                Text(healthValue.map { "felülírva — HealthKit: \($0)" } ?? "kézi érték")
                    .font(.caption2)
                    .foregroundStyle(Brand.accent)
            } else if let healthValue {
                Text("HealthKitből: \(healthValue)")
                    .font(.caption2)
                    .foregroundStyle(Brand.grey)
            } else {
                Text("alapértelmezés — nincs HealthKit-adat")
                    .font(.caption2)
                    .foregroundStyle(Brand.grey)
            }
        }
    }

    // A stepper mindig az effektív értékből lép, és felülírásként ment.
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
}
