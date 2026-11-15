import Foundation
import SwiftUI
import CoreBluetooth

// MARK: - Shared BLE GATT Protocol Constants

enum GATTConstants {
    /// Primary Nordic UART-style custom service UUID shared with the Android host app
    static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")

    /// RX Characteristic (Write & WriteWithoutResponse):
    /// Receives chunked JSON strings (`1/3|...`) for notifications and call alerts from Android
    static let rxCharacteristicUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")

    /// TX Characteristic (Notify):
    /// Sends media, ping, and call response commands from Watch/iPhone to Android
    static let txCharacteristicUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    /// Battery Characteristic (Read & Write):
    /// Responds with Watch/iPhone battery % on Read; receives Android phone battery % on Write
    static let batteryCharacteristicUUID = CBUUID(string: "6E400004-B5A3-F393-E0A9-E50E24DCCA9E")

    /// Background CoreBluetooth peripheral restoration identifier
    static let restoreIdentifier = "com.oswatch.companion.peripheral.manager"

    /// Local advertised peripheral name discovered by the Android host app
    static let advertisedLocalName = "OSWatch-BLE"
}

// MARK: - Outgoing Watch/iPhone -> Android Commands

enum BLECommand: String, CaseIterable, Identifiable {
    case playPause = "PLAY_PAUSE"
    case next = "NEXT"
    case prev = "PREV"
    case findPhone = "FIND_PHONE"
    case answerCall = "ANSWER_CALL"
    case declineCall = "DECLINE_CALL"

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .playPause: return "Play / Pause"
        case .next: return "Next Track"
        case .prev: return "Previous Track"
        case .findPhone: return "Ping Android Phone"
        case .answerCall: return "Answer Call"
        case .declineCall: return "Decline Call"
        }
    }

    var systemImage: String {
        switch self {
        case .playPause: return "playpause.fill"
        case .next: return "forward.fill"
        case .prev: return "backward.fill"
        case .findPhone: return "bell.and.waves.left.and.right.fill"
        case .answerCall: return "phone.fill"
        case .declineCall: return "phone.down.fill"
        }
    }
}

// MARK: - BLE Peripheral Connection State

enum BLEConnectionState: Equatable {
    case bluetoothOff
    case unauthorized
    case idle
    case advertising
    case connected(centralCount: Int)

    var statusLabel: String {
        switch self {
        case .bluetoothOff:
            return "Bluetooth Off"
        case .unauthorized:
            return "No Permission"
        case .idle:
            return "Standby"
        case .advertising:
            return "Advertising"
        case .connected:
            return "Connected"
        }
    }

    var statusSubtext: String {
        switch self {
        case .bluetoothOff:
            return "Enable Bluetooth in Settings"
        case .unauthorized:
            return "Allow Bluetooth access"
        case .idle:
            return "Broadcast paused"
        case .advertising:
            return "Waiting for Android host..."
        case .connected(let count):
            return count > 1 ? "\(count) hosts subscribed" : "Android host linked"
        }
    }

