import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var client: FitShowTreadmillClient

    var body: some View {
        NavigationStack {
            Group {
                switch client.phase {
                case .idle, .scanning, .bluetoothOff:
                    ScanView()
                case .connecting(let name), .preparing(let name):
                    VStack(spacing: 20) {
                        ProgressView()
                            .tint(Brand.accent)
                        Text("CSATLAKOZÁS: \(name.uppercased())…")
                            .font(Brand.display(12, .medium))
                            .tracking(1.5)
                            .foregroundStyle(Brand.fgDim)
                        Button { client.disconnect() } label: {
                            Text("MÉGSE").tracking(1.5)
                        }
                        .buttonStyle(BrandStrokeStyle())
                        .frame(width: 160)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Brand.bgDeep)
                    .toolbar {
                        ToolbarItem(placement: .principal) { BrandWordmark() }
                    }
                case .ready(let name):
                    DashboardView(deviceName: name)
                }
            }
        }
        .tint(Brand.accent)
        .preferredColorScheme(.dark)
        // A riasztás itt él, nem a DashboardView-ban: kapcsolatvesztéskor a
        // dashboard kikerül a hierarchiából, de a figyelmeztetésnek pont akkor
        // kell látszania. Csak a felhasználó nyugtázása zárja be.
        .alert("Megszakadt a kapcsolat futás közben!",
               isPresented: $client.lostConnectionWhileRunning) {
            Button("Értem", role: .cancel) {}
        } message: {
            Text("A szalag az utolsó beállított sebességgel mehet tovább. "
                 + "Használd a pad Stop gombját vagy a biztonsági kulcsot!")
        }
    }
}
