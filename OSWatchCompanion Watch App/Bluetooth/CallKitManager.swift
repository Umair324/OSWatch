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

    /// Callback invoked with human-readable CallKit status for the on-screen debug banner
    var onCallKitStatusUpdate: ((String) -> Void)?

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
        let cleanCaller = callerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unknown Caller" : callerName
        let cleanApp = app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Phone" : app

        let formattedCaller: String
        if cleanApp.caseInsensitiveCompare("Phone") == .orderedSame {
            formattedCaller = cleanCaller
        } else {
            formattedCaller = "\(cleanCaller) (\(cleanApp))"
        }

        let handleValue = !phoneNumber.isEmpty ? "\(phoneNumber) • \(cleanApp)" : "\(cleanCaller) • \(cleanApp)"

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: handleValue)
        update.localizedCallerName = formattedCaller
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false

        // Verify with CXCallObserver whether a CallKit call is genuinely active right now
        let systemActiveCalls = callController.callObserver.calls.filter { !$0.hasEnded }
        if systemActiveCalls.isEmpty {
            activeCallUUID = nil
        }

        // If a CallKit session is actively ringing on screen, update its display metadata and refresh the 35s timeout
        if let existingUUID = activeCallUUID,
           systemActiveCalls.contains(where: { $0.uuid == existingUUID }) {
            provider.reportCall(with: existingUUID, updated: update)
            scheduleAutoTimeout(for: existingUUID)
            let msg = "CallKit Updated: \(formattedCaller)"
            onCallKitStatusUpdate?(msg)
            logger.info("\(msg) (\(existingUUID.uuidString))")
            return
        }

        let callUUID = UUID()
        activeCallUUID = callUUID

        logger.info("Reporting new incoming CallKit call (\(callUUID.uuidString)): \(formattedCaller)")
        onCallKitStatusUpdate?("Reporting to CallKit: \(formattedCaller)...")

        provider.reportNewIncomingCall(with: callUUID, update: update) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let error = error {
                    let errMsg = "CallKit Error: \(error.localizedDescription)"
                    self.logger.error("\(errMsg)")
                    self.onCallKitStatusUpdate?(errMsg)
                    if self.activeCallUUID == callUUID {
                        self.activeCallUUID = nil
                    }
                    self.cancelAutoTimeout()
                } else {
                    let okMsg = "CallKit Ringing: \(formattedCaller)"
                    self.logger.info("\(okMsg)")
                    self.onCallKitStatusUpdate?(okMsg)
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

        let activeUUIDs: [UUID] = {
            var list: [UUID] = []
            if let current = activeCallUUID {
                list.append(current)
            }
            for call in callController.callObserver.calls where !call.hasEnded && !list.contains(call.uuid) {
                list.append(call.uuid)
            }
            return list
        }()

        activeCallUUID = nil
        guard !activeUUIDs.isEmpty else { return }

        for callUUID in activeUUIDs {
            logger.info("Ending CallKit session \(callUUID.uuidString) with reason \(String(describing: reason.rawValue))")
            provider.reportCall(with: callUUID, endedAt: Date(), reason: reason)

            let endAction = CXEndCallAction(call: callUUID)
            let transaction = CXTransaction(action: endAction)
            callController.request(transaction) { [weak self] error in
                if let error = error {
                    self?.logger.debug("CXEndCallAction completed after reportCall: \(error.localizedDescription)")
                }
            }
        }
        onCallKitStatusUpdate?("CallKit Session Ended")
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

            onCallKitStatusUpdate?("Call Answered on iPhone")
            onUserCallResponse?(.answered)

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

            provider.reportCall(with: callUUID, endedAt: Date(), reason: .declinedElsewhere)
            onCallKitStatusUpdate?("Call Declined on iPhone")
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
    var onCallKitStatusUpdate: ((String) -> Void)?

    func reportIncomingCall(callerName: String, app: String, phoneNumber: String = "") {}
    func endActiveCall() {}
}

#endif
