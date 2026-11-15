import Foundation
import CoreBluetooth
import Combine
import os.log

#if os(watchOS)
import WatchKit
#elseif canImport(UIKit)
import UIKit
import AudioToolbox
#endif

// MARK: - Cross-Platform Device Haptics & Battery Helper

enum DeviceHapticEvent {
    case notification
    case ring
    case click
    case start
    case stop
    case directionUp
    case success
}

@MainActor
enum PlatformDeviceBridge {

    static func enableBatteryMonitoring() {
        #if os(watchOS)
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        #elseif canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
    }

    /// Returns device battery percentage (`0...100`), or `88` on Simulator where battery level is `-1.0`
    static func currentBatteryPercentage() -> Int {
        #if os(watchOS)
        let rawLevel = WKInterfaceDevice.current().batteryLevel
        #elseif canImport(UIKit)
        let rawLevel = UIDevice.current.batteryLevel
        #else
        let rawLevel: Float = -1.0
        #endif

        if rawLevel >= 0.0 {
            return Int((rawLevel * 100.0).rounded())
        } else {
            return 88
        }
    }

    static var localDeviceTitle: String {
        #if os(watchOS)
        return "Watch"
        #else
        return "iPhone"
        #endif
    }

    static var localDeviceIcon: String {
        #if os(watchOS)
        return "applewatch"
        #else
        return "iphone"
        #endif
    }

    static func playHaptic(_ event: DeviceHapticEvent) {
        #if os(watchOS)
        let device = WKInterfaceDevice.current()
        switch event {
        case .notification:
            device.play(.notification)
        case .ring:
            device.play(.ring)
        case .click:
            device.play(.click)
        case .start:
            device.play(.start)
        case .stop:
            device.play(.stop)
        case .directionUp:
            device.play(.directionUp)
        case .success:
            device.play(.success)
        }
        #elseif canImport(UIKit)
        switch event {
        case .notification:
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.warning)
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        case .ring:
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.error)
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        case .click:
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
        case .start:
            let generator = UIImpactFeedbackGenerator(style: .heavy)
            generator.impactOccurred()
        case .stop:
            let generator = UIImpactFeedbackGenerator(style: .rigid)
            generator.impactOccurred()
        case .directionUp:
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
        case .success:
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
        }
        #endif
    }
}

/// Manages the watchOS & iOS CoreBluetooth `CBPeripheralManager` lifecycle, GATT service/characteristic registration,
/// background state restoration, chunked JSON packet reassembly, CallKit incoming call reporting, battery sync, and native haptics.
@MainActor
final class BLEPeripheralManager: NSObject, ObservableObject {

    // MARK: - Published UI State

    /// Current BLE peripheral state (`Connected`, `Advertising`, `Standby`, `Bluetooth Off`)
    @Published private(set) var connectionState: BLEConnectionState = .idle

    /// User-controlled toggle binding to start/stop BLE peripheral advertising
    @Published var isBroadcastingEnabled: Bool = true {
        didSet {
            guard oldValue != isBroadcastingEnabled else { return }
            handleBroadcastingToggle(enabled: isBroadcastingEnabled)
        }
    }

    /// Local Apple Watch / iPhone real battery percentage (`0...100`)
    @Published private(set) var watchBatteryPercent: Int = 100

    /// Android smartphone battery percentage (`0...100`), updated when Android writes to `6E400004`
    @Published private(set) var androidBatteryPercent: Int? = nil

    /// Scrollable feed of received Android notifications (newest first)
    @Published private(set) var notifications: [AndroidNotification] = []

    /// Active incoming call alert; presents the full-screen call alert view when `callState == .ringing`
    @Published var activeCallAlert: CallAlert? = nil

    /// Most recently sent command and timestamp for UI feedback
    @Published private(set) var lastSentCommand: BLECommand? = nil
    @Published private(set) var lastCommandTimestamp: Date? = nil

    /// Media playback state tracked locally for the Play/Pause button icon
    @Published private(set) var isPlayingMedia: Bool = false

    /// Diagnostic status message for packet reassembly and GATT events
    @Published private(set) var lastEventLog: String = "Initializing CoreBluetooth..."

