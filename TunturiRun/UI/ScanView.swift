import SwiftUI

struct ScanView: View {
    @EnvironmentObject private var client: FitShowTreadmillClient

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if client.phase == .bluetoothOff {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                        Text("Kapcsold be a Bluetooth-t a folytatáshoz.")
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

                #if targetEnvironment(simulator)
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        client.startDemo()
                    } label: {
                        HStack {
                            Image(systemName: "play.rectangle")
                            Text("DEMÓ MÓD").tracking(1.5)
                        }
                    }
                    .buttonStyle(BrandCTAStyle())
                    Text("A szimulátorban nincs Bluetooth — a demó móddal a teljes felület kipróbálható.")
                        .font(.footnote)
                        .foregroundStyle(Brand.grey)
                }
                #endif

                BrandEyebrow("Talált futópadok")
                    .padding(.top, 8)

                if client.discovered.isEmpty {
                    Text(client.phase == .scanning
                         ? "Keresés… Kapcsold be a futópadot."
                         : "Indíts keresést a padod megtalálásához.")
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
            ToolbarItem(placement: .principal) { BrandWordmark() }
            ToolbarItem(placement: .primaryAction) {
                if client.phase == .scanning {
                    Button { client.stopScan() } label: {
                        Text("ÁLLJ").font(Brand.display(12, .semibold)).tracking(1.5)
                    }
                } else {
                    Button { client.startScan() } label: {
                        Text("KERESÉS").font(Brand.display(12, .semibold)).tracking(1.5)
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
            return "FitShow-konzol (2019-es generáció)"
        }
        if name.uppercased().hasPrefix("TUNTURI T") {
            return "Újabb Tunturi-konzol"
        }
        return "Ismeretlen konzoltípus"
    }
}
