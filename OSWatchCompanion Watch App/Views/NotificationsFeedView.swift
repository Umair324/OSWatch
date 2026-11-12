import SwiftUI

/// Tab 2: Notifications Feed Tab
/// Displays a scrollable list of Android notifications with colored app badges, timestamps,
/// message previews, detail expansion, and a "Clear All" button.
struct NotificationsFeedView: View {
    @EnvironmentObject private var bleManager: BLEPeripheralManager
    @State private var selectedNotification: AndroidNotification?

    var body: some View {
        Group {
            if bleManager.notifications.isEmpty {
                emptyFeedState
            } else {
                notificationsList
            }
        }
        .navigationTitle("Alerts (\(bleManager.notifications.count))")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedNotification) { notification in
            NotificationDetailSheet(notification: notification)
        }
    }

    // MARK: - Empty State

    private var emptyFeedState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell.slash.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

            Text("No Notifications")
                .font(.system(.headline, design: .rounded))

            Text("Incoming Android notifications will appear here with haptic alerts.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)

            Button {
                bleManager.simulateChunkedNotification()
            } label: {
                Label("Simulate Alert", systemImage: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .tint(.cyan)
            .padding(.top, 4)
        }
        .padding()
    }

    // MARK: - Scrollable Notifications List

    @ViewBuilder
    private var notificationsList: some View {
        #if os(watchOS)
        baseList
            .listStyle(.carousel)
        #else
        baseList
            .listStyle(.insetGrouped)
        #endif
    }

    private var baseList: some View {
        List {
            ForEach(bleManager.notifications) { notification in
                Button {
                    selectedNotification = notification
                } label: {
                    NotificationRowCard(notification: notification)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
            }
            .onDelete { offsets in
                let idsToDelete = offsets.map { bleManager.notifications[$0].id }
                for id in idsToDelete {
                    bleManager.removeNotification(id: id)
                }
            }

            Section {
                Button(role: .destructive) {
                    withAnimation {
                        bleManager.clearAllNotifications()
                    }
                } label: {
                    HStack {
                        Spacer()
                        Label("Clear All", systemImage: "trash.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                    }
                }
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.red.opacity(0.22))
                )
            }
        }
    }
}

// MARK: - Notification Row Card

struct NotificationRowCard: View {
    let notification: AndroidNotification

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: notification.badgeIcon)
                        .font(.system(size: 9, weight: .bold))
                    Text(notification.appName.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(notification.badgeColor.gradient)
                )

                Spacer(minLength: 2)

                Text(notification.timestamp, style: .relative)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(notification.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            if !notification.body.isEmpty {
                Text(notification.body)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Full Notification Detail Sheet

struct NotificationDetailSheet: View {
    let notification: AndroidNotification
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: notification.badgeIcon)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(Circle().fill(notification.badgeColor))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(notification.appName)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(notification.badgeColor)

                        Text(notification.timestamp, format: .dateTime.hour().minute().second())
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                Text(notification.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)

                Text(notification.body)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.9))

                Button("Dismiss") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(notification.badgeColor)
                .padding(.top, 10)
            }
            .padding()
        }
    }
}
