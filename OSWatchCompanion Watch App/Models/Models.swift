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

    /// TX / Call Control Characteristic (Notify & Read):
    /// Sends call control JSON (`{"type":"call_action","action":"answer"}` / `{"type":"call_action","action":"decline"}`)
    /// and media/ping commands from Watch/iPhone to Android
    static let txCharacteristicUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    /// Call action JSON payloads sent over `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`
    static let callActionAnswerJSON = #"{"type":"call_action","action":"answer"}"#
    static let callActionDeclineJSON = #"{"type":"call_action","action":"decline"}"#

    /// Battery Characteristic (Read & Write):
    /// Responds with Watch/iPhone battery % on Read; receives Android phone battery % on Write
    static let batteryCharacteristicUUID = CBUUID(string: "6E400004-B5A3-F393-E0A9-E50E24DCCA9E")

    /// Background CoreBluetooth peripheral restoration identifier
    static let restoreIdentifier = "com.oswatch.companion.peripheral.manager"

    /// Local advertised peripheral name discovered by the Android host app
    static let advertisedLocalName = "OSWatch-BLE"

    /// Keywords that identify an incoming call payload even if `type`/`cat` is generic
    static let callDetectionKeywords: [String] = [
        "incoming call",
        "voice call",
        "video call",
        "ringing",
        "is calling",
        "calling you",
        "audio call",
        "ongoing call"
    ]
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
        case packageName
        case pkg
        case title
        case sender
        case body
        case text
        case message
        case subText
        case timestamp
        case time
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

        // Support `appName`, `app`, `packageName`, or `pkg`
        let candidatesApp = [
            try? container.decode(String.self, forKey: .appName),
            try? container.decode(String.self, forKey: .app),
            try? container.decode(String.self, forKey: .packageName),
            try? container.decode(String.self, forKey: .pkg)
        ]
        self.appName = candidatesApp.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "Android"

        // Support `title` or `sender`
        let candidatesTitle = [
            try? container.decode(String.self, forKey: .title),
            try? container.decode(String.self, forKey: .sender)
        ]
        self.title = candidatesTitle.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "Notification"

        // Support `body`, `text`, `message`, or `subText`
        let candidatesBody = [
            try? container.decode(String.self, forKey: .body),
            try? container.decode(String.self, forKey: .text),
            try? container.decode(String.self, forKey: .message),
            try? container.decode(String.self, forKey: .subText)
        ]
        self.body = candidatesBody.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""

        // Support epoch milliseconds, epoch seconds, or ISO-8601 string in `timestamp` or `time`
        if let rawDouble = (try? container.decode(Double.self, forKey: .timestamp)) ??
                           (try? container.decode(Double.self, forKey: .time)) {
            let seconds = rawDouble > 10_000_000_000 ? (rawDouble / 1000.0) : rawDouble
            self.timestamp = Date(timeIntervalSince1970: seconds)
        } else if let rawString = (try? container.decode(String.self, forKey: .timestamp)) ??
                                  (try? container.decode(String.self, forKey: .time)) {
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
        case "RINGING", "INCOMING", "CALL", "ACTIVE_RINGING", "START", "ONGOING":
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
        case sender
        case name
        case phoneNumber
        case number
        case body
        case text
        case message
        case subText
        case app
        case appName
        case packageName
        case pkg
        case callState
        case status
        case state
        case action
        case type
        case cat
        case category
        case isOngoingCall
        case ongoing
        case removed
        case isRemoved
    }

    init(
        callerName: String,
        phoneNumber: String,
        app: String = "Phone",
        callState: CallState = .ringing,
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

        // 1. Extract caller name from `title`, `callerName`, `sender`, or `name`
        let callerCandidates = [
            try? container.decode(String.self, forKey: .title),
            try? container.decode(String.self, forKey: .callerName),
            try? container.decode(String.self, forKey: .sender),
            try? container.decode(String.self, forKey: .name)
        ]
        self.callerName = callerCandidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "Unknown Caller"

        // 2. Extract source app (e.g. "Phone", "WhatsApp") from `app`, `appName`, `packageName`, or `pkg`
        let appCandidates = [
            try? container.decode(String.self, forKey: .app),
            try? container.decode(String.self, forKey: .appName),
            try? container.decode(String.self, forKey: .packageName),
            try? container.decode(String.self, forKey: .pkg)
        ]
        self.app = appCandidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "Phone"

        // 3. Extract phone number or call description from `phoneNumber`, `number`, `body`, `text`, `message`, or `subText`
        let phoneCandidates = [
            try? container.decode(String.self, forKey: .phoneNumber),
            try? container.decode(String.self, forKey: .number),
            try? container.decode(String.self, forKey: .body),
            try? container.decode(String.self, forKey: .text),
            try? container.decode(String.self, forKey: .message),
            try? container.decode(String.self, forKey: .subText)
        ]
        self.phoneNumber = phoneCandidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "Incoming \(self.app) Call"

        // 4. Determine CallState (`RINGING` vs `ENDED` / `IDLE`)
        let isRemovedFlag = Self.decodeFlexibleBool(from: container, forKey: .removed) ??
                            Self.decodeFlexibleBool(from: container, forKey: .isRemoved) ?? false
        let ongoingFlag = Self.decodeFlexibleBool(from: container, forKey: .isOngoingCall) ??
                          Self.decodeFlexibleBool(from: container, forKey: .ongoing)

        let rawType = ((try? container.decode(String.self, forKey: .type)) ?? "").lowercased()
        let rawAction = ((try? container.decode(String.self, forKey: .action)) ?? "").lowercased()
        let rawCat = ((try? container.decode(String.self, forKey: .cat)) ??
                      (try? container.decode(String.self, forKey: .category)) ?? "").lowercased()

        if isRemovedFlag ||
           rawType.contains("end") || rawType.contains("remove") || rawType.contains("dismiss") ||
           rawAction.contains("end") || rawAction.contains("remove") || rawAction.contains("dismiss") {
            self.callState = .ended
        } else if let rawState = (try? container.decode(String.self, forKey: .callState)) ??
                                 (try? container.decode(String.self, forKey: .status)) ??
                                 (try? container.decode(String.self, forKey: .state)),
                  !rawState.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = CallState(rawString: rawState)
            // If `type == "call"` or `cat == "call"` or `isOngoingCall == true` and state was unknown, treat as ringing
            if parsed == .unknown && (rawType == "call" || rawCat == "call" || ongoingFlag == true) {
                self.callState = .ringing
            } else {
                self.callState = parsed
            }
        } else if ongoingFlag == false && rawType != "call" && rawCat != "call" {
            // Only mark ended if explicitly `isOngoingCall: false` AND not a fresh call notification
            self.callState = .ended
        } else {
            self.callState = .ringing
        }

        self.receivedAt = Date()
    }

    private static func decodeFlexibleBool(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Bool? {
        if let boolVal = try? container.decode(Bool.self, forKey: key) {
            return boolVal
        }
        if let intVal = try? container.decode(Int.self, forKey: key) {
            return intVal != 0
        }
        if let strVal = (try? container.decode(String.self, forKey: key))?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if strVal == "true" || strVal == "1" || strVal == "yes" { return true }
            if strVal == "false" || strVal == "0" || strVal == "no" { return false }
        }
        return nil
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

    /// Returns true if any text in the payload contains one of the call keywords
    /// (`incoming call`, `voice call`, `video call`, `ringing`, `is calling`, etc.)
    static func containsCallKeyword(in text: String) -> Bool {
        let lower = text.lowercased()
        return GATTConstants.callDetectionKeywords.contains { lower.contains($0) }
    }

    /// Inspects a reconstructed JSON payload and decodes it as either a `CallAlert` or `AndroidNotification`
    static func decode(from jsonString: String) throws -> IncomingBLEPayload {
        guard let data = jsonString.data(using: .utf8) else {
            throw BLEPayloadError.invalidUTF8
        }

        if let rawObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let rawType = String(describing: rawObject["type"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let rawCat = String(describing: rawObject["cat"] ?? rawObject["category"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            let isOngoingCall: Bool = {
                if let b = rawObject["isOngoingCall"] as? Bool { return b }
                if let b = rawObject["ongoing"] as? Bool { return b }
                if let n = rawObject["isOngoingCall"] as? NSNumber { return n.boolValue }
                if let s = (rawObject["isOngoingCall"] as? String)?.lowercased() {
                    return s == "true" || s == "1"
                }
                return false
            }()

            // Collect all text fields to check for call keywords (`incoming call`, `voice call`, `video call`, `ringing`, `is calling`)
            let combinedTextFields = [
                rawObject["title"] as? String,
                rawObject["callerName"] as? String,
                rawObject["body"] as? String,
                rawObject["text"] as? String,
                rawObject["message"] as? String,
                rawObject["subText"] as? String,
                rawObject["ticker"] as? String,
                rawType,
                rawCat
            ]
            .compactMap { $0 }
            .joined(separator: " ")

            let hasCallKeyword = containsCallKeyword(in: combinedTextFields)

            let isCallPayload =
                rawType == "call" ||
                rawType.contains("call") ||
                rawCat == "call" ||
                rawCat.contains("call") ||
                isOngoingCall ||
                hasCallKeyword ||
                rawObject["callState"] != nil ||
                rawObject["callerName"] != nil ||
                rawObject["phoneNumber"] != nil

            if isCallPayload {
                var alert = try JSONDecoder().decode(CallAlert.self, from: data)
                // If matched via keyword or `type == "call"` / `cat == "call"` / `isOngoingCall == true`,
                // ensure it rings unless explicitly marked removed/ended
                let explicitlyEnded = rawType.contains("end") || rawType.contains("remove") ||
                                      (rawObject["removed"] as? Bool == true) ||
                                      (rawObject["isRemoved"] as? Bool == true)
                if !explicitlyEnded && !alert.isRinging {
                    alert = CallAlert(
                        callerName: alert.callerName,
                        phoneNumber: alert.phoneNumber,
                        app: alert.app,
                        callState: .ringing,
                        receivedAt: alert.receivedAt
                    )
                }
                return .callAlert(alert)
            }

            if rawObject["appName"] != nil || rawObject["app"] != nil ||
               rawObject["title"] != nil || rawObject["body"] != nil || rawObject["text"] != nil ||
               rawObject["message"] != nil || rawObject["id"] != nil {
                let notification = try JSONDecoder().decode(AndroidNotification.self, from: data)
                return .notification(notification)
            }
        }

        // Fallback: If raw string contains call indicators or keywords even with non-standard JSON formatting
        let lowerJSON = jsonString.lowercased()
        if lowerJSON.contains("\"type\":\"call\"") ||
           lowerJSON.contains("\"type\": \"call\"") ||
           lowerJSON.contains("\"cat\":\"call\"") ||
           lowerJSON.contains("\"cat\": \"call\"") ||
           lowerJSON.contains("\"isongoingcall\":true") ||
           lowerJSON.contains("\"isongoingcall\": true") ||
           containsCallKeyword(in: lowerJSON) {
            let caller = extractJSONStringValue(from: jsonString, keys: ["title", "callerName", "sender", "name"]) ?? "Incoming Caller"
            let app = extractJSONStringValue(from: jsonString, keys: ["app", "appName", "pkg"]) ?? "Phone"
            let body = extractJSONStringValue(from: jsonString, keys: ["body", "text", "phoneNumber", "message"]) ?? "Incoming Call"
            return .callAlert(CallAlert(callerName: caller, phoneNumber: body, app: app, callState: .ringing))
        }

        throw BLEPayloadError.unrecognizedSchema(jsonString)
    }

    /// Lightweight regex-free key extractor for fallback decoding if Android sends slightly truncated/non-escaped JSON
    static func extractJSONStringValue(from json: String, keys: [String]) -> String? {
        for key in keys {
            let patterns = ["\"\(key)\":\"", "\"\(key)\": \"", "\"\(key)\" : \""]
            for pattern in patterns {
                if let range = json.range(of: pattern, options: .caseInsensitive) {
                    let remainder = json[range.upperBound...]
                    if let endQuote = remainder.firstIndex(of: "\"") {
                        let value = String(remainder[..<endQuote]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !value.isEmpty {
                            return value
                        }
                    }
                }
            }
        }
        return nil
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
