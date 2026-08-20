// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import CoreBluetooth
import Foundation

/// The treadmill's momentary state, intended for the UI.
struct TreadmillState: Equatable {
    var status: FitShow.Status = .idle
    var countdownSeconds: Int = 0
    var speedKmh: Double = 0
    var inclinePercent: Int = 0
    var elapsedSeconds: Int = 0
    var distanceKm: Double = 0
    var kcal: Int = 0
    var steps: Int = 0
    var heartRate: Int = 0

    var isRunning: Bool { status == .running }
}

enum ConnectionPhase: Equatable {
    case idle
    case scanning
    case connecting(name: String)
    case preparing(name: String)
    case ready(name: String)
    case bluetoothOff
}

struct DiscoveredTreadmill: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
}

/// BLE client for a FitShow-protocol treadmill.
///
/// How it works: after connecting it subscribes to the notify characteristic,
/// starts the 200 ms poll, and queries the speed/incline limits. Every command is
/// sent through a serial queue: re-sent every 200 ms, at most 3 attempts, and
/// acknowledged by the treadmill's command echo. The safety rule holds at the
/// client level too: only an explicit user action can start the belt.
@MainActor
final class FitShowTreadmillClient: NSObject, ObservableObject {

    @Published private(set) var phase: ConnectionPhase = .idle
    @Published private(set) var discovered: [DiscoveredTreadmill] = []
    @Published private(set) var state = TreadmillState()
    @Published private(set) var limits = TreadmillLimits()
    @Published var targetSpeedKmh: Double = 0.8
    @Published var targetIncline: Int = 0
    @Published var lostConnectionWhileRunning = false
    @Published private(set) var staleData = false
    @Published private(set) var lastError: String?
    @Published private(set) var variant: FitShowVariant = .standard

    /// How old the data in hand may be while the belt runs before `staleData` is
    /// raised. Named, because `ProgramRunner.maxTickSeconds` is derived from it: the
    /// runner may not credit a tick with more running than one frame is evidence
    /// for, and a bare literal here would let the two drift apart silently.
    nonisolated static let freshnessHorizonSeconds: TimeInterval = 3

    // The services observed in the 2019 Tunturi consoles' advertisements.
    private static let advertisedServices = [CBUUID(string: "E0FF"), CBUUID(string: "1826")]
    private static let preferredService = CBUUID(string: "FFE0")
    private static let serialServices = [CBUUID(string: "FFE0"), CBUUID(string: "FFF0")]
    private static let writeCharUUIDs = [CBUUID(string: "FFE1"), CBUUID(string: "FFF2")]
    private static let notifyCharUUIDs = [CBUUID(string: "FFE4"), CBUUID(string: "FFF1")]

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var peripheralsById: [UUID: CBPeripheral] = [:]
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var chosenServiceUUID: CBUUID?

    private var pollTimer: Timer?
    private var prepTimer: Timer?
    private var pending: [(payload: [UInt8], attempts: Int)] = []
    private var lastFrameAt: Date = .distantPast
    private var lastTargetCommandAt: Date = .distantPast
    private var targetsDirtyWhileNotRunning = false
    private var userWantsConnection = false
    private var pendingScanRequest = false
    private var variantDetector = FitShowVariantDetector()
    private var variantLocked = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Demo mode (simulator only — the simulator has no Bluetooth)

    private(set) var demoMode = false
    private var demoTimer: Timer?

    func startDemo() {
        demoMode = true
        lastError = nil
        state = TreadmillState()
        limits = TreadmillLimits()
        targetSpeedKmh = limits.minSpeedKmh
        targetIncline = 0
        phase = .ready(name: String(localized: "Demo treadmill (simulated)"))
        demoTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.demoTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        demoTimer = timer
    }

    private func stopDemo() {
        demoTimer?.invalidate()
        demoTimer = nil
        demoMode = false
        state = TreadmillState()
        phase = .idle
    }

    /// The fractional part of the demo step counter between two ticks.
    private var demoStepFraction = 0.0

