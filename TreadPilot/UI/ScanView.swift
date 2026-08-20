import SwiftUI

struct ScanView: View {
    @EnvironmentObject private var client: FitShowTreadmillClient

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if client.phase == .bluetoothOff {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                        Text("Turn on Bluetooth to continue.")
                    }
                    .font(Brand.display(13, .medium))
                    .foregroundStyle(Brand.accent)
                    .brandBox()
                }

                if let error = client.lastError {
                    HStack(spacing: 10) {
                        Image(systemName: "xmark.octagon")
                        Text(error)
                    }
                    .font(Brand.display(13, .medium))
                    .foregroundStyle(Brand.danger)
                    .brandBox()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        client.startDemo()
                    } label: {
                        HStack {
                            Image(systemName: "play.rectangle")
                            Text("DEMO MODE").tracking(1.5)
                        }
                    }
                    .buttonStyle(BrandCTAStyle())
                    Text("No treadmill nearby? Demo mode lets you explore the whole app on a simulated treadmill.")
                        .font(.footnote)
                        .foregroundStyle(Brand.grey)
                }

                BrandEyebrow(String(localized: "Discovered treadmills"))
                    .padding(.top, 8)

                if client.discovered.isEmpty {
                    Text(client.phase == .scanning
                         ? String(localized: "Scanning… Turn on the treadmill.")
                         : String(localized: "Start a scan to find your treadmill."))
                        .font(.subheadline)
                        .foregroundStyle(Brand.fgDim)
                        .brandBox()
                }

                ForEach(client.discovered) { device in
                    Button {
                        client.connect(to: device.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.name)
                                    .font(Brand.display(15, .semibold))
                                    .tracking(0.5)
                                    .foregroundStyle(.white)
                                Text(hint(for: device.name))
                                    .font(.caption)
                                    .foregroundStyle(Brand.grey)
                            }
                            Spacer()
                            Text("\(device.rssi) dBm")
                                .font(Brand.display(12, .regular))
                                .foregroundStyle(Brand.fgDim)
                        }
                    }
                    .brandBox()
                }
            }
            .padding(20)
        }
        .background(Brand.bgDeep)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    HistoryView()
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    ProgramListView()
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                }
            }
            ToolbarItem(placement: .principal) { BrandWordmark(size: 11) }
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink {
                    ProfileView()
                } label: {
                    Image(systemName: "person.crop.circle")
                }
                if client.phase == .scanning {
                    Button { client.stopScan() } label: {
                        Text("STOP").font(Brand.display(12, .semibold)).tracking(1.5)
                    }
                } else {
                    Button { client.startScan() } label: {
                        Text("SCAN").font(Brand.display(12, .semibold)).tracking(1.5)
                    }
                }
            }
        }
        .toolbarBackground(Brand.bgDeep, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .onAppear { client.startScan() }
    }

    private func hint(for name: String) -> String {
        if name.uppercased().hasPrefix("SW") {
            return String(localized: "FitShow console (2019 models)")
        }
        if name.uppercased().hasPrefix("TUNTURI T") {
            return String(localized: "Newer Tunturi console")
        }
        return String(localized: "Unknown console type")
    }
}
