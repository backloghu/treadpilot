import SwiftData
import SwiftUI

struct DashboardView: View {
    let deviceName: String

    @EnvironmentObject private var client: FitShowTreadmillClient
    @EnvironmentObject private var runner: ProgramRunner
    @EnvironmentObject private var recorder: SessionRecorder
    @Query(sort: \CustomProgram.createdAt) private var customPrograms: [CustomProgram]
    @State private var showStartConfirmation = false
    @State private var showProgramStartConfirmation = false
    @State private var selectedProgram = WorkoutProgram.builtIn[0]

    private var programOptions: [WorkoutProgram] {
        WorkoutProgram.builtIn + customPrograms.map(\.asWorkoutProgram)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                statusHeader
                speedReadout
                statsGrid
                controls
                programSection
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
            ToolbarItem(placement: .principal) {
                Text(deviceName.uppercased())
                    .font(Brand.display(12, .semibold))
                    .tracking(1.5)
                    .foregroundStyle(Brand.fgMid)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { runner.stop(); client.disconnect() } label: {
                    Text("BONTÁS").font(Brand.display(12, .semibold)).tracking(1.5)
                }
            }
        }
        .toolbarBackground(Brand.bgDeep, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .confirmationDialog("Elindítod a szalagot?",
                            isPresented: $showStartConfirmation,
                            titleVisibility: .visible) {
            Button("Indítás \(client.targetSpeedKmh, specifier: "%.1f") km/h sebességgel") {
                client.userConfirmedStart()
            }
            Button("Mégse", role: .cancel) {}
        } message: {
            Text("Állj a szalag két szélére, és csíptesd fel a biztonsági kulcsot.")
        }
        .confirmationDialog("Programot indítasz álló szalagon?",
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

    // MARK: - Fejléc

    private var statusHeader: some View {
        HStack {
            statusPill
            if client.staleData {
                HStack(spacing: 4) {
                    Image(systemName: "wifi.exclamationmark")
                    Text("NEM FRISSÜL").tracking(1)
                }
                .font(Brand.display(10, .semibold))
                .foregroundStyle(Brand.accent)
            }
            Spacer()
            if !client.limits.fromDevice {
                Text("ALAPÉRTELMEZETT LIMITEK")
                    .font(Brand.display(9, .medium))
                    .tracking(1.2)
                    .foregroundStyle(Brand.grey)
            }
        }
    }

    private var statusPill: some View {
        let (text, color): (String, Color) = switch client.state.status {
        case .running: ("FUT", Brand.accent)
        case .countdown: ("INDUL: \(client.state.countdownSeconds) MP", Brand.accent)
        case .paused: ("SZÜNETEL", Brand.fgMid)
        case .stopping: ("ÁLL LE", Brand.fgMid)
        case .safety: ("BIZTONSÁGI KULCS!", Brand.danger)
        case .error: ("HIBA", Brand.danger)
        default: ("KÉSZENLÉT", Brand.grey)
        }
        return Text(text)
            .font(Brand.display(11, .semibold))
            .tracking(1.5)
            .foregroundStyle(color == Brand.accent ? Brand.ink : color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color == Brand.accent ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(color.opacity(0.12)),
                        in: RoundedRectangle(cornerRadius: Brand.radius))
    }

    // MARK: - Kijelző

    private var speedReadout: some View {
        VStack(spacing: 6) {
            Text("\(client.state.speedKmh, specifier: "%.1f")")
                .font(Brand.display(84, .bold))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            Text("KM/H · DŐLÉS \(client.state.inclinePercent)%")
                .font(Brand.display(12, .medium))
                .tracking(2)
                .foregroundStyle(Brand.grey)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var statsGrid: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                stat("Idő", formattedTime(client.state.elapsedSeconds))
                stat("Táv", String(format: "%.2f km", client.state.distanceKm))
            }
            GridRow {
                // Aktív edzésnél a saját (testadat-alapú) számítást mutatjuk,
                // egyébként a pad nyers értékét.
                stat("Kalória", recorder.activeSession.map { "\(Int($0.computedKcal.rounded())) kcal" }
                                ?? "\(client.state.kcal) kcal")
                stat("Pulzus", client.state.heartRate > 0 ? "\(client.state.heartRate) bpm" : "–")
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            BrandEyebrow(title)
            Text(value)
                .font(Brand.display(22, .semibold))
                .foregroundStyle(.white)
        }
        .brandBox(padding: 14)
    }

    // MARK: - Vezérlők

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if client.state.isRunning {
                    Button {
                        client.requestStop()
                    } label: {
                        HStack { Image(systemName: "stop.fill"); Text("STOP").tracking(1.5) }
                    }
                    .buttonStyle(BrandCTAStyle(fill: Brand.danger, textColor: .white))
                    Button {
                        client.requestPause()
                    } label: {
                        HStack { Image(systemName: "pause.fill"); Text("SZÜNET").tracking(1.5) }
                    }
                    .buttonStyle(BrandStrokeStyle())
                } else {
                    Button {
                        showStartConfirmation = true
                    } label: {
                        HStack { Image(systemName: "play.fill"); Text("INDÍTÁS").tracking(1.5) }
                    }
                    .buttonStyle(BrandCTAStyle())
                    .disabled(client.state.status == .countdown)
                }
            }

            HStack(spacing: 10) {
                adjuster(title: "Sebesség",
                         value: String(format: "%.1f", client.targetSpeedKmh),
                         minus: { client.adjustSpeed(by: -0.1) },
                         plus: { client.adjustSpeed(by: 0.1) })
                adjuster(title: "Dőlés",
                         value: "\(client.targetIncline)%",
                         minus: { client.adjustIncline(by: -1) },
                         plus: { client.adjustIncline(by: 1) })
            }
        }
    }

    private func adjuster(title: String, value: String,
                          minus: @escaping () -> Void,
                          plus: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            BrandEyebrow(title)
            HStack {
                stepButton("minus", action: minus)
                Spacer()
                Text(value)
                    .font(Brand.display(20, .semibold))
                    .foregroundStyle(.white)
                Spacer()
                stepButton("plus", action: plus)
            }
        }
        .brandBox(padding: 12)
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Brand.accent)
                .frame(width: 36, height: 36)
                .background(Brand.bgElev2, in: RoundedRectangle(cornerRadius: Brand.radius))
                .overlay(RoundedRectangle(cornerRadius: Brand.radius).stroke(Brand.gridLine))
        }
    }

    // MARK: - Edzésprogram

    private var programSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BrandEyebrow("Edzésprogram")

            switch runner.runnerState {
            case .armed(let remaining):
                VStack(spacing: 10) {
                    Text("\(remaining)")
                        .font(Brand.display(64, .bold))
                        .foregroundStyle(Brand.accent)
                        .contentTransition(.numericText(countsDown: true))
                        .frame(maxWidth: .infinity)
                    Text("A szalag hamarosan elindul — állj a két szélére, biztonsági kulcs fel!")
                        .font(.footnote)
                        .foregroundStyle(Brand.fgDim)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                    Button {
                        runner.cancelArm()
                    } label: {
                        Text("MÉGSE").tracking(1.5)
                    }
                    .buttonStyle(BrandStrokeStyle(color: Brand.danger))
                }
            case .waitingForBelt:
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        ProgressView().tint(Brand.accent)
                        Text("A PAD INDUL…")
                            .font(Brand.display(13, .semibold))
                            .tracking(1.5)
                            .foregroundStyle(Brand.fgMid)
                    }
                    .frame(maxWidth: .infinity)
                    Button {
                        runner.cancelArm()
                    } label: {
                        Text("MÉGSE").tracking(1.5)
                    }
                    .buttonStyle(BrandStrokeStyle(color: Brand.danger))
                }
            case .running(let index, let remaining), .suspended(let index, let remaining):
                VStack(alignment: .leading, spacing: 8) {
                    if case .suspended = runner.runnerState {
                        HStack(spacing: 6) {
                            Image(systemName: "pause.circle")
                            Text("FELFÜGGESZTVE — A SZALAG NEM FUT").tracking(1)
                        }
                        .font(Brand.display(10, .semibold))
                        .foregroundStyle(Brand.accent)
                    }
                    if let segment = runner.currentSegment, let program = runner.program {
                        Text("\(index + 1)/\(program.segments.count) · \(segment.name)")
                            .font(Brand.display(15, .semibold))
                            .foregroundStyle(.white)
                        Text("Hátra: \(formattedTime(Int(remaining))) · cél: "
                             + String(format: "%.1f km/h, %d%%", segment.targetSpeedKmh, segment.targetIncline))
                            .font(.caption)
                            .foregroundStyle(Brand.grey)
                    }
                    Button {
                        runner.stop()
                    } label: {
                        Text("PROGRAM LEÁLLÍTÁSA").tracking(1.5)
                    }
                    .buttonStyle(BrandStrokeStyle(color: Brand.danger))
                }
            case .finished:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("PROGRAM KÉSZ!").tracking(1.5)
                }
                .font(Brand.display(13, .semibold))
                .foregroundStyle(Brand.accent)
                Button {
                    runner.stop()
                } label: {
                    Text("ÚJ PROGRAM").tracking(1.5)
                }
                .buttonStyle(BrandStrokeStyle())
            case .idle:
                HStack {
                    Picker("Program", selection: $selectedProgram) {
                        ForEach(programOptions) { program in
                            Text(program.name).tag(program)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Brand.accent)
                    Spacer()
                    NavigationLink {
                        ProgramListView()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(Brand.accent)
                    }
                }
                Button {
                    if client.state.isRunning {
                        runner.start(selectedProgram, on: client)
                    } else {
                        showProgramStartConfirmation = true
                    }
                } label: {
                    HStack { Image(systemName: "list.bullet"); Text("PROGRAM INDÍTÁSA").tracking(1.5) }
                }
                .buttonStyle(BrandStrokeStyle(color: Brand.accent))
                .disabled(client.state.status == .countdown)
                if !client.state.isRunning {
                    Text("Álló szalagon a program megerősítés és "
                         + "\(ProgramRunner.armCountdownSeconds) mp visszaszámlálás után indítja a padot.")
                        .font(.footnote)
                        .foregroundStyle(Brand.grey)
                }
            }
        }
        .brandBox()
    }

    private func formattedTime(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
