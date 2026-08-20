// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import SwiftUI

/// Első indításkor kötelezően megjelenő biztonsági tájékoztató.
/// Az app valódi futópadot vezérel — enélkül nem engedjük tovább.
struct DisclaimerView: View {
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
