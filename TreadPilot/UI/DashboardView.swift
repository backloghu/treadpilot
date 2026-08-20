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
            VStack(spacing: 12) {
                statusHeader
                if let watchError = watchHeartRate.startError {
                    Text(watchError)
                        .font(.caption2)
                        .foregroundStyle(Brand.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // A program mindig felül, jól láthatóan — futás közben ez a
                // legfontosabb információ.
                if isProgramActive {
                    programPanel
                }
                speedReadout
                statsGrid
                controls
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
        .confirmationDialog("Resume the workout?",
                            isPresented: $showResumeConfirmation,
                            titleVisibility: .visible) {
            Button("Resume at \(client.targetSpeedKmh, specifier: "%.1f") km/h") {
                client.userConfirmedStart()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Safety.standClear)
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
                    Text("NOT UPDATING").tracking(1)
                }
                .font(Brand.display(10, .semibold))
                .foregroundStyle(Brand.accent)
            }
            Spacer()
            if !client.limits.fromDevice {
                Text("DEFAULT LIMITS")
                    .font(Brand.display(9, .medium))
                    .tracking(1.2)
                    .foregroundStyle(Brand.grey)
            }
        }
    }

    private var statusPill: some View {
        let (text, color): (String, Color) = switch client.state.status {
        case .running: (String(localized: "RUNNING"), Brand.accent)
        case .countdown: (String(localized: "STARTING IN \(client.state.countdownSeconds) SEC"), Brand.accent)
        case .paused: (String(localized: "PAUSED"), Brand.fgMid)
        case .stopping: (String(localized: "STOPPING"), Brand.fgMid)
        case .safety: (String(localized: "SAFETY KEY!"), Brand.danger)
        case .error: (String(localized: "ERROR"), Brand.danger)
        default: (String(localized: "STANDBY"), Brand.grey)
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
        VStack(spacing: 4) {
            Text("\(client.state.speedKmh, specifier: "%.1f")")
                .font(Brand.display(isProgramActive ? 60 : 84, .bold))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            Text("KM/H · INCLINE \(client.state.inclinePercent)%")
                .font(Brand.display(12, .medium))
                .tracking(2)
                .foregroundStyle(Brand.grey)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, isProgramActive ? 2 : 12)
    }

    private var kcalText: String {
        recorder.activeSession.map { "\(Int($0.computedKcal.rounded())) kcal" }
            ?? "\(client.state.kcal) kcal"
    }

    @ViewBuilder
    private var statsGrid: some View {
        if isProgramActive {
            // Kompakt, 3 oszlopos rács, hogy programnál minden egy képernyőn legyen.
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    compactStat(String(localized: "Time"), formattedTime(client.state.elapsedSeconds))
                    compactStat(String(localized: "Distance"), String(format: "%.2f km", client.state.distanceKm))
                    compactStat(String(localized: "Calories"), kcalText)
                }
                GridRow {
                    compactStat(watchHeartRate.freshHeartRate() > 0
                                ? String(localized: "Heart rate ⌚")
                                : String(localized: "Heart rate"),
                                heartRateText)
                    compactStat(String(localized: "Elevation gain"),
                                String(format: "%.0f m",
                                       recorder.activeSession?.elevationGainM ?? 0))
                    compactStat(String(localized: "Steps"), client.state.steps > 0 ? "\(client.state.steps)" : "–")
                }
            }
        } else {
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    stat(String(localized: "Time"), formattedTime(client.state.elapsedSeconds))
                    stat(String(localized: "Distance"), String(format: "%.2f km", client.state.distanceKm))
                }
                GridRow {
                    // Aktív edzésnél a saját (testadat-alapú) számítást mutatjuk,
                    // egyébként a pad nyers értékét.
                    stat(String(localized: "Calories"), kcalText)
                    stat(watchHeartRate.freshHeartRate() > 0
                         ? String(localized: "Heart rate · Watch")
                         : String(localized: "Heart rate"),
                         heartRateText)
                }
                GridRow {
                    stat(String(localized: "Elevation gain"),
                         String(format: "%.0f m",
                                recorder.activeSession?.elevationGainM ?? 0))
                    stat(String(localized: "Steps"), client.state.steps > 0 ? "\(client.state.steps)" : "–")
                }
            }
        }
    }

    private func compactStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(Brand.display(8, .medium))
                .tracking(1)
                .foregroundStyle(Brand.grey)
                .lineLimit(1)
            Text(value)
                .font(Brand.display(15, .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Brand.bgElev1, in: RoundedRectangle(cornerRadius: Brand.radius))
        .overlay(RoundedRectangle(cornerRadius: Brand.radius).stroke(Brand.gridLine))
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
                // A TÉNYLEGES sebesség dönt, nem a jelentett státusz: egyes
                // konzolok szünet közben is „running" státuszt jelentenek 0
                // sebességgel — a FOLYTATÁS-nak ilyenkor is elérhetőnek kell
                // lennie (#181).
                if client.state.isRunning && client.state.speedKmh > 0 {
                    Button {
                        client.requestStop()
                    } label: {
                        HStack { Image(systemName: "stop.fill"); Text("STOP").tracking(1.5) }
                    }
                    .buttonStyle(BrandCTAStyle(fill: Brand.danger, textColor: .white))
                    Button {
                        client.requestPause()
                    } label: {
                        HStack { Image(systemName: "pause.fill"); Text("PAUSE").tracking(1.5) }
                    }
                    .buttonStyle(BrandStrokeStyle())
                } else {
                    Button {
                        showResumeConfirmation = true
                    } label: {
                        HStack { Image(systemName: "play.fill"); Text("RESUME").tracking(1.5) }
                    }
                    .buttonStyle(BrandCTAStyle())
                    .disabled(client.state.status == .countdown)
                    Button {
                        client.requestStop()
                    } label: {
                        HStack { Image(systemName: "stop.fill"); Text("STOP").tracking(1.5) }
                    }
                    .buttonStyle(BrandStrokeStyle(color: Brand.danger))
                }
            }

            HStack(spacing: 10) {
                adjuster(title: String(localized: "Speed"),
                         value: String(format: "%.1f", client.targetSpeedKmh),
                         minus: { client.adjustSpeed(by: -0.1) },
                         plus: { client.adjustSpeed(by: 0.1) })
                adjuster(title: String(localized: "Incline"),
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

    // MARK: - Aktív edzésprogram (felül, kompakt sávként)

    @ViewBuilder
    private var programPanel: some View {
        switch runner.runnerState {
        case .running(let index, let remaining), .suspended(let index, let remaining):
            programStrip(segmentIndex: index, segmentRemaining: remaining)
        default:
            programArmingPanel
        }
    }

    /// Futó/felfüggesztett program: tömör sáv a képernyő tetején — szakasz,
    /// NAGY szakasz-visszaszámláló, következő szakasz, haladás, leállítás.
    private func programStrip(segmentIndex: Int, segmentRemaining: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .suspended = runner.runnerState {
                HStack(spacing: 6) {
                    Image(systemName: "pause.circle")
                    Text("SUSPENDED — BELT NOT RUNNING").tracking(1)
                }
                .font(Brand.display(10, .semibold))
                .foregroundStyle(Brand.accent)
            }
            if let segment = runner.currentSegment, let program = runner.program {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(segmentIndex + 1)/\(program.segments.count) · \(segment.name)")
                            .font(Brand.display(14, .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let next = runner.nextSegment {
                            Text("→ \(next.name) · "
                                 + String(format: "%.1f km/h, %d%%", next.targetSpeedKmh, next.targetIncline))
                                .font(.caption)
                                .foregroundStyle(Brand.fgDim)
                                .lineLimit(1)
                        } else {
                            Text("🏁 Last segment")
                                .font(.caption)
                                .foregroundStyle(Brand.fgDim)
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 0) {
                        // A szakasz-visszaszámláló a program lelke — nagyban.
                        Text(formattedTime(Int(segmentRemaining)))
                            .font(Brand.display(30, .bold))
                            .foregroundStyle(Brand.accent)
                            .contentTransition(.numericText(countsDown: true))
                        if let programRemaining = runner.programRemainingSeconds {
                            Text("Σ " + SessionFormat.duration(programRemaining))
                                .font(Brand.display(11, .medium))
                                .foregroundStyle(Brand.grey)
                        }
                    }
                    Button {
                        runner.stop()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Brand.danger)
                            .frame(width: 32, height: 32)
                            .background(Brand.bgElev2, in: RoundedRectangle(cornerRadius: Brand.radius))
                            .overlay(RoundedRectangle(cornerRadius: Brand.radius).stroke(Brand.gridLine))
                    }
                }
                if let progress = runner.programProgress {
                    programProgressBar(progress)
                }
            }
        }
        .brandBox(padding: 12)
    }

    /// Élesítés/padra várás — ugyanitt, felül.
    private var programArmingPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            BrandEyebrow(String(localized: "Program"))

            switch runner.runnerState {
            case .armed(let remaining):
                VStack(spacing: 10) {
                    Text("\(remaining)")
                        .font(Brand.display(64, .bold))
                        .foregroundStyle(Brand.accent)
                        .contentTransition(.numericText(countsDown: true))
                        .frame(maxWidth: .infinity)
                    Text("The belt starts in a moment. \(Safety.standClear)")
                        .font(.footnote)
                        .foregroundStyle(Brand.fgDim)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                    Button {
                        runner.cancelArm()
                    } label: {
                        Text("CANCEL").tracking(1.5)
                    }
                    .buttonStyle(BrandStrokeStyle(color: Brand.danger))
                }
            case .waitingForBelt:
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        ProgressView().tint(Brand.accent)
                        Text("TREADMILL STARTING…")
                            .font(Brand.display(13, .semibold))
                            .tracking(1.5)
                            .foregroundStyle(Brand.fgMid)
                    }
                    .frame(maxWidth: .infinity)
                    Button {
                        runner.cancelArm()
                    } label: {
                        Text("CANCEL").tracking(1.5)
                    }
                    .buttonStyle(BrandStrokeStyle(color: Brand.danger))
                }
            case .running, .suspended, .idle, .finished:
                // Ezeket az állapotokat a programPanel a kompakt sávra
                // irányítja, ide nem jutnak el.
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