    var accentColor: Color {
        switch self {
        case .connected:
            return Color.green
        case .advertising:
            return Color.cyan
        case .idle:
            return Color.gray
        case .bluetoothOff, .unauthorized:
            return Color.orange
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isAdvertising: Bool {
        if case .advertising = self { return true }
        return false
    }
}

// MARK: - Android Notification Model

struct AndroidNotification: Identifiable, Codable, Equatable {
    let id: String
    let appName: String
    let title: String
    let body: String
    let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case id
        case appName
        case app
        case title
        case body
        case text
        case timestamp
    }

    init(
        id: String = UUID().uuidString,
        appName: String,
        title: String,
        body: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.appName = appName
        self.title = title
        self.body = body
        self.timestamp = timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Support String or Int `id`
        if let stringId = try? container.decode(String.self, forKey: .id), !stringId.isEmpty {
            self.id = stringId
        } else if let intId = try? container.decode(Int64.self, forKey: .id) {
            self.id = String(intId)
        } else {
            self.id = UUID().uuidString
        }

        if let appName = try? container.decode(String.self, forKey: .appName), !appName.isEmpty {
            self.appName = appName
        } else if let app = try? container.decode(String.self, forKey: .app), !app.isEmpty {
            self.appName = app
        } else {
            self.appName = "Android"
        }

        self.title = (try? container.decode(String.self, forKey: .title)) ?? "Notification"

        if let body = try? container.decode(String.self, forKey: .body), !body.isEmpty {
            self.body = body
        } else if let text = try? container.decode(String.self, forKey: .text), !text.isEmpty {
            self.body = text
        } else {
            self.body = ""
        }

        // Support epoch milliseconds, epoch seconds, or ISO-8601 string
        if let rawDouble = try? container.decode(Double.self, forKey: .timestamp) {
            let seconds = rawDouble > 10_000_000_000 ? (rawDouble / 1000.0) : rawDouble
            self.timestamp = Date(timeIntervalSince1970: seconds)
        } else if let rawString = try? container.decode(String.self, forKey: .timestamp) {
            if let numericValue = Double(rawString) {
                let seconds = numericValue > 10_000_000_000 ? (numericValue / 1000.0) : numericValue
                self.timestamp = Date(timeIntervalSince1970: seconds)
            } else if let isoDate = ISO8601DateFormatter().date(from: rawString) {
                self.timestamp = isoDate
            } else {
                self.timestamp = Date()
            }
        } else {
            self.timestamp = Date()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(appName, forKey: .appName)
        try container.encode(title, forKey: .title)
        try container.encode(body, forKey: .body)
        try container.encode(timestamp.timeIntervalSince1970 * 1000.0, forKey: .timestamp)
    }

    /// Dynamic color badge determined by the Android application's name
    var badgeColor: Color {
        let normalized = appName.lowercased()
        if normalized.contains("whatsapp") || normalized.contains("messages") || normalized.contains("sms") {
            return .green
        } else if normalized.contains("gmail") || normalized.contains("mail") || normalized.contains("youtube") {
            return .red
        } else if normalized.contains("slack") || normalized.contains("discord") || normalized.contains("teams") {
            return .purple
        } else if normalized.contains("telegram") || normalized.contains("signal") || normalized.contains("twitter") || normalized.contains("x") {
            return .cyan
        } else if normalized.contains("instagram") {
            return .pink
        } else if normalized.contains("calendar") || normalized.contains("clock") || normalized.contains("alarm") {
            return .orange
        } else {
            return .blue
        }
    }

    /// SF Symbol icon matching the source Android app category
    var badgeIcon: String {
        let normalized = appName.lowercased()
        if normalized.contains("whatsapp") || normalized.contains("messages") || normalized.contains("sms") || normalized.contains("telegram") {
            return "message.fill"
        } else if normalized.contains("gmail") || normalized.contains("mail") {
            return "envelope.fill"
        } else if normalized.contains("slack") || normalized.contains("discord") || normalized.contains("teams") {
            return "bubble.left.and.bubble.right.fill"
        } else if normalized.contains("calendar") {
            return "calendar"
        } else if normalized.contains("youtube") || normalized.contains("spotify") || normalized.contains("music") {
            return "play.circle.fill"
        } else {
            return "app.badge.fill"
        }
    }
}

// MARK: - Incoming Call Alert Model

enum CallState: String, Codable, Equatable {
    case ringing = "RINGING"
    case offhook = "OFFHOOK"
    case idle = "IDLE"
    case ended = "ENDED"
    case unknown = "UNKNOWN"

    init(rawString: String) {
        switch rawString.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "RINGING", "INCOMING", "CALL", "ACTIVE_RINGING", "START":
            self = .ringing
        case "OFFHOOK", "ACTIVE", "ANSWERED":
            self = .offhook
        case "IDLE", "DISCONNECTED":
            self = .idle
        case "ENDED", "MISSED", "REJECTED", "REMOVED", "DISMISSED", "STOP", "END":
            self = .ended
        default:
            self = .unknown
        }
    }
}

struct CallAlert: Identifiable, Codable, Equatable {
    var id: String { "\(callerName)-\(app)-\(callState.rawValue)" }
    let callerName: String
    let phoneNumber: String
    let app: String
    let callState: CallState
    let receivedAt: Date

    enum CodingKeys: String, CodingKey {
        case callerName
        case title
        case phoneNumber
        case body
        case text
        case app
        case appName
        case callState
        case status
        case action
        case type
        case cat
        case isOngoingCall
        case removed
        case isRemoved
    }

