import SwiftUI

/// Root container view coordinating the watchOS 10+ & iOS `TabView`
/// and full-screen incoming call alert overlay.
struct ContentView: View {
    @EnvironmentObject private var bleManager: BLEPeripheralManager
    @State private var selectedTab: Int = 0

    var body: some View {
        tabContainer
            .preferredColorScheme(.dark)
            .fullScreenCover(
                isPresented: Binding(
                    get: { bleManager.activeCallAlert?.isRinging == true },
                    set: { isPresented in
                        if !isPresented {
                            bleManager.dismissActiveCallAlert()
                        }
                    }
                )
            ) {
                if let callAlert = bleManager.activeCallAlert {
                    IncomingCallAlertView(callAlert: callAlert) {
                        bleManager.dismissActiveCallAlert()
                    }
                }
            }
    }

    @ViewBuilder
    private var tabContainer: some View {
        #if os(watchOS)
        TabView(selection: $selectedTab) {
            tabsContent
        }
        .tabViewStyle(.verticalPage)
        #else
        TabView(selection: $selectedTab) {
            tabsContent
        }
        .tint(.cyan)
        #endif
    }

    @ViewBuilder
    private var tabsContent: some View {
        NavigationStack {
            StatusPairingView()
        }
        .tabItem {
            Label("Status", systemImage: "antenna.radiowaves.left.and.right")
        }
        .tag(0)

        NavigationStack {
            NotificationsFeedView()
        }
        .tabItem {
            Label("Notifications", systemImage: "bell.badge.fill")
        }
        .tag(1)

        NavigationStack {
            RemoteControlsView()
        }
        .tabItem {
            Label("Remote", systemImage: "playpause.circle.fill")
        }
        .tag(2)
    }
}

#Preview {
    ContentView()
        .environmentObject(BLEPeripheralManager())
}