    private func demoTick() {
        switch state.status {
        case .countdown:
            state.countdownSeconds -= 1
            if state.countdownSeconds <= 0 { state.status = .running }
        case .running:
            let diff = targetSpeedKmh - state.speedKmh
            state.speedKmh = max(0, ((state.speedKmh + max(-0.5, min(0.5, diff))) * 10).rounded() / 10)
            state.inclinePercent = targetIncline
            state.elapsedSeconds += 1
            state.distanceKm = ((state.distanceKm + state.speedKmh / 3600) * 1000).rounded() / 1000
            state.kcal = Int(Double(state.elapsedSeconds) * 0.11 * max(1, state.speedKmh / 6))
            // A realistic step rate: from walking to running, cadence is roughly
            // 1.7–3.0 steps/s, and does not grow linearly with speed. We accumulate
            // the fractional part, otherwise per-second rounding would wash it away.
            if state.speedKmh > 0 {
                demoStepFraction += 1.4 + state.speedKmh * 0.12
                let whole = demoStepFraction.rounded(.down)
                state.steps += Int(whole)
                demoStepFraction -= whole
            }
            state.heartRate = 78 + Int(state.speedKmh * 7) + Int.random(in: -2...2)
        default:
            break
        }
    }

    private func demoStart() {
        state.status = .countdown
        state.countdownSeconds = 3
    }

    private func demoStop() {
        state.status = .idle
        state.speedKmh = 0
        state.heartRate = 0
    }

    private func demoPause() {
        state.status = .paused
        state.speedKmh = 0
    }

    // MARK: - Kapcsolat

    func startScan() {
        lastError = nil
        switch central.state {
        case .poweredOn:
            pendingScanRequest = false
            discovered = []
            peripheralsById = [:]
            phase = .scanning
            central.scanForPeripherals(withServices: Self.advertisedServices)
        case .unknown, .resetting:
            // On a cold start the central's state is still .unknown — scanning starts
            // automatically when poweredOn arrives.
            pendingScanRequest = true
        default:
            phase = .bluetoothOff
        }
    }

    func stopScan() {
        pendingScanRequest = false
        central.stopScan()
        if phase == .scanning { phase = .idle }
    }

    func connect(to id: UUID) {
        guard let peripheral = peripheralsById[id] else { return }
        central.stopScan()
        userWantsConnection = true
        lastError = nil
        // A new device: the limits and targets learned from the previous treadmill do not apply.
        limits = TreadmillLimits()
        targetSpeedKmh = limits.minSpeedKmh
        targetIncline = 0
        targetsDirtyWhileNotRunning = false
        lostConnectionWhileRunning = false
        // Reload the previously detected frame variant for this device.
        if let stored = UserDefaults.standard.string(forKey: Self.variantKey(peripheral.identifier)),
           let storedVariant = FitShowVariant(rawValue: stored) {
            variant = storedVariant
            variantLocked = true
        } else {
            variant = .standard
            variantLocked = false
            variantDetector = FitShowVariantDetector()
        }
        self.peripheral = peripheral
        phase = .connecting(name: peripheral.name ?? String(localized: "Treadmill"))
        central.connect(peripheral)
        startPrepTimeout()
    }

    func disconnect() {
        if demoMode { return stopDemo() }
        userWantsConnection = false
        prepTimer?.invalidate()
        stopPolling()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        phase = .idle
    }

    // MARK: - Control (all of these are called by an explicit user action)

    /// Starting the belt from the dashboard. Only callable after a user confirmation!
    func userConfirmedStart() {
        startBelt(speedKmh: max(limits.minSpeedKmh, targetSpeedKmh), incline: targetIncline)
    }

    /// Starting the belt with given targets. For a program-driven start ProgramRunner
    /// calls this — exclusively after the user confirmation plus the cancellable
    /// app-side countdown.
    func startBelt(speedKmh: Double, incline: Int) {
        targetSpeedKmh = min(max(speedKmh, limits.minSpeedKmh), limits.maxSpeedKmh)
        targetIncline = min(max(incline, limits.minIncline), limits.maxIncline)
        targetsDirtyWhileNotRunning = false
        if demoMode { return demoStart() }
        enqueue(FitShowCommands.start)
        // Following the QZ pattern, we also send a target after starting.
        sendCurrentTargets()
    }

