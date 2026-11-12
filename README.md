# OSWatch Companion — watchOS 10+ & iOS (iPhone) BLE Peripheral App

A **CoreBluetooth** (`CBPeripheralManager`) and **SwiftUI** companion app that runs natively on both **iPhone (iOS 17.0+)** and **Apple Watch (watchOS 10.0+)**. It acts as a Bluetooth Low Energy (BLE) Peripheral for an Android smartphone host app to receive chunked notifications, incoming call alerts, and battery status, and send media/ping commands back.

---

## Folder Structure

```text
Oswatch/
├── .github/
│   └── workflows/
│       └── build-ios.yml                     # GitHub Actions (macos-latest) unsigned .ipa builder
├── OSWatchCompanion.xcodeproj/
│   ├── project.pbxproj                       # Dual-target Xcode project (iOS + watchOS)
│   └── xcshareddata/xcschemes/
│       └── OSWatchCompanion.xcscheme         # Shared iOS scheme for CI/xcodebuild
├── project.yml                               # Dual-target XcodeGen specification
├── README.md
├── OSWatchCompanion iOS/
│   └── Info.plist                            # iOS Info.plist with bluetooth-peripheral background mode
└── OSWatchCompanion Watch App/
    ├── Info.plist                            # watchOS Info.plist with WKBackgroundModes
    ├── OSWatchApp.swift                      # Shared @main entry point (iOS & watchOS)
    ├── Assets.xcassets/                      # Shared AppIcon & AccentColor assets
    ├── Models/
    │   └── Models.swift                      # GATT UUIDs, AndroidNotification, CallAlert, BLECommand
    ├── Bluetooth/
    │   ├── BLEPacketReassembler.swift        # Multi-part ("1/3|...") chunk buffer & JSON decoder
    │   └── BLEPeripheralManager.swift        # Cross-platform CBPeripheralManager, haptics & battery
    └── Views/
        ├── ContentView.swift                 # Adaptive TabView + Incoming Call .fullScreenCover
        ├── StatusPairingView.swift           # Tab 1: Glowing status ring, broadcast toggle, dual gauges
        ├── NotificationsFeedView.swift       # Tab 2: Colored app badges, feed, detail sheet, Clear All
        ├── IncomingCallAlertView.swift       # Screen 3: Full-screen RINGING call alert with haptics
        └── RemoteControlsView.swift          # Tab 4: PREV, PLAY_PAUSE, NEXT & Ping Android Phone button
```

---

## Building & Installing on iPhone from Windows (GitHub Actions + Sideloadly)

No Mac is required! You can compile the unsigned `.ipa` in the cloud using GitHub Actions and install it onto your iPhone with **Sideloadly** on Windows:

### Step 1: Push Project to GitHub
Run these commands in PowerShell inside `c:\Users\Raza\Downloads\Oswatch`:
```powershell
git init
git add .
git commit -m "Add iOS target and GitHub Actions IPA workflow"
git branch -M main
git remote add origin https://github.com/<your-username>/<your-repo>.git
git push -u origin main
```

### Step 2: Download `OSWatchCompanion.ipa` from GitHub Actions
1. Open your GitHub repository in the browser and click the **Actions** tab.
2. Select the **Build Unsigned iOS IPA (Sideloadly)** workflow run (or click **Run workflow** to trigger it manually).
3. Once the job finishes (~1–2 minutes), scroll to the **Artifacts** section at the bottom of the run summary and download **OSWatchCompanion-IPA**.
4. Extract the downloaded zip archive to get `OSWatchCompanion.ipa`.

### Step 3: Sideload to Your iPhone via Sideloadly (Windows)
1. Connect your iPhone to your Windows PC via USB and open **Sideloadly**.
2. Drag and drop `OSWatchCompanion.ipa` into the IPA slot in Sideloadly.
3. Enter your Apple ID email and click **Start** (Sideloadly will sign the unsigned `.ipa` with your free Apple ID certificate and install it).
4. On your iPhone, go to **Settings → General → VPN & Device Management**, trust your Apple ID developer certificate, and enable **Developer Mode** under **Settings → Privacy & Security → Developer Mode** if prompted.
5. Launch **OSWatch** on your iPhone and allow Bluetooth access when prompted!

---

## Shared BLE GATT Protocol

| Attribute | UUID | Properties | Permissions | Direction & Payload Format |
| :--- | :--- | :--- | :--- | :--- |
| **Primary Service** | `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` | Primary | — | Advertised as `OSWatch-BLE` |
| **RX Characteristic** | `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` | `Write`, `WriteWithoutResponse` | `.writeable` | **Android → Watch/iPhone:** Chunked JSON (`1/3\|...`) for notifications & calls |
| **TX Characteristic** | `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` | `Notify` | `.readable` | **Watch/iPhone → Android:** UTF-8 commands (`PLAY_PAUSE`, `NEXT`, `PREV`, `FIND_PHONE`) |
| **Battery Characteristic** | `6E400004-B5A3-F393-E0A9-E50E24DCCA9E` | `Read`, `Write`, `WriteWithoutResponse`, `Notify` | `.readable`, `.writeable` | **Read:** Local Watch/iPhone battery % (`0..100`)<br>**Write:** Android battery % (`0..100`) |
