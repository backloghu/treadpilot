// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import SwiftUI

/// Safety notice shown mandatorily on first launch, and re-presentable later.
/// The app controls a real treadmill — we do not let the user past this.
struct DisclaimerView: View {
    /// Bumped whenever the content changes in a way that needs re-consent, not
    /// on every wording tweak. `ContentView` stores the version the user last
    /// accepted and re-shows this, gated on `fullScreenCover`, whenever the
    /// stored value is lower — which is also what makes it reachable for a 1.0
    /// upgrader for free: 1.0 stored a plain `Bool` at a different key, so the
    /// versioned key defaults to 0 for every existing installation (finding
    /// 132). 1 marks this revision, which adds the "fitness feature, not a
    /// medical device" sentence below.
    static let currentVersion = 1

    let onAccept: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BrandWordmark()
                    .padding(.top, 24)

                BrandEyebrow(String(localized: "Safety information"))
                Text("This app controls a real treadmill")
                    .font(Brand.display(24, .bold))
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 12) {
                    bullet(String(localized: "On your commands the belt really starts, speeds up and inclines — stand firmly before every start and speed change."))
                    bullet(String(localized: "Always clip on the treadmill's safety key before use."))
                    bullet(String(localized: "If the connection drops, the belt may keep running at the last set speed — in an emergency the treadmill's own Stop button and the safety key are your primary protection."))
                    bullet(String(localized: "Never let a child use the app or the treadmill unsupervised."))
                    bullet(String(localized: "This is a fitness feature, not a medical device: heart-rate control estimates a target zone and steers toward it, it does not diagnose, monitor or treat any condition."))
                    bullet(String(localized: "You use this app at your own risk. If you have any health concerns, consult a doctor before working out."))
                }
                .brandBox()

                Button {
                    onAccept()
                } label: {
                    Text("I UNDERSTAND AND ACCEPT").tracking(1.5)
                }
                .buttonStyle(BrandCTAStyle())
            }
            .padding(20)
        }
        .background(Brand.bgDeep)
        .preferredColorScheme(.dark)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("■")
                .font(.system(size: 8))
                .foregroundStyle(Brand.accent)
                .padding(.top, 5)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Brand.fgMid)
        }
    }
}