    func requestStop() {
        if demoMode { return demoStop() }
        enqueue(FitShowCommands.stop)
    }

    func requestPause() {
        if demoMode { return demoPause() }
        enqueue(FitShowCommands.pause)
    }

    func adjustSpeed(by delta: Double) {
        setTarget(speedKmh: targetSpeedKmh + delta, incline: targetIncline)
    }

    func adjustIncline(by delta: Int) {
        setTarget(speedKmh: targetSpeedKmh, incline: targetIncline + delta)
    }

    func setTarget(speedKmh: Double, incline: Int) {
        targetSpeedKmh = min(max(speedKmh, limits.minSpeedKmh), limits.maxSpeedKmh)
        targetIncline = min(max(incline, limits.minIncline), limits.maxIncline)
        if demoMode { return } // the demo tick follows the targets
        guard state.isRunning else {
            // We do not send on a standing/counting-down belt — we catch up on the
            // transition to running.
            targetsDirtyWhileNotRunning = true
            return
        }
        sendCurrentTargets()
    }

    private func sendCurrentTargets() {
        enqueue(FitShowCommands.setTarget(speedKmh: targetSpeedKmh,
                                          inclinePercent: targetIncline,
                                          limits: limits))
        lastTargetCommandAt = Date()
    }

    // MARK: - Command queue and poll

