import SwiftUI

/// Screen 3: Incoming Call Full-Screen Alert
/// Presented automatically whenever `callState == "RINGING"`.
/// Displays caller name, source app ("Phone", "WhatsApp", etc.), and phone number with animated concentric rings.
struct IncomingCallAlertView: View {
    let callAlert: CallAlert
    let onDismiss: () -> Void

    @State private var isPulsing = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.green.opacity(0.28),
                    Color.black,
                    Color.black
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 12) {
                Spacer(minLength: 8)

                ZStack {
                    Circle()
                        .stroke(Color.green.opacity(0.35), lineWidth: 3)
                        .frame(width: 82, height: 82)
                        .scaleEffect(isPulsing ? 1.32 : 0.92)
                        .opacity(isPulsing ? 0.0 : 0.85)

                    Circle()
                        .fill(Color.green.opacity(0.22))
                        .frame(width: 64, height: 64)

                    Image(systemName: "phone.down.waves.left.and.right")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.green)
                        .symbolEffect(.bounce, value: isPulsing)
                }

                Text("INCOMING \(callAlert.app.uppercased()) CALL")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(.green)

                Text(callAlert.callerName)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(callAlert.phoneNumber)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 8)

                Button(role: .destructive) {
                    onDismiss()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 14, weight: .bold))
                        Text("Silence / Decline")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .frame(maxWidth: 280)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                isPulsing = true
            }
        }
    }
}