    init(
        callerName: String,
        phoneNumber: String,
        app: String = "Phone",
        callState: CallState,
        receivedAt: Date = Date()
    ) {
        self.callerName = callerName
        self.phoneNumber = phoneNumber
        self.app = app
        self.callState = callState
        self.receivedAt = receivedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // 1. Extract caller name from `title` or `callerName`
        let rawTitle = (try? container.decode(String.self, forKey: .title))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawCaller = (try? container.decode(String.self, forKey: .callerName))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedCaller = !rawTitle.isEmpty ? rawTitle : rawCaller
        self.callerName = resolvedCaller.isEmpty ? "Unknown Caller" : resolvedCaller

        // 2. Extract source app (e.g. "Phone", "WhatsApp") from `app` or `appName`
        let rawApp = (try? container.decode(String.self, forKey: .app))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawAppName = (try? container.decode(String.self, forKey: .appName))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedApp = !rawApp.isEmpty ? rawApp : rawAppName
        self.app = resolvedApp.isEmpty ? "Phone" : resolvedApp

        // 3. Extract phone number or subtitle from `phoneNumber`, `body`, `text`, or fallback to `app`
        let rawPhone = (try? container.decode(String.self, forKey: .phoneNumber))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawBody = (try? container.decode(String.self, forKey: .body))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawText = (try? container.decode(String.self, forKey: .text))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !rawPhone.isEmpty {
            self.phoneNumber = rawPhone
        } else if !rawBody.isEmpty {
            self.phoneNumber = rawBody
        } else if !rawText.isEmpty {
            self.phoneNumber = rawText
        } else {
            self.phoneNumber = "\(self.app) Audio"
        }

        // 4. Determine CallState (`RINGING` vs `ENDED` / `IDLE`)
        let isRemovedFlag = (try? container.decode(Bool.self, forKey: .removed)) ??
                            (try? container.decode(Bool.self, forKey: .isRemoved)) ?? false
        let ongoingFlag = try? container.decode(Bool.self, forKey: .isOngoingCall)
        let rawType = ((try? container.decode(String.self, forKey: .type)) ?? "").lowercased()
        let rawAction = ((try? container.decode(String.self, forKey: .action)) ?? "").lowercased()

        if isRemovedFlag || ongoingFlag == false ||
           rawType.contains("end") || rawType.contains("remove") || rawType.contains("dismiss") ||
           rawAction.contains("end") || rawAction.contains("remove") || rawAction.contains("dismiss") {
            self.callState = .ended
        } else if let rawState = try? container.decode(String.self, forKey: .callState), !rawState.isEmpty {
            self.callState = CallState(rawString: rawState)
        } else if let rawStatus = try? container.decode(String.self, forKey: .status), !rawStatus.isEmpty {
            self.callState = CallState(rawString: rawStatus)
        } else {
            // When `type == "call"`, `cat == "call"`, or `isOngoingCall == true` with no explicit end state, treat as RINGING
            self.callState = .ringing
        }

        self.receivedAt = Date()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(callerName, forKey: .callerName)
        try container.encode(phoneNumber, forKey: .phoneNumber)
        try container.encode(app, forKey: .app)
        try container.encode(callState.rawValue, forKey: .callState)
    }

    var isRinging: Bool {
        callState == .ringing
    }

    /// Formatted caller display name for CallKit (e.g., "Sarah Jenkins (WhatsApp)")
    var callKitDisplayName: String {
        if app.isEmpty || app.caseInsensitiveCompare("Phone") == .orderedSame {
            return callerName
        }
        return "\(callerName) (\(app))"
    }
}

// MARK: - Decoded Incoming BLE Payload Envelope

enum IncomingBLEPayload: Equatable {
    case notification(AndroidNotification)
    case callAlert(CallAlert)

    /// Inspects a reconstructed JSON payload and decodes it as either a `CallAlert` or `AndroidNotification`
    static func decode(from jsonString: String) throws -> IncomingBLEPayload {
        guard let data = jsonString.data(using: .utf8) else {
            throw BLEPayloadError.invalidUTF8
        }

        if let rawObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let rawType = (rawObject["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let rawCat = (rawObject["cat"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ??
                         (rawObject["category"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let isOngoingCall = (rawObject["isOngoingCall"] as? Bool) ?? false

            let isCallPayload =
                rawType == "call" ||
                rawType == "call_end" ||
                rawType == "call_removed" ||
                rawCat == "call" ||
                isOngoingCall ||
                rawObject["callState"] != nil ||
                rawObject["callerName"] != nil ||
                rawObject["phoneNumber"] != nil

            if isCallPayload {
                let alert = try JSONDecoder().decode(CallAlert.self, from: data)
                return .callAlert(alert)
            }

            if rawObject["appName"] != nil || rawObject["app"] != nil ||
               rawObject["title"] != nil || rawObject["body"] != nil || rawObject["text"] != nil {
                let notification = try JSONDecoder().decode(AndroidNotification.self, from: data)
                return .notification(notification)
            }
        }

        throw BLEPayloadError.unrecognizedSchema(jsonString)
    }
}

enum BLEPayloadError: LocalizedError {
    case invalidUTF8
    case malformedChunkHeader(String)
    case unrecognizedSchema(String)

    var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "Payload bytes are not valid UTF-8 text."
        case .malformedChunkHeader(let raw):
            return "Invalid BLE chunk header in packet: \(raw)"
        case .unrecognizedSchema(let json):
            return "JSON did not match Notification or CallAlert schema: \(json)"
        }
    }
}

// MARK: - Sample Preview Data

extension AndroidNotification {
    static let sampleFeed: [AndroidNotification] = [
        AndroidNotification(
            id: "notif-1",
            appName: "WhatsApp",
            title: "Maya Lin",
            body: "Are we still meeting at 6 PM for coffee?",
            timestamp: Date().addingTimeInterval(-120)
        ),
        AndroidNotification(
            id: "notif-2",
            appName: "Gmail",
            title: "Build Pipeline",
            body: "Release candidate v2.4.1 passed all Android BLE integration checks.",
            timestamp: Date().addingTimeInterval(-940)
        ),
        AndroidNotification(
            id: "notif-3",
            appName: "Slack",
            title: "#mobile-sync",
            body: "Updated GATT MTU chunk size to 180 bytes for faster notification delivery.",
            timestamp: Date().addingTimeInterval(-3600)
        )
    ]
}