    // MARK: - On-Screen BLE JSON & CallKit Debug Banner State

    /// Full reassembled JSON string most recently received on `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`
    @Published private(set) var latestReceivedBLEJSON: String = "Waiting for BLE JSON on 6E400002..."

    /// Latest raw BLE write chunk string received before/during reassembly
    @Published private(set) var latestReceivedRawChunk: String = "No BLE chunks received yet"

    /// Latest CallKit provider status message
    @Published private(set) var latestCallKitStatus: String = "CallKit Ready"

    /// Total count of BLE write packets received on `6E400002`
    @Published private(set) var receivedPacketCount: Int = 0

    // MARK: - Private CoreBluetooth & CallKit Properties

    private let logger = Logger(subsystem: "com.oswatch.companion", category: "BLEPeripheralManager")
    private let packetReassembler = BLEPacketReassembler()
    private let callKitManager = CallKitManager.shared

    private var peripheralManager: CBPeripheralManager!
    private var primaryService: CBMutableService?
    private var rxCharacteristic: CBMutableCharacteristic?
    private var txCharacteristic: CBMutableCharacteristic?
    private var batteryCharacteristic: CBMutableCharacteristic?

    /// Connected Android centrals currently subscribed to our TX/Notify characteristic
    private var subscribedCentrals: Set<CBCentral> = []

    /// Outgoing command queue if `updateValue(_:for:onSubscribedCentrals:)` returns `false` (TX buffer full)
    private var pendingOutgoingPayloads: [Data] = []

    /// Repeating timers for battery polling and incoming call ringing haptics
    private var batteryMonitorTimer: Timer?
    private var callHapticTimer: Timer?

    // MARK: - Initialization

    override init() {
        super.init()
        configureCallKitCallbacks()
        configureWatchBatteryMonitoring()
        initializePeripheralManager()
    }

    // MARK: - Setup & Configuration

    private func configureCallKitCallbacks() {
        callKitManager.onCallKitStatusUpdate = { [weak self] status in
            self?.latestCallKitStatus = status
        }

        callKitManager.onUserCallResponse = { [weak self] response in
            guard let self = self else { return }
            self.stopCallRingingHaptics()
            self.activeCallAlert = nil

            switch response {
            case .answered:
                self.lastEventLog = "Call answered via CallKit"
                self.sendCommand(.answerCall)
            case .declined:
                self.lastEventLog = "Call declined via CallKit"
                self.sendCommand(.declineCall)
            case .timedOut:
                self.lastEventLog = "CallKit auto-timeout (35s)"
            }
        }
    }

    private func initializePeripheralManager() {
        let options: [String: Any] = [
            CBPeripheralManagerOptionRestoreIdentifierKey: GATTConstants.restoreIdentifier,
            CBPeripheralManagerOptionShowPowerAlertKey: true
        ]
        peripheralManager = CBPeripheralManager(
            delegate: self,
            queue: .main,
            options: options
        )
    }

