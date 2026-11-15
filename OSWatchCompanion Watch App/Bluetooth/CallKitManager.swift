import Foundation
import os.log

#if canImport(CallKit) && os(iOS)
import CallKit
import AVFoundation

/// Dedicated CallKit manager using `CXProvider` and `CXCallController` to trigger
/// the native iOS full-screen Incoming Call UI and iPhone ringtone when an Android call payload arrives over BLE.
@MainActor
final class CallKitManager: NSObject {

    // MARK: - Nested Types

    enum UserCallResponse {
        case answered
        case declined
        case timedOut
    }

    // MARK: - Properties

    static let shared = CallKitManager()

    private let logger = Logger(subsystem: "com.oswatch.companion", category: "CallKitManager")
    private let provider: CXProvider
    private let callController = CXCallController()

    /// UUID of the currently ringing/active CallKit session
    private(set) var activeCallUUID: UUID?

    /// Auto-timeout interval (35 seconds) to close the CallKit screen automatically if Android stops ringing
    private let autoTimeoutInterval: TimeInterval = 35.0
    private var autoTimeoutTimer: Timer?

    /// Callback invoked when the user taps Answer or Decline on the native iOS CallKit screen (or when it times out)
    var onUserCallResponse: ((UserCallResponse) -> Void)?

    // MARK: - Initialization

    override init() {
        let configuration = CXProviderConfiguration(localizedName: "OSWatch Bridge")
        configuration.supportsVideo = false
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = true

        self.provider = CXProvider(configuration: configuration)
        super.init()
        self.provider.setDelegate(self, queue: .main)
    }

    // MARK: - Incoming Call Reporting

    /// Reports a new incoming call to iOS CallKit so the native full-screen Incoming Call UI and ringtone trigger,
    /// even when the iPhone screen is locked.
    /// - Parameters:
    ///   - callerName: Extracted `title` / `callerName` from the Android BLE JSON payload
    ///   - app: Extracted `app` / `appName` (e.g. `"Phone"` or `"WhatsApp"`)
    ///   - phoneNumber: Optional phone number or subtitle
    func reportIncomingCall(callerName: String, app: String, phoneNumber: String = "") {
        let formattedCaller: String
        if app.isEmpty || app.caseInsensitiveCompare("Phone") == .orderedSame {
            formattedCaller = callerName
        } else {
            formattedCaller = "\(callerName) (\(app))"
        }

        let handleValue = !phoneNumber.isEmpty ? "\(phoneNumber) • \(app)" : "\(callerName) • \(app)"

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: handleValue)
        update.localizedCallerName = formattedCaller
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false

        // If a CallKit session is already active, update its display metadata and refresh the 35s timeout
        if let existingUUID = activeCallUUID {
            provider.reportCall(with: existingUUID, updated: update)
            scheduleAutoTimeout(for: existingUUID)
            logger.info("Updated existing CallKit incoming call session (\(existingUUID.uuidString)) for \(formattedCaller)")
            return
        }

        let callUUID = UUID()
        activeCallUUID = callUUID

        logger.info("Reporting new incoming CallKit call (\(callUUID.uuidString)): \(formattedCaller)")

        provider.reportNewIncomingCall(with: callUUID, update: update) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let error = error {
                    self.logger.error("CallKit reportNewIncomingCall failed: \(error.localizedDescription)")
                    if self.activeCallUUID == callUUID {
                        self.activeCallUUID = nil
                    }
                    self.cancelAutoTimeout()
                } else {
                    self.logger.info("CallKit incoming call UI presented for \(formattedCaller)")
                    self.scheduleAutoTimeout(for: callUUID)
                }
            }
        }
    }

    // MARK: - Call End / Dismiss / Auto-Timeout Handling

    /// Cleanly ends the active CallKit call session (called when Android reports the call ended/removed,
    /// when the 35s auto-timeout fires, or when dismissed in-app).
    func endActiveCall(reason: CXCallEndedReason = .declinedElsewhere) {
        cancelAutoTimeout()
        guard let callUUID = activeCallUUID else { return }
        activeCallUUID = nil

        logger.info("Ending CallKit session \(callUUID.uuidString) with reason \(String(describing: reason.rawValue))")
        provider.reportCall(with: callUUID, endedAt: Date(), reason: reason)

        // Also submit CXEndCallAction via CXCallController in case CallKit UI is still transitioning
        let endAction = CXEndCallAction(call: callUUID)
        let transaction = CXTransaction(action: endAction)
        callController.request(transaction) { [weak self] error in
            if let error = error {
                self?.logger.debug("CXEndCallAction transaction completed after reportCall: \(error.localizedDescription)")
            }
        }
    }

    private func scheduleAutoTimeout(for callUUID: UUID) {
        cancelAutoTimeout()
        autoTimeoutTimer = Timer.scheduledTimer(withTimeInterval: autoTimeoutInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.activeCallUUID == callUUID else { return }
                self.logger.info("CallKit 35s auto-timeout reached for call \(callUUID.uuidString); closing CallKit UI")
                self.endActiveCall(reason: .declinedElsewhere)
                self.onUserCallResponse?(.timedOut)
            }
        }
    }

    private func cancelAutoTimeout() {
        autoTimeoutTimer?.invalidate()
        autoTimeoutTimer = nil
    }
}

// MARK: - CXProviderDelegate

extension CallKitManager: CXProviderDelegate {

    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in
            logger.info("CXProvider did reset")
            cancelAutoTimeout()
            activeCallUUID = nil
        }
    }

    /// Triggered when the user taps "Answer" on the native iOS CallKit screen
    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            let callUUID = action.callUUID
            logger.info("User tapped Answer on CallKit screen for \(callUUID.uuidString)")

            cancelAutoTimeout()
            action.fulfill()

            // Notify BLEPeripheralManager to send a BLE response packet back to Android and stop local ringing
            onUserCallResponse?(.answered)

            // End the CallKit bridge session cleanly so the user is not stuck in a dummy audio call screen on iPhone
            activeCallUUID = nil
            provider.reportCall(with: callUUID, endedAt: Date(), reason: .declinedElsewhere)
        }
    }

    /// Triggered when the user taps "Decline" / "End" on the native iOS CallKit screen
    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            let callUUID = action.callUUID
            logger.info("User tapped Decline/End on CallKit screen for \(callUUID.uuidString)")

            cancelAutoTimeout()
            action.fulfill()

            if activeCallUUID == callUUID {
                activeCallUUID = nil
            }

            // Report call ended to CallKit and notify BLEPeripheralManager to send BLE response to Android
            provider.reportCall(with: callUUID, endedAt: Date(), reason: .declinedElsewhere)
            onUserCallResponse?(.declined)
        }
    }
}

#else

/// Lightweight stub for watchOS where iOS CallKit is not used
@MainActor
final class CallKitManager {
    enum UserCallResponse {
        case answered
        case declined
        case timedOut
    }

    static let shared = CallKitManager()
    var onUserCallResponse: ((UserCallResponse) -> Void)?

    func reportIncomingCall(callerName: String, app: String, phoneNumber: String = "") {}
    func endActiveCall() {}
}

#endif
