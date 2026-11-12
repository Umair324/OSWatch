import SwiftUI

/// Tab 1: Status & Pairing Screen
/// Displays a glowing status ring (`Connected` vs `Advertising`), a toggle switch to start/stop BLE broadcasting,
/// and dual circular battery gauges (`Watch/iPhone %` & `Android Phone %`).
struct StatusPairingView: View {
    @EnvironmentObject private var bleManager: BLEPeripheralManager
    @State private var pulseAnimation: Bool = false

    #if os(watchOS)
    private let ringOuterSize: CGFloat = 82
    private let ringInnerSize: CGFloat = 74
    #else
    private let ringOuterSize: CGFloat = 148
    private let ringInnerSize: CGFloat = 132
    #endif

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // 1. Glowing BLE Connection Status Ring
                statusRingSection

                // 2. Dual Circular Battery Gauges (Watch/iPhone % & Android Phone %)
                batteryGaugesSection

                // 3. BLE Broadcast Toggle Switch
                broadcastToggleCard

                // 4. Live GATT Telemetry & Demo Trigger Bar
                diagnosticsAndSimulatorSection
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
            .frame(maxWidth: 480)
        }
        .navigationTitle("OSWatch")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            bleManager.refreshWatchBatteryLevel()
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulseAnimation = true
            }
        }
    }

    // MARK: - Glowing Status Ring

    private var statusRingSection: some View {
        let state = bleManager.connectionState
        let ringColor = state.accentColor

        return VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(ringColor.opacity(0.28), lineWidth: 10)
                    .frame(width: ringOuterSize, height: ringOuterSize)
                    .scaleEffect(pulseAnimation && (state.isConnected || state.isAdvertising) ? 1.09 : 0.96)
                    .blur(radius: 3)

                Circle()
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                ringColor.opacity(0.95),
                                ringColor.opacity(0.45),
                                ringColor
                            ]),
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .frame(width: ringInnerSize, height: ringInnerSize)
                    .shadow(color: ringColor.opacity(0.75), radius: 8)

                VStack(spacing: 3) {
                    Image(systemName: statusIconName(for: state))
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(ringColor)
                        .symbolEffect(.pulse, isActive: state.isAdvertising)

                    Text(state.isConnected ? "LINKED" : (state.isAdvertising ? "BLE ON" : "IDLE"))
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)

            Text(state.statusLabel)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.white)

            Text(state.statusSubtext)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Dual Circular Battery Gauges

    private var batteryGaugesSection: some View {
        HStack(spacing: 16) {
            CircularBatteryGauge(
                title: PlatformDeviceBridge.localDeviceTitle,
                systemImage: PlatformDeviceBridge.localDeviceIcon,
                percentage: bleManager.watchBatteryPercent,
                tint: batteryTint(for: bleManager.watchBatteryPercent)
            )

            CircularBatteryGauge(
                title: "Android",
                systemImage: "candybarphone",
                percentage: bleManager.androidBatteryPercent,
                tint: batteryTint(for: bleManager.androidBatteryPercent ?? 50)
            )
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
    }

    // MARK: - Broadcast Toggle Switch

    private var broadcastToggleCard: some View {
        Toggle(isOn: $bleManager.isBroadcastingEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text("BLE Broadcast")
                    .font(.system(size: 14, weight: .semibold))
                Text(bleManager.isBroadcastingEnabled ? "Discoverable (\(GATTConstants.advertisedLocalName))" : "Paused")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .tint(.cyan)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
    }

    // MARK: - Diagnostics & Test Controls

    private var diagnosticsAndSimulatorSection: some View {
        VStack(spacing: 8) {
            Text(bleManager.lastEventLog)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: 8) {
                Button {
                    bleManager.simulateChunkedNotification()
                } label: {
                    Label("Test Msg", systemImage: "bell.badge.fill")
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.cyan)

                Button {
                    bleManager.simulateIncomingCall()
                } label: {
                    Label("Test Call", systemImage: "phone.down.waves.left.and.right")
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.green)
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Helpers

    private func statusIconName(for state: BLEConnectionState) -> String {
        switch state {
        case .connected:
            return "checkmark.circle.fill"
        case .advertising:
            return "antenna.radiowaves.left.and.right"
        case .idle:
            return "pause.circle.fill"
        case .bluetoothOff, .unauthorized:
            return "exclamationmark.triangle.fill"
        }
    }

    private func batteryTint(for percent: Int) -> Color {
        if percent <= 20 {
            return .red
        } else if percent <= 40 {
            return .orange
        } else {
            return .green
        }
    }
}

// MARK: - Dual Circular Battery Gauge Subview

struct CircularBatteryGauge: View {
    let title: String
    let systemImage: String
    let percentage: Int?
    let tint: Color

    #if os(watchOS)
    private let gaugeSize: CGFloat = 48
    #else
    private let gaugeSize: CGFloat = 68
    #endif

    private var normalizedProgress: Double {
        guard let percentage = percentage else { return 0.0 }
        return Double(max(0, min(100, percentage))) / 100.0
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.14), lineWidth: 5)
                    .frame(width: gaugeSize, height: gaugeSize)

                Circle()
                    .trim(from: 0, to: normalizedProgress)
                    .stroke(
                        tint,
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: gaugeSize, height: gaugeSize)
                    .animation(.easeInOut(duration: 0.35), value: normalizedProgress)

                VStack(spacing: 2) {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(percentage != nil ? tint : .secondary)

                    Text(percentage.map { "\($0)%" } ?? "--%")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }

            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
