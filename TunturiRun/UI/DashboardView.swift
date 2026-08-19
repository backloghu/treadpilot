import SwiftUI

/// Edzésképernyő: csak aktív edzésnél (futó/szüneteltetett szalag vagy aktív
/// program) látszik. A programindítás a kezdőképernyőn történik — itt csak az
/// élő adatok, a vezérlők és az aktív program állapota van.
struct DashboardView: View {
    let deviceName: String

    @EnvironmentObject private var client: FitShowTreadmillClient
    @EnvironmentObject private var runner: ProgramRunner
    @EnvironmentObject private var recorder: SessionRecorder
    @EnvironmentObject private var watchHeartRate: WatchHeartRateManager
    @State private var showResumeConfirmation = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                statusHeader
                speedReadout
                statsGrid
                controls
                if isProgramActive {
                    programSection
                }
            }
            .padding(20)
        }
        .background(Brand.bgDeep)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(deviceName.uppercased())
                    .font(Brand.display(12, .semibold))
                    .tracking(1.5)
                    .foregroundStyle(Brand.fgMid)
            }
        }
        .toolbarBackground(Brand.bgDeep, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .confirmationDialog("Folytatod az edzést?",
                            isPresented: $showResumeConfirmation,
                            titleVisibility: .visible) {
            Button("Folytatás \(client.targetSpeedKmh, specifier: "%.1f") km/h sebességgel") {
                client.userConfirmedStart()
            }
            Button("Mégse", role: .cancel) {}
        } message: {
            Text("Állj a szalag két szélére, és csíptesd fel a biztonsági kulcsot.")
        }
    }

    private var isProgramActive: Bool {
        switch runner.runnerState {
        case .armed, .waitingForBelt, .running, .suspended:
            return true
        case .idle, .finished:
            return false
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
                stat(watchHeartRate.freshHeartRate() > 0 ? "Pulzus · Watch" : "Pulzus",
                     heartRateText)
            }
            GridRow {
                stat("Szint fel", String(format: "%.0f m",
                                         recorder.activeSession?.elevationGainM ?? 0))
                stat("Lépések", client.state.steps > 0 ? "\(client.state.steps)" : "–")
            }
        }
    }

    private var heartRateText: String {
        let watchBpm = watchHeartRate.freshHeartRate()
        if watchBpm > 0 { return "\(watchBpm) bpm" }
        return client.state.heartRate > 0 ? "\(client.state.heartRate) bpm" : "–"
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
                    // Szünet/leállás közben innen folytatható az edzés;
                    // álló szalagnál a nézet magától visszavált a kezdőképernyőre.
                    Button {
                        showResumeConfirmation = true
                    } label: {
                        HStack { Image(systemName: "play.fill"); Text("FOLYTATÁS").tracking(1.5) }
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

    // MARK: - Aktív edzésprogram

    private var programSection: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                VStack(alignment: .leading, spacing: 10) {
                    if case .suspended = runner.runnerState {
                        HStack(spacing: 6) {
                            Image(systemName: "pause.circle")
                            Text("FELFÜGGESZTVE — A SZALAG NEM FUT").tracking(1)
                        }
                        .font(Brand.display(10, .semibold))
                        .foregroundStyle(Brand.accent)
                    }
                    if let segment = runner.currentSegment, let program = runner.program {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(index + 1)/\(program.segments.count) · \(segment.name)")
                                .font(Brand.display(15, .semibold))
                                .foregroundStyle(.white)
                            Spacer()
                            if let programRemaining = runner.programRemainingSeconds {
                                Text("HÁTRA " + SessionFormat.duration(programRemaining))
                                    .font(Brand.display(12, .semibold))
                                    .tracking(1)
                                    .foregroundStyle(Brand.accent)
                            }
                        }
                        if let progress = runner.programProgress {
                            programProgressBar(progress)
                        }
                        Text("Szakaszból hátra: \(formattedTime(Int(remaining))) · cél: "
                             + String(format: "%.1f km/h, %d%%", segment.targetSpeedKmh, segment.targetIncline))
                            .font(.caption)
                            .foregroundStyle(Brand.grey)
                        if let next = runner.nextSegment {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.right")
                                    .font(.caption2.weight(.bold))
                                Text("Következő: \(next.name) · "
                                     + String(format: "%.1f km/h, %d%%", next.targetSpeedKmh, next.targetIncline))
                            }
                            .font(.caption)
                            .foregroundStyle(Brand.fgDim)
                        } else {
                            HStack(spacing: 5) {
                                Image(systemName: "flag.checkered")
                                    .font(.caption2)
                                Text("Ez az utolsó szakasz")
                            }
                            .font(.caption)
                            .foregroundStyle(Brand.fgDim)
                        }
                    }
                    Button {
                        runner.stop()
                    } label: {
                        Text("PROGRAM LEÁLLÍTÁSA").tracking(1.5)
                    }
                    .buttonStyle(BrandStrokeStyle(color: Brand.danger))
                }
            case .idle, .finished:
                EmptyView()
            }
        }
        .brandBox()
    }

    private func programProgressBar(_ progress: Double) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Brand.bgElev2)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Brand.accent)
                    .frame(width: max(0, min(1, progress)) * geometry.size.width)
            }
        }
        .frame(height: 6)
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Brand.gridLine))
    }

    private func formattedTime(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