    private func enqueue(_ payload: [UInt8]) {
        // For the same CMD+sub we replace the not-yet-sent command (coalescing): two
        // quick "+" taps thus send a single, latest target, and a duplicated echo
        // cannot falsely acknowledge a command that was never sent.
        if payload.count >= 2,
           let index = pending.firstIndex(where: {
               $0.attempts == 0 && $0.payload.count >= 2
               && $0.payload[0] == payload[0] && $0.payload[1] == payload[1]
           }) {
            pending[index] = (payload, 0)
        } else {
            pending.append((payload, 0))
        }
    }

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        pending = []
    }

    private func tick() {
        guard writeCharacteristic != nil else { return }

        // Guarding data freshness: while running, older data is suspect — the
        // status and the speed in hand are then remembered values, not observations.
        staleData = state.isRunning
            && Date().timeIntervalSince(lastFrameAt) > Self.freshnessHorizonSeconds

        // An unacknowledged command drops out after 3 sends so it does not starve the poll.
        if let head = pending.first, head.attempts >= 3 {
            pending.removeFirst()
        }
        if !pending.isEmpty {
            write(pending[0].payload)
            pending[0].attempts += 1
        } else {
            write(FitShowCommands.statusPoll)
        }
    }

    private func write(_ payload: [UInt8]) {
        guard let peripheral, let characteristic = writeCharacteristic else { return }
        let type: CBCharacteristicWriteType =
            characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(FitShowFrame.encode(payload), for: characteristic, type: type)
    }

    // MARK: - Incoming frames

    private func handleNotification(_ data: Data) {
        guard let payload = FitShowFrame.decode(data) else { return }
        lastFrameAt = Date()

        // Acknowledging a command echo: the reply starts with the sent CMD(+sub)
        // bytes. Only an already sent command can be acknowledged.
        if let head = pending.first,
           head.attempts > 0,
           payload.first == head.payload.first,
           head.payload.count < 2 || payload.count < 2 || payload[1] == head.payload[1] {
            pending.removeFirst()
        }

        // Detecting the frame variant from running frames (AnyRun consoles send time
        // as a minute+second pair and the words big-endian). Once known, we remember
        // it per device.
        if !variantLocked,
           payload.count >= 14,
           payload.first == FitShow.Command.sysStatus.rawValue,
           payload[1] == FitShow.Status.running.rawValue {
            variantDetector.observeRunningFrame(payload)
            if let detected = variantDetector.detected {
                variant = detected
                variantLocked = true
                if let id = peripheral?.identifier {
                    UserDefaults.standard.set(detected.rawValue, forKey: Self.variantKey(id))
                }
            }
        }

        switch FitShowParser.parse(payload, variant: variant) {
        case .runData(let data):
            let wasRunning = state.isRunning
            state.status = data.status
            state.speedKmh = data.speedKmh
            state.inclinePercent = data.inclinePercent
            state.elapsedSeconds = data.elapsedSeconds
            state.distanceKm = data.distanceKm
            state.kcal = data.kcal
            state.steps = data.steps
            state.heartRate = data.heartRate
            if data.status == .running {
                reconcileTargets(with: data, justStarted: !wasRunning)
            }
        case .idle:
            state.status = .idle
            state.speedKmh = 0
            state.countdownSeconds = 0
        case .countdown(let seconds):
            state.status = .countdown
            state.countdownSeconds = seconds
        case .statusOnly(let status):
            state.status = status
        case .speedLimits(let maxRaw, let minRaw) where maxRaw > 0:
            limits.maxSpeedRaw = maxRaw
            limits.minSpeedRaw = max(minRaw, 0)
            limits.fromDevice = true
        case .inclineLimits(let max, let min, _):
            limits.maxIncline = max
            limits.minIncline = min
            limits.fromDevice = true
        case .inclineUnsupported:
            limits.maxIncline = 0
            limits.minIncline = 0
        case .extendedLimits(let maxSpeedRaw, let minSpeedRaw, let maxIncline, let minIncline)
            where maxSpeedRaw > 0:
            limits.maxSpeedRaw = maxSpeedRaw
            limits.minSpeedRaw = max(minSpeedRaw, 0)
            limits.maxIncline = maxIncline
            limits.minIncline = minIncline
            limits.fromDevice = true
        case .controlAck, .other, .speedLimits, .extendedLimits:
            break
        }
    }

    private static func variantKey(_ id: UUID) -> String {
        "fitshow.variant.\(id.uuidString)"
    }

    /// Reconciling the target and actual values so a "+" tap always steps relative to
    /// the real speed — never commanding a large jump.
    private func reconcileTargets(with data: RunData, justStarted: Bool) {
        if justStarted && targetsDirtyWhileNotRunning {
            // A target set during the countdown/pause is applied on the transition to running.
            targetsDirtyWhileNotRunning = false
            sendCurrentTargets()
            return
        }
        // If we have not commanded for a long time (started/adjusted from the
        // console), let the target follow the actual values.
        if Date().timeIntervalSince(lastTargetCommandAt) > 10 {
            if abs(targetSpeedKmh - data.speedKmh) >= 0.1, data.speedKmh > 0 {
                targetSpeedKmh = data.speedKmh
            }
            if targetIncline != data.inclinePercent {
                targetIncline = data.inclinePercent
            }
        }
    }

    private func deviceReady() {
        guard case .preparing(let name) = phase else { return }
        prepTimer?.invalidate()
        phase = .ready(name: name)
        startPolling()
        // The order matters: startPolling empties the queue, so the limit queries can
        // only be enqueued after it.
        enqueue(FitShowCommands.infoSpeed)
        enqueue(FitShowCommands.infoIncline)
        enqueue(FitShowCommands.infoExtended)
    }

    // MARK: - Hibautak

    private func startPrepTimeout() {
        prepTimer?.invalidate()
        let timer = Timer(timeInterval: 15, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.preparationTimedOut() }
        }
        RunLoop.main.add(timer, forMode: .common)
        prepTimer = timer
    }

    private func preparationTimedOut() {
        switch phase {
        case .connecting:
            failPreparation(String(localized: "Couldn't connect to the device."))
        case .preparing:
            failPreparation(String(localized: "The device isn't responding — it may not be a FitShow console."))
        default:
            break
        }
    }

    private func failPreparation(_ message: String) {
        prepTimer?.invalidate()
        userWantsConnection = false
        stopPolling()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        writeCharacteristic = nil
        notifyCharacteristic = nil
        chosenServiceUUID = nil
        lastError = message
        phase = .idle
    }

    /// A full cleanup for when the link dies without the delegate callbacks (for
    /// example Bluetooth being turned off — there is no didDisconnectPeripheral then).
    private func teardownAfterRadioLoss() {
        prepTimer?.invalidate()
        stopPolling()
        if state.isRunning { lostConnectionWhileRunning = true }
        state = TreadmillState()
        writeCharacteristic = nil
        notifyCharacteristic = nil
        chosenServiceUUID = nil
        peripheral = nil
        peripheralsById = [:]
        discovered = []
        userWantsConnection = false
    }
}

