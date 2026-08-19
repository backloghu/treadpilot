import SwiftData
import SwiftUI

/// Kezdőképernyő csatlakozás után: innen indul a manuális edzés vagy az
/// edzésprogram, és itt érhető el a programkezelés, az előzmények, a profil
/// és a kapcsolat bontása. Az edzésképernyő csak aktív edzésnél látszik.
struct HomeView: View {
    let deviceName: String

    @EnvironmentObject private var client: FitShowTreadmillClient
    @EnvironmentObject private var runner: ProgramRunner
    @Query(sort: \CustomProgram.createdAt) private var customPrograms: [CustomProgram]
    @State private var selectedProgramId: UUID = WorkoutProgram.builtIn[0].id
    @State private var showManualStartConfirmation = false
    @State private var showProgramStartConfirmation = false

    private var programOptions: [WorkoutProgram] {
        WorkoutProgram.builtIn + customPrograms.map(\.asWorkoutProgram)
    }

    private var selectedProgram: WorkoutProgram {
        programOptions.first(where: { $0.id == selectedProgramId }) ?? WorkoutProgram.builtIn[0]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                deviceBox
                manualStartBox
                programBox
                navigationRow

                Button {
                    runner.stop()
                    client.disconnect()
                } label: {
                    Text("BONTÁS").tracking(1.5)
                }
                .buttonStyle(BrandStrokeStyle(color: Brand.fgDim))
            }
            .padding(20)
        }
        .background(Brand.bgDeep)
        .toolbar {
            ToolbarItem(placement: .principal) { BrandWordmark() }
        }
        .toolbarBackground(Brand.bgDeep, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .onAppear {
            // A lefutott program maradványa ne éljen tovább a kezdőképernyőn.
            if case .finished = runner.runnerState { runner.stop() }
        }
        .confirmationDialog("Elindítod a szalagot?",
                            isPresented: $showManualStartConfirmation,
                            titleVisibility: .visible) {
            Button("Indítás \(client.targetSpeedKmh, specifier: "%.1f") km/h sebességgel") {
                client.userConfirmedStart()
            }
            Button("Mégse", role: .cancel) {}
        } message: {
            Text("Állj a szalag két szélére, és csíptesd fel a biztonsági kulcsot.")
        }
        .confirmationDialog("Programot indítasz?",
                            isPresented: $showProgramStartConfirmation,
                            titleVisibility: .visible) {
            Button("\(selectedProgram.name) indítása") {
                runner.arm(selectedProgram, on: client)
            }
            Button("Mégse", role: .cancel) {}
        } message: {
            if let first = selectedProgram.segments.first {
                Text("A(z) \(ProgramRunner.armCountdownSeconds) mp-es visszaszámlálás után "
                     + "a szalag magától elindul, első szegmens: "
                     + String(format: "%.1f km/h, %d%% dőlés.", first.targetSpeedKmh, first.targetIncline)
                     + " Állj a szalag két szélére, biztonsági kulcs fel!")
            }
        }
    }

    private var deviceBox: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                BrandEyebrow("Csatlakoztatva")
                Text(deviceName)
                    .font(Brand.display(16, .semibold))
                    .foregroundStyle(.white)
            }
            Spacer()
            if !client.limits.fromDevice {
                Text("ALAPÉRTELMEZETT LIMITEK")
                    .font(Brand.display(9, .medium))
                    .tracking(1.2)
                    .foregroundStyle(Brand.grey)
            }
        }
        .brandBox()
    }

    private var manualStartBox: some View {
        VStack(alignment: .leading, spacing: 12) {
            BrandEyebrow("Manuális edzés")
            Text("Te állítod a sebességet és a dőlést edzés közben.")
                .font(.footnote)
                .foregroundStyle(Brand.fgDim)
            Button {
                showManualStartConfirmation = true
            } label: {
                HStack { Image(systemName: "play.fill"); Text("MANUÁLIS INDÍTÁS").tracking(1.5) }
            }
            .buttonStyle(BrandCTAStyle())
        }
        .brandBox()
    }

    private var programBox: some View {
        VStack(alignment: .leading, spacing: 12) {
            BrandEyebrow("Edzésprogram")
            Menu {
                ForEach(programOptions) { program in
                    Button(program.name) { selectedProgramId = program.id }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(selectedProgram.name)
                        .font(Brand.display(14, .semibold))
                        .foregroundStyle(Brand.accent)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Brand.accent)
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(Brand.bgElev2, in: RoundedRectangle(cornerRadius: Brand.radius))
                .overlay(RoundedRectangle(cornerRadius: Brand.radius).stroke(Brand.gridLine))
            }
            Text(SessionFormat.duration(Int(selectedProgram.totalDuration))
                 + " · \(selectedProgram.segments.count) szegmens"
                 + String(format: " · %.2f km", selectedProgram.totalDistanceKm)
                 + String(format: " · %.0f m szint", selectedProgram.totalElevationGainM)
                 + String(format: " · ⌀ %.1f km/h", selectedProgram.averageSpeedKmh))
                .font(.caption)
                .foregroundStyle(Brand.grey)
            Button {
                showProgramStartConfirmation = true
            } label: {
                HStack { Image(systemName: "list.bullet"); Text("PROGRAM INDÍTÁSA").tracking(1.5) }
            }
            .buttonStyle(BrandStrokeStyle(color: Brand.accent))
        }
        .brandBox()
    }

    private var navigationRow: some View {
        HStack(spacing: 10) {
            navBox("Előzmények", icon: "clock.arrow.circlepath") { HistoryView() }
            navBox("Programok", icon: "list.bullet.rectangle") { ProgramListView() }
            navBox("Profil", icon: "person.crop.circle") { ProfileView() }
        }
    }

    private func navBox<Destination: View>(_ title: String, icon: String,
                                           @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(Brand.accent)
                Text(title.uppercased())
                    .font(Brand.display(9, .semibold))
                    .tracking(1)
                    .foregroundStyle(Brand.fgMid)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Brand.bgElev1, in: RoundedRectangle(cornerRadius: Brand.radius))
            .overlay(RoundedRectangle(cornerRadius: Brand.radius).stroke(Brand.gridLine))
        }
    }
}
