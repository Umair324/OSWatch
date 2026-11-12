import SwiftUI

#if os(watchOS)
import WatchKit

final class OSWatchExtensionDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        PlatformDeviceBridge.enableBatteryMonitoring()
    }
}
#elseif canImport(UIKit)
import UIKit

final class OSWatchIOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PlatformDeviceBridge.enableBatteryMonitoring()
        return true
    }
}
#endif

@main
struct OSWatchApp: App {
    #if os(watchOS)
    @WKApplicationDelegateAdaptor(OSWatchExtensionDelegate.self) private var appDelegate
    #elseif canImport(UIKit)
    @UIApplicationDelegateAdaptor(OSWatchIOSAppDelegate.self) private var appDelegate
    #endif

    @StateObject private var bleManager = BLEPeripheralManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bleManager)
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        bleManager.refreshWatchBatteryLevel()
                        bleManager.startAdvertisingIfPossible()
                    }
                }
        }
    }
}