// MARK: - CBCentralManagerDelegate / CBPeripheralDelegate
// The central runs on the main queue, so the delegate calls arrive on the MainActor.

extension FitShowTreadmillClient: @preconcurrency CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if phase == .bluetoothOff { phase = .idle }
            if pendingScanRequest { startScan() }
        case .poweredOff, .unauthorized, .unsupported, .resetting:
            // When the radio goes down the system does not send
            // didDisconnectPeripheral, so the cleanup has to happen here (timer,
            // characteristics, alert).
            teardownAfterRadioLoss()
            phase = .bluetoothOff
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        peripheralsById[peripheral.identifier] = peripheral
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? String(localized: "Unknown device")
        let item = DiscoveredTreadmill(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        if let index = discovered.firstIndex(where: { $0.id == item.id }) {
            discovered[index] = item
        } else {
            discovered.append(item)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        phase = .preparing(name: peripheral.name ?? String(localized: "Treadmill"))
        peripheral.delegate = self
        peripheral.discoverServices(Self.serialServices)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        failPreparation(String(localized: "Couldn't connect to the device."))
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        // A late-arriving disconnect belonging to an earlier device must not touch the state.
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        prepTimer?.invalidate()
        stopPolling()
        writeCharacteristic = nil
        notifyCharacteristic = nil
        chosenServiceUUID = nil
        if state.isRunning { lostConnectionWhileRunning = true }
        state = TreadmillState()
        if userWantsConnection {
            // connect() never expires: as soon as the treadmill is reachable again, we reconnect.
            phase = .connecting(name: peripheral.name ?? String(localized: "Treadmill"))
            central.connect(peripheral)
            startPrepTimeout()
        } else {
            phase = .idle
        }
    }
}

extension FitShowTreadmillClient: @preconcurrency CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        guard error == nil else {
            return failPreparation(String(localized: "Service discovery error."))
        }
        let serialServices = (peripheral.services ?? []).filter { Self.serialServices.contains($0.uuid) }
        guard !serialServices.isEmpty else {
            return failPreparation(String(localized: "This device doesn't use the FitShow protocol (no serial service)."))
        }
        for service in serialServices {
            peripheral.discoverCharacteristics(Self.writeCharUUIDs + Self.notifyCharUUIDs, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier, error == nil else { return }
        // The write and notify characteristics have to come from the same service,
        // otherwise we would write to one bridge and listen on the other.
        // 0xFFE0 is the primary one on Tunturis; 0xFFF0 is the fallback.
        if let chosen = chosenServiceUUID,
           chosen == Self.preferredService || service.uuid != Self.preferredService {
            return
        }
        let characteristics = service.characteristics ?? []
        guard let write = characteristics.first(where: { Self.writeCharUUIDs.contains($0.uuid) }),
              let notify = characteristics.first(where: { Self.notifyCharUUIDs.contains($0.uuid) })
        else { return }
        if let previous = notifyCharacteristic, previous.uuid != notify.uuid {
            // Switching to the preferred service: we cancel the old subscription so
            // frames do not arrive twice.
            peripheral.setNotifyValue(false, for: previous)
        }
        chosenServiceUUID = service.uuid
        writeCharacteristic = write
        notifyCharacteristic = notify
        peripheral.setNotifyValue(true, for: notify)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        guard error == nil else {
            return failPreparation(String(localized: "Couldn't subscribe to the device's data."))
        }
        guard characteristic.uuid == notifyCharacteristic?.uuid,
              characteristic.isNotifying,
              writeCharacteristic != nil else { return }
        deviceReady()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier,
              error == nil, let data = characteristic.value else { return }
        handleNotification(data)
    }
}
