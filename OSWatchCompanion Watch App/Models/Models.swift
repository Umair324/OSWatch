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
    /// Sends media and ping commands (`PLAY_PAUSE`, `NEXT`, `PREV`, `FIND_PHONE`) from Watch to Android
    static let txCharacteristicUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    /// Battery Characteristic (Read & Write):
    /// Responds with Watch battery % on Read; receives Android phone battery % on Write
    static let batteryCharacteristicUUID = CBUUID(string: "6E400004-B5A3-F393-E0A9-E50E24DCCA9E")

    /// Background CoreBluetooth peripheral restoration identifier
    static let restoreIdentifier = "com.oswatch.companion.peripheral.manager"

    /// Local advertised peripheral name discovered by the Android host app
    static let advertisedLocalName = "OSWatch-BLE"
}

// MARK: - Outgoing Watch -> Android Commands

enum BLECommand: String, CaseIterable, Identifiable {
    case playPause = "PLAY_PAUSE"
    case next = "NEXT"
    case prev = "PREV"
    case findPhone = "FIND_PHONE"

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .playPause: return "Play / Pause"
        case .next: return "Next Track"
        case .prev: return "Previous Track"
        case .findPhone: return "Ping Android Phone"
        }
    }

    var systemImage: String {
        switch self {
        case .playPause: return "playpause.fill"
        case .next: return "forward.fill"
        case .prev: return "backward.fill"
        case .findPhone: return "bell.and.waves.left.and.right.fill"
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
        case title
        case body
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

        self.appName = (try? container.decode(String.self, forKey: .appName)) ?? "Android"
        self.title = (try? container.decode(String.self, forKey: .title)) ?? "Notification"
        self.body = (try? container.decode(String.self, forKey: .body)) ?? ""

        // Support epoch milliseconds, epoch seconds, or ISO-8601 string
        if let rawDouble = try? container.decode(Double.self, forKey: .timestamp) {
            // Heuristic: values > 10_000_000_000 are epoch milliseconds (standard on Android System.currentTimeMillis())
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
        case "RINGING", "INCOMING":
            self = .ringing
        case "OFFHOOK", "ACTIVE", "ANSWERED":
            self = .offhook
        case "IDLE", "DISCONNECTED":
            self = .idle
        case "ENDED", "MISSED", "REJECTED":
            self = .ended
        default:
            self = .unknown
        }
    }
}

struct CallAlert: Identifiable, Codable, Equatable {
    var id: String { "\(phoneNumber)-\(callState.rawValue)" }
    let callerName: String
    let phoneNumber: String
    let callState: CallState
    let receivedAt: Date

    enum CodingKeys: String, CodingKey {
        case callerName
        case phoneNumber
        case callState
    }

    init(
        callerName: String,
        phoneNumber: String,
        callState: CallState,
        receivedAt: Date = Date()
    ) {
        self.callerName = callerName
        self.phoneNumber = phoneNumber
        self.callState = callState
        self.receivedAt = receivedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawName = (try? container.decode(String.self, forKey: .callerName)) ?? ""
        let rawNumber = (try? container.decode(String.self, forKey: .phoneNumber)) ?? ""
        let rawState = try container.decode(String.self, forKey: .callState)

        self.callerName = rawName.isEmpty ? "Unknown Caller" : rawName
        self.phoneNumber = rawNumber.isEmpty ? "Private Number" : rawNumber
        self.callState = CallState(rawString: rawState)
        self.receivedAt = Date()
    }

    var isRinging: Bool {
        callState == .ringing
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

        // Inspect keys to distinguish `{ callerName, phoneNumber, callState }` from `{ id, appName, title, body, timestamp }`
        if let rawObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if rawObject["callState"] != nil || rawObject["callerName"] != nil || rawObject["phoneNumber"] != nil {
                let alert = try JSONDecoder().decode(CallAlert.self, from: data)
                return .callAlert(alert)
            }
            if rawObject["appName"] != nil || rawObject["title"] != nil || rawObject["body"] != nil {
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
