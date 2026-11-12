import SwiftUI

/// Tab 3 (Screen 4): Remote Controls Tab
/// Sends media playback commands (`PREV`, `PLAY_PAUSE`, `NEXT`) and the `FIND_PHONE` ping command
/// over BLE Characteristic `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` (Notify).
struct RemoteControlsView: View {
    @EnvironmentObject private var bleManager: BLEPeripheralManager
    @State private var isPinging: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Header Status Pill
                HStack(spacing: 6) {
                    Circle()
                        .fill(bleManager.connectionState.accentColor)
                        .frame(width: 7, height: 7)

                    Text(bleManager.connectionState.isConnected ? "Android Media Ready" : "BLE Notify Queue")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)

                // Media Transport Controls (PREV, PLAY_PAUSE, NEXT)
                mediaTransportSection

                // Prominent "Ping Android Phone" (FIND_PHONE) Button
                pingPhoneButton

                // Last Sent Command Feedback
                if let lastCommand = bleManager.lastSentCommand {
                    Text("Sent: \(lastCommand.rawValue)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.cyan)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
        .navigationTitle("Remote")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Media Transport Buttons

    private var mediaTransportSection: some View {
        HStack(spacing: 10) {
            // Previous Track (`PREV`)
            Button {
                bleManager.sendCommand(.prev)
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 42, height: 42)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous Track")

            // Play / Pause (`PLAY_PAUSE`)
            Button {
                bleManager.sendCommand(.playPause)
            } label: {
                Image(systemName: bleManager.isPlayingMedia ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 56, height: 56)
                    .background(
                        Circle()
                            .fill(Color.cyan.gradient)
                            .shadow(color: Color.cyan.opacity(0.55), radius: 6)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play or Pause Media")

            // Next Track (`NEXT`)
            Button {
                bleManager.sendCommand(.next)
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 42, height: 42)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next Track")
        }
        .padding(.vertical, 6)
    }

    // MARK: - Prominent "Ping Android Phone" Button (`FIND_PHONE`)

    private var pingPhoneButton: some View {
        Button {
            triggerPingAnimation()
            bleManager.sendCommand(.findPhone)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bell.and.waves.left.and.right.fill")
                    .font(.system(size: 15, weight: .bold))
                    .symbolEffect(.bounce, value: isPinging)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Ping Android Phone")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                    Text("Sends FIND_PHONE alert")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.8))
                }

                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.orange, Color.pink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: Color.orange.opacity(isPinging ? 0.8 : 0.35), radius: isPinging ? 8 : 4)
            )
        }
        .buttonStyle(.plain)
    }

    private func triggerPingAnimation() {
        isPinging.toggle()
    }
}
