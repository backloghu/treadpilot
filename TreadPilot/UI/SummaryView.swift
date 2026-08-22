// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import SwiftData
import SwiftUI

/// End-of-workout summary — the recorder presents it when the session closes.
struct SummaryView: View {
    let session: WorkoutSessionRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Finding 139: this sheet used to present a green checkmark
                    // over both live safety banners, so a stop the belt never
                    // obeyed could be replaced on screen by a completion tick.
                    // The durable facts are rendered here, inside the sheet
                    // itself, so nothing presented on top of anything else can
                    // hide them — and the heading below only ever claims a
                    // clean finish when one actually happened.
                    SessionStopReasonBanners(session: session)

                    HStack(spacing: 8) {
                        Image(systemName: headline.icon)
                        Text(headline.text).tracking(1.5)
                    }
                    .font(Brand.display(14, .semibold))
                    .foregroundStyle(headline.color)

                    SessionStatsGrid(session: session)

                    HealthSyncSection(session: session)

                    Button {
                        dismiss()
                    } label: {
                        Text("CLOSE").tracking(1.5)
                    }
                    .buttonStyle(BrandStrokeStyle())
                }
                .padding(20)
            }
            .background(Brand.bgDeep)
            .toolbar {
                ToolbarItem(placement: .principal) { BrandWordmark() }
            }
            .toolbarBackground(Brand.bgDeep, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            // Finding 203, same as ContentView's stack: a principal item with no
            // navigationTitle leaves the default *large* title layout reserving
            // a blank 52pt row under the bar. This sheet owns its own stack, so
            // it needs its own line.
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }

    /// A belt the app never saw stop is not a clean finish, whatever else the
    /// workout accomplished (finding 139). A stop for the heart-rate ceiling
    /// that *was* obeyed keeps the ordinary heading — `SessionStopReasonBanners`
    /// above already says why it ended early — because the app did exactly what
    /// it was supposed to.
    private var headline: (icon: String, text: String, color: Color) {
        session.beltDidNotStop
            ? ("exclamationmark.triangle.fill", String(localized: "WORKOUT ENDED"), Brand.danger)
            : ("checkmark.circle.fill", String(localized: "WORKOUT COMPLETE"), Brand.accent)
    }
}
