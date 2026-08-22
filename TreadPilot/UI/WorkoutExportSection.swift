// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import SwiftUI

/// The workout's TCX-export box — shared by the end-of-workout summary and the
/// history detail view, directly below `HealthSyncSection`. A demo workout
/// never happened, so — like the Health box above it — it renders nothing here.
struct WorkoutExportSection: View {
    let session: WorkoutSessionRecord

    @State private var fileURL: URL?
    @State private var exportFailed = false

    var body: some View {
        if session.isDemo {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                BrandEyebrow("Export")

                if let url = fileURL {
                    ShareLink(item: url) {
                        HStack { Image(systemName: "square.and.arrow.up"); Text("EXPORT TCX FILE").tracking(1.5) }
                    }
                    .buttonStyle(BrandStrokeStyle(color: Brand.accent))

                    Text("For Strava: upload the file manually at strava.com/upload.")
                        .font(.footnote)
                        .foregroundStyle(Brand.fgDim)
                } else if exportFailed {
                    Text("Couldn't create the export file.")
                        .font(.footnote)
                        .foregroundStyle(Brand.danger)
                }
            }
            .brandBox()
            .task {
                // Regenerated on every appearance rather than cached, so the
                // share sheet always offers the workout's current data. A throw
                // here — the demo guard (already excluded above) or a raw
                // file-write CocoaError — renders the same failure line either way.
                do {
                    fileURL = try TCXExporter.writeFile(for: session)
                } catch {
                    exportFailed = true
                }
            }
        }
    }
}