    private func configureWatchBatteryMonitoring() {
        PlatformDeviceBridge.enableBatteryMonitoring()
        refreshWatchBatteryLevel()

        batteryMonitorTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshWatchBatteryLevel()
            }
        }
    }

    /// Reads real battery level on watchOS (`WKInterfaceDevice`) or iOS (`UIDevice`)
    func refreshWatchBatteryLevel() {
        watchBatteryPercent = PlatformDeviceBridge.currentBatteryPercentage()
    }

    // MARK: - GATT Service & Characteristic Registration

    private func setupGATTServiceIfNeeded() {
        guard primaryService == nil, peripheralManager.state == .poweredOn else { return }

        // 1. RX Characteristic (6E400002): Write & WriteWithoutResponse for chunked JSON from Android
        let rxChar = CBMutableCharacteristic(
            type: GATTConstants.rxCharacteristicUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )

        // 2. TX Characteristic (6E400003): Notify for commands from Watch/iPhone -> Android
        let txChar = CBMutableCharacteristic(
            type: GATTConstants.txCharacteristicUUID,
            properties: [.notify],
            value: nil,
            permissions: [.readable]
        )

        // 3. Battery Characteristic (6E400004): Read (Watch/iPhone %) & Write (Android %)
        let batChar = CBMutableCharacteristic(
            type: GATTConstants.batteryCharacteristicUUID,
            properties: [.read, .write, .writeWithoutResponse, .notify],
            value: nil,
            permissions: [.readable, .writeable]
        )

        let service = CBMutableService(type: GATTConstants.serviceUUID, primary: true)
        service.characteristics = [rxChar, txChar, batChar]

        self.rxCharacteristic = rxChar
        self.txCharacteristic = txChar
        self.batteryCharacteristic = batChar
        self.primaryService = service

        peripheralManager.removeAllServices()
        peripheralManager.add(service)
        logger.info("Registering primary GATT service \(GATTConstants.serviceUUID.uuidString)")
    }

    // MARK: - BLE Advertising Control

    private func handleBroadcastingToggle(enabled: Bool) {
        PlatformDeviceBridge.playHaptic(.click)
        if enabled {
            startAdvertisingIfPossible()
        } else {
            stopAdvertising()
        }
    }

    func startAdvertisingIfPossible() {
        guard isBroadcastingEnabled else {
            updateConnectionState()
            return
        }

        guard peripheralManager.state == .poweredOn else {
            updateConnectionState()
            return
        }

        setupGATTServiceIfNeeded()

        if !peripheralManager.isAdvertising {
            let advertisementData: [String: Any] = [
                CBAdvertisementDataServiceUUIDsKey: [GATTConstants.serviceUUID],
                CBAdvertisementDataLocalNameKey: GATTConstants.advertisedLocalName
            ]
            peripheralManager.startAdvertising(advertisementData)
            lastEventLog = "Advertising \(GATTConstants.advertisedLocalName)"
            logger.info("Started BLE advertising for service \(GATTConstants.serviceUUID.uuidString)")
        }

        updateConnectionState()
    }

    func stopAdvertising() {
        if peripheralManager.isAdvertising {
            peripheralManager.stopAdvertising()
            logger.info("Stopped BLE advertising")
        }
        subscribedCentrals.removeAll()
        packetReassembler.resetAll()
        lastEventLog = "BLE broadcasting paused"
        updateConnectionState()
    }

    private func updateConnectionState() {
        switch peripheralManager.state {
        case .poweredOff:
            connectionState = .bluetoothOff
        case .unauthorized:
            connectionState = .unauthorized
        case .poweredOn:
            if !subscribedCentrals.isEmpty {
                connectionState = .connected(centralCount: subscribedCentrals.count)
            } else if isBroadcastingEnabled && peripheralManager.isAdvertising {
                connectionState = .advertising
            } else if isBroadcastingEnabled {
                connectionState = .advertising
            } else {
                connectionState = .idle
            }
        default:
            connectionState = .idle
        }
    }

    // MARK: - Outgoing Commands (Watch/iPhone -> Android via 6E400003)

    /// Sends a command (`PLAY_PAUSE`, `NEXT`, `PREV`, `FIND_PHONE`, `ANSWER_CALL`, `DECLINE_CALL`) over `6E400003`.
    func sendCommand(_ command: BLECommand) {
        switch command {
        case .findPhone:
            PlatformDeviceBridge.playHaptic(.start)
        case .playPause:
            isPlayingMedia.toggle()
            PlatformDeviceBridge.playHaptic(.click)
        case .next, .prev:
            PlatformDeviceBridge.playHaptic(.directionUp)
        case .answerCall:
            PlatformDeviceBridge.playHaptic(.success)
        case .declineCall:
            PlatformDeviceBridge.playHaptic(.stop)
        }

        lastSentCommand = command
        lastCommandTimestamp = Date()

        guard let payloadData = command.rawValue.data(using: .utf8) else { return }

        guard
            peripheralManager.state == .poweredOn,
            let txCharacteristic = txCharacteristic
        else {
            lastEventLog = "Queued \(command.rawValue) (BLE not ready)"
            logger.warning("Cannot send \(command.rawValue): peripheral not powered on or TX missing")
            return
        }

        let sentImmediately = peripheralManager.updateValue(
            payloadData,
            for: txCharacteristic,
            onSubscribedCentrals: nil
        )

        if sentImmediately {
            lastEventLog = "Sent \(command.rawValue) to Android"
            logger.info("Sent command '\(command.rawValue)' via notify characteristic")
        } else {
            pendingOutgoingPayloads.append(payloadData)
            lastEventLog = "Buffered \(command.rawValue) for transmission"
            logger.debug("TX queue full; buffered command '\(command.rawValue)'")
        }
    }

    private func flushPendingOutgoingPayloads() {
        guard let txCharacteristic = txCharacteristic, peripheralManager.state == .poweredOn else { return }

        while let nextPayload = pendingOutgoingPayloads.first {
            let success = peripheralManager.updateValue(
                nextPayload,
                for: txCharacteristic,
                onSubscribedCentrals: nil
            )
            if success {
                pendingOutgoingPayloads.removeFirst()
            } else {
                break
            }
        }
    }

    // MARK: - Notification & Call Management

    /// Clears all stored Android notifications and plays a subtle haptic confirmation.
    func clearAllNotifications() {
        PlatformDeviceBridge.playHaptic(.click)
        notifications.removeAll()
        lastEventLog = "Cleared all notifications"
    }

    /// Removes a specific notification by ID
    func removeNotification(id: String) {
        notifications.removeAll { $0.id == id }
    }

    /// Dismisses or silences the active incoming call overlay and ends any active CallKit session
    func dismissActiveCallAlert() {
        stopCallRingingHaptics()
        activeCallAlert = nil
        callKitManager.endActiveCall()
        sendCommand(.declineCall)
    }

    // MARK: - Unified CallKit Trigger & Incoming Payload Handler

    /// Single unified entry point that triggers `CallKitManager.shared.reportIncomingCall(...)`,
    /// sets the in-app `activeCallAlert`, and starts ringing haptics.
    /// Used identically by both the Demo Call button and live BLE payloads from Android (`6E400002`).
    func triggerCallKitIncomingCall(callerName: String, app: String, phoneNumber: String) {
        let alert = CallAlert(
            callerName: callerName,
            phoneNumber: phoneNumber,
            app: app,
            callState: .ringing
        )
        activeCallAlert = alert
        lastEventLog = "Call (\(alert.app)): \(alert.callerName)"
        latestCallKitStatus = "Triggering CallKit: \(alert.callerName) (\(alert.app))"

        callKitManager.reportIncomingCall(
            callerName: alert.callerName,
            app: alert.app,
            phoneNumber: alert.phoneNumber
        )
        startCallRingingHaptics()
    }

    /// Processes a reassembled BLE payload and routes any call (`type == "call"`, `cat == "call"`, `isOngoingCall == true`,
    /// or call keywords `incoming call`, `voice call`, `video call`, `ringing`, `is calling`) directly to `triggerCallKitIncomingCall`.
    private func handleDecodedPayload(_ payload: IncomingBLEPayload, rawJSON: String) {
        latestReceivedBLEJSON = rawJSON

        switch payload {
        case .callAlert(let callAlert):
            logger.info("Decoded CallAlert payload: \(callAlert.callerName) via \(callAlert.app) (\(callAlert.callState.rawValue))")

            if callAlert.isRinging {
                triggerCallKitIncomingCall(
                    callerName: callAlert.callerName,
                    app: callAlert.app,
                    phoneNumber: callAlert.phoneNumber
                )
            } else {
                stopCallRingingHaptics()
                activeCallAlert = nil
                callKitManager.endActiveCall()
                lastEventLog = "Call ended: \(callAlert.callerName)"
                latestCallKitStatus = "Call Ended: \(callAlert.callerName)"
            }

        case .notification(let notification):
            // Double-check if the notification title/body/rawJSON contains any call keyword
            let combined = "\(notification.appName) \(notification.title) \(notification.body) \(rawJSON)"
            if IncomingBLEPayload.containsCallKeyword(in: combined) {
                logger.info("Notification matched call keyword; promoting to CallKit incoming call: \(notification.title)")
                triggerCallKitIncomingCall(
                    callerName: notification.title,
                    app: notification.appName,
                    phoneNumber: notification.body
                )
                return
            }

            notifications.removeAll { $0.id == notification.id }
            notifications.insert(notification, at: 0)

            PlatformDeviceBridge.playHaptic(.notification)
            lastEventLog = "Notification from \(notification.appName)"
            logger.info("Received Android notification [\(notification.appName)]: \(notification.title)")
        }
    }

    private func startCallRingingHaptics() {
        stopCallRingingHaptics()
        PlatformDeviceBridge.playHaptic(.ring)

        callHapticTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.activeCallAlert?.isRinging == true else {
                    self?.stopCallRingingHaptics()
                    return
                }
                PlatformDeviceBridge.playHaptic(.ring)
            }
        }
    }

    private func stopCallRingingHaptics() {
        callHapticTimer?.invalidate()
        callHapticTimer = nil
    }

    // MARK: - Battery Payload Parsing (`6E400004`)

    /// Encodes the local Watch/iPhone battery percentage (`0...100`) for GATT Read requests.
    private func encodedWatchBatteryData() -> Data {
        refreshWatchBatteryLevel()
        let clamped = max(0, min(100, watchBatteryPercent))
        return Data("\(clamped)".utf8)
    }

    /// Parses the Android phone battery level written to `6E400004`.
    private func handleAndroidBatteryWrite(_ data: Data) {
        guard !data.isEmpty else { return }

        if data.count == 1 {
            let byteVal = Int(data[0])
            if byteVal <= 100 {
                androidBatteryPercent = byteVal
                lastEventLog = "Android battery synced: \(byteVal)%"
                return
            }
        }

        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            let cleaned = text.replacingOccurrences(of: "%", with: "")
            if let value = Int(cleaned), (0...100).contains(value) {
                androidBatteryPercent = value
                lastEventLog = "Android battery synced: \(value)%"
                return
            }

            if let jsonObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let level = (jsonObj["battery"] as? Int) ?? (jsonObj["level"] as? Int) {
                let clamped = max(0, min(100, level))
                androidBatteryPercent = clamped
                lastEventLog = "Android battery synced: \(clamped)%"
                return
            }
        }
    }

    // MARK: - Simulator / On-Device Demo Helpers

    /// Feeds a realistic 3-chunk BLE notification through `BLEPacketReassembler` for testing
    func simulateChunkedNotification() {
        let timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
        let samples: [(app: String, title: String, body: String)] = [
            ("WhatsApp", "Liam Carter", "Hey! Just landed at SFO. Are you near Terminal 2?"),
            ("Gmail", "Security Alert", "New sign-in detected on your Google Pixel 9 Pro."),
            ("Slack", "#watchos-ble", "Chunked GATT packet reassembler verified at 100% delivery."),
            ("Telegram", "Elena Rostova", "Sent you the updated circuit schematics for the prototype.")
        ]
        let pick = samples.randomElement()!
        let id = UUID().uuidString.prefix(8)

        let chunk1 = #"1/3|{"id":"\#(id)","appName":"\#(pick.app)","title":"\#(pick.title)","#
        let chunk2 = #"2/3|"body":"\#(pick.body)","#
        let chunk3 = #"3/3|"timestamp":\#(timestampMs)}"#

        do {
            _ = try packetReassembler.ingestPacket(chunkString: chunk1, from: "simulator")
            _ = try packetReassembler.ingestPacket(chunkString: chunk2, from: "simulator")
            if let reassembled = try packetReassembler.ingestPacket(chunkString: chunk3, from: "simulator") {
                handleDecodedPayload(reassembled.payload, rawJSON: reassembled.jsonString)
            }
            if androidBatteryPercent == nil {
                androidBatteryPercent = 76
            }
        } catch {
            logger.error("Simulator chunk test error: \(error.localizedDescription)")
        }
    }

    /// Demo Call button handler: feeds a 2-chunk Android BLE bridge call payload through `packetReassembler`
    /// and invokes the exact same `handleDecodedPayload` -> `triggerCallKitIncomingCall` path as live BLE writes!
    func simulateIncomingCall() {
        let chunk1 = #"1/2|{"type":"call","cat":"call","isOngoingCall":true,"app":"WhatsApp","#
        let chunk2 = #"2/2|"title":"Sarah Jenkins","body":"Incoming voice call"}"#

        latestReceivedRawChunk = chunk2

        do {
            _ = try packetReassembler.ingestPacket(chunkString: chunk1, from: "simulator")
            if let reassembled = try packetReassembler.ingestPacket(chunkString: chunk2, from: "simulator") {
                handleDecodedPayload(reassembled.payload, rawJSON: reassembled.jsonString)
            }
        } catch {
            logger.error("Demo Call error: \(error.localizedDescription)")
            triggerCallKitIncomingCall(callerName: "Sarah Jenkins", app: "WhatsApp", phoneNumber: "Incoming voice call")
        }
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BLEPeripheralManager: CBPeripheralManagerDelegate {

    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { @MainActor in
            logger.info("CBPeripheralManager state updated: \(String(describing: peripheral.state.rawValue))")
            switch peripheral.state {
            case .poweredOn:
                setupGATTServiceIfNeeded()
                if isBroadcastingEnabled {
                    startAdvertisingIfPossible()
                } else {
                    updateConnectionState()
                }
            case .poweredOff:
                subscribedCentrals.removeAll()
                updateConnectionState()
                lastEventLog = "Bluetooth powered off"
            case .unauthorized:
                updateConnectionState()
                lastEventLog = "Bluetooth permission denied"
            default:
                updateConnectionState()
            }
        }
    }

    /// Background State Restoration handler (`bluetooth-peripheral`)
    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        willRestoreState dict: [String: Any]
    ) {
        Task { @MainActor in
            logger.info("Restoring CBPeripheralManager state from background")

            if let restoredServices = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] {
                for service in restoredServices where service.uuid == GATTConstants.serviceUUID {
                    self.primaryService = service
                    for characteristic in service.characteristics ?? [] {
                        guard let mutableChar = characteristic as? CBMutableCharacteristic else { continue }
                        switch mutableChar.uuid {
                        case GATTConstants.rxCharacteristicUUID:
                            self.rxCharacteristic = mutableChar
                        case GATTConstants.txCharacteristicUUID:
                            self.txCharacteristic = mutableChar
                            if let centrals = mutableChar.subscribedCentrals {
                                self.subscribedCentrals.formUnion(centrals)
                            }
                        case GATTConstants.batteryCharacteristicUUID:
                            self.batteryCharacteristic = mutableChar
                        default:
                            break
                        }
                    }
                }
            }

            lastEventLog = "Restored background BLE state"
            updateConnectionState()
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didAdd service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            if let error = error {
                logger.error("Failed to add GATT service: \(error.localizedDescription)")
                lastEventLog = "Service error: \(error.localizedDescription)"
                return
            }
            logger.info("Successfully published GATT service \(service.uuid.uuidString)")
            if isBroadcastingEnabled {
                startAdvertisingIfPossible()
            }
        }
    }

    nonisolated func peripheralManagerDidStartAdvertising(
        _ peripheral: CBPeripheralManager,
        error: Error?
    ) {
        Task { @MainActor in
            if let error = error {
                logger.error("BLE advertising failed: \(error.localizedDescription)")
                lastEventLog = "Adv error: \(error.localizedDescription)"
            } else {
                logger.info("BLE peripheral actively advertising")
            }
            updateConnectionState()
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        Task { @MainActor in
            subscribedCentrals.insert(central)
            updateConnectionState()
            PlatformDeviceBridge.playHaptic(.success)
            lastEventLog = "Android host connected"
            logger.info("Central \(central.identifier.uuidString) subscribed to \(characteristic.uuid.uuidString)")
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        Task { @MainActor in
            subscribedCentrals.remove(central)
            updateConnectionState()
            lastEventLog = "Android host disconnected"
            logger.info("Central \(central.identifier.uuidString) unsubscribed from \(characteristic.uuid.uuidString)")

            if isBroadcastingEnabled && subscribedCentrals.isEmpty {
                startAdvertisingIfPossible()
            }
        }
    }

    /// Handles GATT Read requests on `6E400004` (Watch / iPhone battery percentage)
    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveRead request: CBATTRequest
    ) {
        Task { @MainActor in
            guard request.characteristic.uuid == GATTConstants.batteryCharacteristicUUID else {
                peripheral.respond(to: request, withResult: .requestNotSupported)
                return
            }

            let batteryData = encodedWatchBatteryData()
            if request.offset > batteryData.count {
                peripheral.respond(to: request, withResult: .invalidOffset)
                return
            }

            request.value = batteryData.subdata(in: request.offset..<batteryData.count)
            peripheral.respond(to: request, withResult: .success)
            lastEventLog = "Served battery (\(watchBatteryPercent)%)"
        }
    }

    /// Handles GATT Write & WriteWithoutResponse requests on `6E400002` (chunked JSON) and `6E400004` (Android battery)
    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        Task { @MainActor in
            for request in requests {
                subscribedCentrals.insert(request.central)
                updateConnectionState()

                guard let value = request.value else {
                    peripheral.respond(to: request, withResult: .invalidAttributeValueLength)
                    continue
                }

                switch request.characteristic.uuid {
                case GATTConstants.rxCharacteristicUUID:
                    receivedPacketCount += 1
                    let rawChunkText = String(decoding: value, as: UTF8.self)
                        .replacingOccurrences(of: "\0", with: "")
                    latestReceivedRawChunk = rawChunkText

                    do {
                        let sourceID = request.central.identifier.uuidString
                        if let reassembled = try packetReassembler.ingestPacket(data: value, from: sourceID) {
                            handleDecodedPayload(reassembled.payload, rawJSON: reassembled.jsonString)
                        } else {
                            let bufferedCount = packetReassembler.bufferedChunkCount(for: sourceID)
                            lastEventLog = "Buffering chunk (\(bufferedCount) parts)..."
                        }
                        peripheral.respond(to: request, withResult: .success)
                    } catch {
                        logger.error("Packet reassembly error: \(error.localizedDescription)")
                        latestReceivedBLEJSON = rawChunkText
                        lastEventLog = "Parse fallback on packet #\(receivedPacketCount)"

                        // Emergency fallback: If raw text contains call flags or keywords, trigger CallKit immediately!
                        let lower = rawChunkText.lowercased()
                        if lower.contains("\"type\":\"call\"") ||
                           lower.contains("\"type\": \"call\"") ||
                           lower.contains("\"cat\":\"call\"") ||
                           lower.contains("\"cat\": \"call\"") ||
                           lower.contains("\"isongoingcall\":true") ||
                           lower.contains("\"isongoingcall\": true") ||
                           IncomingBLEPayload.containsCallKeyword(in: lower) {
                            let caller = IncomingBLEPayload.extractJSONStringValue(
                                from: rawChunkText,
                                keys: ["title", "callerName", "sender", "name"]
                            ) ?? "Incoming Call"
                            let app = IncomingBLEPayload.extractJSONStringValue(
                                from: rawChunkText,
                                keys: ["app", "appName", "pkg"]
                            ) ?? "Phone"
                            let phone = IncomingBLEPayload.extractJSONStringValue(
                                from: rawChunkText,
                                keys: ["body", "text", "phoneNumber", "message"]
                            ) ?? "Incoming Call"
                            triggerCallKitIncomingCall(callerName: caller, app: app, phoneNumber: phone)
                        }
                        peripheral.respond(to: request, withResult: .success)
                    }

                case GATTConstants.batteryCharacteristicUUID:
                    handleAndroidBatteryWrite(value)
                    peripheral.respond(to: request, withResult: .success)

                default:
                    peripheral.respond(to: request, withResult: .requestNotSupported)
                }
            }
        }
    }

    nonisolated func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        Task { @MainActor in
            flushPendingOutgoingPayloads()
        }
    }
}
