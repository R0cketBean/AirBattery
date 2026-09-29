//
//  SettingsView.swift
//  AirBattery
//
//  Created by apple on 2023/9/7.
//

import SwiftUI
import ServiceManagement
import WidgetKit

struct SettingsView: View {
    @State private var selectedItem: String? = "General"
    @AppStorage("showDebug") var showDebug: Bool = false

    // Re-attempted the NavigationSplitView modernization (previous note here said this had been
    // reverted because the split view draws its own sidebar-collapse toggle button that
    // .toolbar(removing:)/.toolbar(.hidden:) couldn't reach). That modifier does work when
    // applied to the NavigationSplitView itself (it was previously being applied to an inner
    // view instead, which is why it silently did nothing) - .toolbar(removing: .sidebarToggle)
    // below removes the button. List(selection:) + plain .tag(...) rows replace the deprecated
    // tag-based NavigationLink(destination:tag:selection:label:) initializer, with the detail
    // pane driven by a switch on the same selectedItem instead of NavigationLink's own
    // destination routing.
    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $selectedItem) {
                Label("General", image: "gear").tag("General")
                Label("Menu Bar & Dock", image: "dock").tag("Display")
                Label("Nearbility", image: "nearbility").tag("Nearbility")
                Label("Nearcast", image: "nearcast").tag("Nearcast")
                Label("Widget", image: "widget").tag("Widget")
                Label("Blocklist", image: "blacklist").tag("Blocklist")
                if showDebug {
                    Label("Debug", image: "debug").tag("Debug")
                }
            }
            .listStyle(.sidebar)
            // Thinner gap above the first row - was 9pt, now 4pt.
            .padding(.top, 4)
            // NavigationSplitView lets you drag-resize the sidebar/detail divider by default,
            // which the old NavigationView never allowed - pinning min/ideal/max to the same
            // value locks the sidebar at a fixed width so the divider can't be dragged at all,
            // matching the old fixed-layout behavior.
            .navigationSplitViewColumnWidth(min: 165, ideal: 165, max: 165)
        } detail: {
            // Only Menu Bar & Dock (DisplayView) gets wrapped in a ScrollView - it's the
            // one tab whose content is taller than the fixed 440pt window, and that was
            // rendering partially scrolled/cut off until nudged. Every other tab fits fine
            // as-is, so wrapping them too just introduced an unwanted, unnecessary scroll.
            switch selectedItem {
            case "General": GeneralView()
            case "Display": ScrollView { DisplayView() }
            case "Nearbility": NearbilityView()
            case "Nearcast": NearcastView()
            case "Widget": WidgetView()
            case "Blocklist": BlacklistView()
            case "Debug": DebugView(selectedItem: $selectedItem)
            default: GeneralView()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .frame(width: 600, height: 440)
        .navigationTitle("AirBattery Settings")
    }
}

struct GeneralView: View {
    @AppStorage("showOn") var showOn = "sbar"
    @AppStorage("launchAtLogin") var launchAtLogin = false
    @AppStorage("showDebug") var showDebug: Bool = false
    // New: low battery notifications, off by default. See checkLowBattery() in
    // AirBatteryModel.swift for where these are actually read and acted on.
    @AppStorage("lowBatteryAlert") var lowBatteryAlert = false
    @AppStorage("lowBatteryThreshold") var lowBatteryThreshold = 20
    @State private var debugCount: Int = 0
    @State private var cltInstalled: Bool = false
    // New: Mac battery health / cycle count display. InternalBattery.swift already computes
    // these (health, cycleCount) from the AppleSmartBattery IORegistry entry for the charge-
    // limit-inflation fix earlier - this just surfaces that existing data in the UI instead of
    // only using it internally. nil on a Mac with no battery (Mac mini/Studio/Pro/iMac), so
    // the whole section is hidden in that case rather than showing empty fields.
    @State private var macBatteryHealth: Double? = nil
    @State private var macBatteryCycles: Int? = nil
    
    var body: some View {
        SForm {
            SGroupBox(label: "Startup") {
                SToggle("Launch at Login", isOn: $launchAtLogin)
                    .onAppear {
                        // Fetch once when the General tab first appears, not inside the
                        // conditional battery-health panel below - that panel only renders
                        // once these values are non-nil, so it can never trigger its own
                        // first fetch.
                        if let b = InternalFinder().getInternalBattery(), b.health != nil {
                            macBatteryHealth = b.health
                            macBatteryCycles = b.cycleCount
                        }
                    }
                    .onChange(of: launchAtLogin) { _, newValue in
                        // Route through ensureLoginItem() so macOS 13+ uses SMAppService.
                        ensureLoginItem(enabled: newValue)
                    }
                Divider().opacity(0.5)
                SPicker("Show AirBattery", selection: $showOn) {
                    Text("Dock").tag("dock")
                    Text("Menu Bar").tag("sbar")
                    Text("Both").tag("both")
                    Text("None").tag("none")
                }.onChange(of: showOn) { _, newValue in
                    switch newValue {
                    case "sbar":
                        statusBarItem.isVisible = true
                        for i in pinnedItems { i.isVisible = true }
                        NSApp.setActivationPolicy(.accessory)
                    case "both":
                        statusBarItem.isVisible = true
                        for i in pinnedItems { i.isVisible = true }
                        NSApp.setActivationPolicy(.regular)
                    case "dock":
                        statusBarItem.isVisible = false
                        for i in pinnedItems { i.isVisible = false }
                        NSApp.setActivationPolicy(.regular)
                    default:
                        statusBarItem.isVisible = false
                        for i in pinnedItems { i.isVisible = false }
                        NSApp.setActivationPolicy(.accessory)
                    }
                    if newValue == "dock" || newValue == "both" {
                        _ = createAlert(title: "AirBattery Tips".local, message: "Displaying AirBattery on the Dock will consume more power, it is better to use Menu Bar mode or Widgets.".local, button1: "OK").runModal()
                    }
                }
            }
            SGroupBox(label: "Notifications") {
                SToggle("Low Battery Alerts", isOn: $lowBatteryAlert, tips: "Get a notification when a device's battery drops below the threshold below, as long as it isn't charging.")
                if lowBatteryAlert {
                    Divider().opacity(0.5)
                    SSteper("Alert Threshold (%)", value: $lowBatteryThreshold, min: 5, max: 50)
                }
            }
            if let health = macBatteryHealth, let cycles = macBatteryCycles {
                SGroupBox(label: "This Mac's Battery") {
                    // Explicit .font/.frame(height: 16) to force this to match SToggle's row
                    // sizing exactly (see SToggle in GroupForm.swift) - plain Text() rows here
                    // were reportedly rendering larger than the rest of the form.
                    HStack {
                        Text("Battery Health").font(.system(size: 13))
                        Spacer()
                        Text("\(Int(health.rounded()))%").font(.system(size: 13)).foregroundColor(.secondary)
                    }.frame(height: 16)
                    Divider().opacity(0.5)
                    HStack {
                        Text("Cycle Count").font(.system(size: 13))
                        Spacer()
                        Text("\(cycles)").font(.system(size: 13)).foregroundColor(.secondary)
                    }.frame(height: 16)
                }
                .onAppear {
                    // Refresh in case the value changed since the settings window was last opened
                    if let b = InternalFinder().getInternalBattery(), b.health != nil {
                        macBatteryHealth = b.health
                        macBatteryCycles = b.cycleCount
                    }
                }
            }
            SGroupBox {
                SButton("Command Line Tool", buttonTitle: cltInstalled ? "Uninstall" : "Install",
                        tips: "After installation, you can run \"airbattery\" in yor terminal to list all devices.") {
                    if cltInstalled {
                        CommandLineTool.uninstall { updateCTL() }
                    } else {
                        CommandLineTool.install { updateCTL() }
                    }
                }.onAppear { cltInstalled = CommandLineTool.isInstalled() }
            }.padding(.top, -20)
            // Removed the "Update" section (auto-check/auto-download toggles and the "Check
            // for Updates…" button) - Sparkle's feed URL was already stripped out of Info.plist
            // earlier so it can never reach the official app's update feed and silently
            // overwrite this patched build, which means these controls could never actually do
            // anything useful and would just be confusing to have sitting in the UI. Kept the
            // version number display below.
            VStack(spacing: 8) {
                if let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    Text("AirBattery v\(appVersion)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .onTapGesture {
                            debugCount += 1
                            if debugCount > 9 {
                                debugCount = 0
                                showDebug.toggle()
                            }
                        }
                }
            }
        }
    }
    func updateCTL() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            cltInstalled = CommandLineTool.isInstalled()
        }
    }
}

struct NearbilityView: View {
    @ObservedObject private var bleScanner = bleBattery
    @AppStorage("ideviceOverBLE") var ideviceOverBLE = false
    @AppStorage("readBTDevice") var readBTDevice = true
    @AppStorage("readBLEDevice") var readBLEDevice = false
    @AppStorage("readPencil") var readPencil = false
    @AppStorage("readIDevice") var readIDevice = true
    @AppStorage("readBTHID") var readBTHID = true
    @AppStorage("updateInterval") var updateInterval = 1
    @AppStorage("twsMerge") var twsMerge = 5
    @State private var showIOSBluetoothDevices = false
    @AppStorage("neverMergeTws") var neverMergeTws = false

    var body: some View {
        SForm {
            SGroupBox(label: "Scanner") {
                SToggle("Discover iOS devices via Network", isOn: $readIDevice, tips: "Scan your iPhone / iPad / Apple Watch / VisionPro and other iDevices in your local network.")
                Divider().opacity(0.5)
                SToggle("Discover iOS devices via Bluetooth", isOn: $ideviceOverBLE, tips: "Scan only the iPhone and iPad that you explicitly authorize via Bluetooth.")
                    .onChange(of: ideviceOverBLE) { newValue in
                        if newValue {
                            showIOSBluetoothDevices = bleScanner.authorizedIOSDevices.isEmpty
                            bleScanner.refreshIOSDevices()
                        } else {
                            bleScanner.cancelIOSConnections()
                        }
                    }
                if ideviceOverBLE {
                    Divider().opacity(0.5)
                    SButton("Authorized iOS Bluetooth Devices", buttonTitle: "Manage") {
                        showIOSBluetoothDevices = true
                        bleScanner.refreshIOSDevices()
                    }
                }
                Divider().opacity(0.5)
                SToggle("Discover BT and BLE devices", isOn: $readBTDevice, tips: "Get the battery usage of some Bluetooth peripherals like mouse, keyboard, headphone or etc.\n\nIf some of your device is not shown, try enabling \"Discover more BT devices\" or \"Discover more BLE devices\"")
                Divider().opacity(0.5)
                SToggle("Discover more BT devices", isOn: $readBTHID, tips: "Get the battery usage of more third-party Bluetooth devices\n\nBattery data will be updated when devices are reconnected to the Mac or the Mac wakes up.")
                Divider().opacity(0.5)
                SToggle("Discover more BLE devices", isOn: $readBLEDevice, tips: "Try to get the battery usage of any Bluetooth device that AirBattery can find\n\nWARNING: This is a BETA feature and may cause unexpected errors!")
                    .foregroundColor(.orange)
                    .onChange(of: readBLEDevice) { _, newValue in
                        if newValue {
                            _ = createAlert(title: "AirBattery Tips".local, message: "If you see a bluetooth pairing request from any device that isn't yours, add it to your blocklist!".local, button1: "OK").runModal()
                        }
                    }
                Divider().opacity(0.5)
                SToggle("Apple Pencil from your iPad", isOn: $readPencil, tips: "Read the battery status of the connected Apple Pencil through your iPad\n(It may take 10 minutes or longer to discover the Pencil for the first time)\n\nWARNING: This is a BETA feature and may drain your iPad's battery faster!")
                    .foregroundColor(.orange)
            }
            SGroupBox(label: "Others") {
                VStack(spacing: 2) {
                    SSteper("Refresh Interval (min)", value: $updateInterval, min: 1, max: 99)
                    if updateDelay != updateInterval {
                        HStack {
                            Text("Relaunch AirBattery to apply this change")
                                .font(.footnote)
                                .foregroundColor(.red)
                            Spacer()
                        }
                    }
                }
                Divider().opacity(0.5)
                SToggle("Always show earbuds separately", isOn: $neverMergeTws, tips: "Always show the left and right earbuds as separate devices, instead of merging them into one entry when their battery levels are close.")
                if !neverMergeTws {
                    Divider().opacity(0.5)
                    SSteper("Earbud Merging Threshold", value: $twsMerge, min: 1, max: 99, tips: "If the difference in battery usage between the left and right earbuds is less than this value, AirBattery will show them as one device.")
                }
            }
        }
        .sheet(isPresented: $showIOSBluetoothDevices) {
            IOSBluetoothDevicesView()
        }
    }
}

struct IOSBluetoothDevicesView: View {
    @ObservedObject private var scanner = bleBattery
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("iOS Bluetooth Devices")
                .font(.headline)
            Text("AirBattery will only connect to devices authorized here. Pair only an iPhone or iPad you own; it may show a one-time system pairing request.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox(label: Text("Authorized Devices")) {
                VStack(spacing: 8) {
                    if scanner.authorizedIOSDevices.isEmpty {
                        Text("No authorized devices")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(scanner.authorizedIOSDevices.keys.sorted(), id: \.self) { identifier in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(scanner.authorizedIOSDevices[identifier] ?? "iPhone / iPad")
                                    Text(shortIdentifier(identifier))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Forget") {
                                    if let uuid = UUID(uuidString: identifier) {
                                        scanner.forgetIOSDevice(uuid)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(5)
            }

            GroupBox(label: Text("Nearby Apple Devices (type unverified)")) {
                ScrollView {
                    VStack(spacing: 8) {
                        if scanner.nearbyIOSDevices.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.7)
                                Text("Scanning nearby Apple devices…")
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(scanner.nearbyIOSDevices) { device in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.name)
                                        Text("\(shortIdentifier(device.id.uuidString)) · \(device.rssi) dBm")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if scanner.isIOSDeviceAuthorized(device.id) {
                                        Text("Authorized")
                                            .foregroundColor(.secondary)
                                    } else {
                                        Button(scanner.pendingIOSDeviceIDs.contains(device.id) ? "Connecting…".local : "Pair…".local) {
                                            scanner.authorizeIOSDevice(device.id)
                                        }
                                        .disabled(scanner.pendingIOSDeviceIDs.contains(device.id))
                                    }
                                }
                            }
                        }
                    }
                    .padding(5)
                }
                .frame(height: 105)
            }

            Text("Nearby Apple devices may include Macs and Apple Watches. Select only your iPhone or iPad. Open Personal Hotspot and move it close to the Mac before connecting.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Scan Again") { scanner.refreshIOSDevices() }
                Spacer()
                Button("Done") { presentationMode.wrappedValue.dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 460)
        .onAppear { scanner.refreshIOSDevices() }
        .alert(item: $scanner.iosConnectionFailure) { failure in
            Alert(title: Text("Bluetooth connection failed"), message: Text(failure.message), dismissButton: .default(Text("OK")))
        }
    }

    private func shortIdentifier(_ identifier: String) -> String {
        String(identifier.suffix(8))
    }
}

struct NearcastView: View {
    @AppStorage("nearCast") var nearCast = false
    @AppStorage("ncGroupID") var ncGroupID = ""
    @State var debug: Bool = false
    
    var body: some View {
        SForm {
            SGroupBox(label: "Nearcast") {
                SToggle("Enable Nearcast", isOn: $nearCast)
                    .onChange(of: nearCast) { _, newValue in
                        if newValue {
                            if ncGroupID != "" && isGroudIDValid(id: ncGroupID) {
                                netcastService.resume()
                            } else {
                                DispatchQueue.main.async { nearCast = false; ncGroupID = "" }
                                _ = createAlert(
                                    title: "Invalid group ID".local,
                                    message: "Please create or enter a valid Group ID before use!",
                                    button1: "OK".local
                                ).runModal()
                            }
                        } else {
                            netcastService.stop()
                        }
                    }
                Divider().opacity(0.5)
                HStack(spacing: 4) {
                    SField("Group ID", text: $ncGroupID).disabled(nearCast)
                    Button(action: {
                        ncGroupID = "nc-" + randomString(length: 20)
                    }, label: {
                        if ncGroupID != "" {
                            Image(systemName: "arrow.clockwise.circle")
                                .font(.system(size: 15, weight: .light))
                        } else {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 15, weight: .light))
                        }
                    })
                    .buttonStyle(.plain)
                    .disabled(nearCast)
                    Button(action: {
                        if ncGroupID != "" && isGroudIDValid(id: ncGroupID) {
                            copyToClipboard(ncGroupID)
                            _ = createAlert(title: "Group ID Copied".local,
                                            message: String(format: "Group ID has been copied to the clipboard.".local, ncGroupID),
                                            button1: "OK".local).runModal()
                        } else {
                            DispatchQueue.main.async { ncGroupID = "" }
                            _ = createAlert(
                                title: "Invalid group ID".local,
                                message: "Please create or enter a valid Group ID before use!",
                                button1: "OK".local
                            ).runModal()
                        }
                    }, label: {
                        Image("list.clipboard.fill.circle")
                            .resizable().scaledToFit()
                            .frame(width: 15, height: 15)
                    }).buttonStyle(.plain)
                }.frame(height: 16)
                Divider().opacity(0.5)
                VStack(spacing: 2) {
                    Text("Nearcast will broadcast your battery data within the local network.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Text("Your data has been encrypted using the group id, don't share it with others.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            SGroupBox(label: "Peer Info") {
                HStack {
                    Text("Local ID")
                    Spacer()
                    Text(netcastService.transceiver.localPeerId ?? "")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

struct DisplayView: View {
    @AppStorage("appearance") var appearance = "auto"
    @AppStorage("showThisMac") var showThisMac = "icon"
    @AppStorage("carouselMode") var carouselMode = true
    @AppStorage("colorfulBattery") var colorfulBattery = false
    @AppStorage("iosBatteryStyle") var iosBatteryStyle = false
    @AppStorage("intBattOnStatusBar") var intBattOnStatusBar = true
    @AppStorage("batteryPercent") var batteryPercent = "outside"
    @AppStorage("hideLevel") var hideLevel = 90
    @AppStorage("showChargePower") var showChargePower = false
    @AppStorage("disappearTime") var disappearTime = 20
    @AppStorage("pinnedBatteryBar") var pinnedBatteryBar = false
    @AppStorage("deviceSortOrder") var deviceSortOrder = "default"
    @State private var levelList = [95, 90, 80, 70, 60, 50, 40, 30, 20, 10]
    
    var body: some View {
        SForm {
            SGroupBox(label: "Menu Bar") {
                SToggle("Dynamic Battery Icon", isOn: $intBattOnStatusBar)
                Divider().opacity(0.5)
                SToggle("Colorful Battery Icon", isOn: $colorfulBattery)
                    .disabled(!intBattOnStatusBar)
                Divider().opacity(0.5)
                SPicker("Battery Icon Style", selection: $iosBatteryStyle) {
                    Text("macOS").tag(false)
                    Text("iOS").tag(true)
                }.disabled(!intBattOnStatusBar)
                Divider().opacity(0.5)
                SPicker("Show Percentage", selection: $batteryPercent) {
                    Text("Hidden").tag("hide")
                    Text("Inside").tag("inside")
                    Text("Outside").tag("outside")
                }.disabled(!intBattOnStatusBar)
                Divider().opacity(0.5)
                SToggle("Show Charging Power", isOn: $showChargePower)
                    .disabled(!intBattOnStatusBar)
                Divider().opacity(0.5)
                // "Never" uses -1: a UInt32 tag never matches the Int binding in a Picker.
                SPicker("Remove Offline Device", selection: $disappearTime) {
                    Text("Never").tag(-1)
                    Text("after 20min").tag(20)
                    Text("after 40min").tag(40)
                    Text("after 60min").tag(60)
                }
                Divider().opacity(0.5)
                SPicker("Hide percentage when above", selection: $hideLevel) {
                    Text("Never").tag(100)
                    ForEach(levelList, id: \.self) { number in
                        Text("\(number)%").tag(number)
                    }
                    if !levelList.contains(hideLevel) && hideLevel != 100 {
                        Text("\(hideLevel)%").tag(hideLevel)
                    }
                }.disabled(!intBattOnStatusBar || (batteryPercent == "hide"))
            }
            SGroupBox(label: "Pinned Devices") {
                SToggle("Show Battery Bar", isOn: $pinnedBatteryBar, tips: "Show a battery bar graphic instead of a percentage number for devices pinned to the menu bar.")
                    .onChange(of: pinnedBatteryBar) { _, _ in refeshPinnedBar() }
            }
            SGroupBox(label: "Sorting") {
                SPicker("Sort Devices By", selection: $deviceSortOrder, tips: "Choose how devices are ordered in the list. A device's own sub-devices (like an AirPods case and its earbuds) always stay grouped together.") {
                    Text("Default").tag("default")
                    Text("Name (A-Z)").tag("name")
                    Text("Battery Level (Low to High)").tag("level_asc")
                    Text("Battery Level (High to Low)").tag("level_desc")
                }
            }
            SGroupBox(label: "Dock") {
                    SPicker("Appearance", selection: $appearance) {
                        Text("Automatic").tag("auto")
                        Text("Light").tag("false")
                        Text("Dark").tag("true")
                    }.pickerStyle(.segmented)
                    Divider().opacity(0.5)
                    SPicker("Built-in Battery Style", selection: $showThisMac, tips: "Show or hide this Mac's built-in battery in the Dock icon") {
                        Text("Hidden").tag("hidden")
                        Text("Device Icon").tag("icon")
                        Text("Percent").tag("percent")
                    }
                    Divider().opacity(0.5)
                    SToggle("Carousel Mode", isOn: $carouselMode, tips: "Cycle through all found devices in the Dock icon")
            }
        }
    }
}

struct WidgetView: View {
    //@AppStorage("showMacOnWidget") var showMacOnWidget = true
    @AppStorage("revListOnWidget") var revListOnWidget = false
    @AppStorage("deviceOnWidget") var deviceOnWidget = ""
    @AppStorage("widgetInterval") var widgetInterval = 0
    @AppStorage("deviceName") var deviceName = "Mac"
    // Fixes issue #119 (feature request). This mirrors AirBatteryModel's file-based flag (a
    // plain @AppStorage bool here wouldn't be visible to the sandboxed widget process - see
    // the comment on getWhiteWidgetBackground() for why), initialized from that file on
    // appear so the toggle reflects the real current setting.
    @State private var whiteWidgetBackground = AirBatteryModel.getWhiteWidgetBackground()

    @State var ib = getMacDeviceType().lowercased().contains("book")
    @State var devices = [String]()

    var body: some View {
        SForm {
            SGroupBox(label: "Widget") {
                SToggle("White Widget Background", isOn: $whiteWidgetBackground, tips: "Use a plain white background for widgets instead of the default.")
                    .onChange(of: whiteWidgetBackground) { _, newValue in
                        AirBatteryModel.setWhiteWidgetBackground(newValue)
                        WidgetCenter.shared.reloadAllTimelines()
                    }
                Divider().opacity(0.5)
                SToggle("Reverse Device List", isOn: $revListOnWidget)
                Divider().opacity(0.5)
                SPicker("Refresh Interval", selection: $widgetInterval) {
                    Text("System Default").tag(-1)
                    Text("Same as Nearbility").tag(0)
                }
                Divider().opacity(0.5)
                SButton("Reload All Widgets", buttonTitle: "Reload") {
                    AirBatteryModel.writeData()
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }
        }
        .onAppear { devices = AirBatteryModel.getAll(noFilter: true).filter({ $0.hasBattery }).map({ $0.deviceName }) }
    }
}

struct BlacklistView: View {
    @AppStorage("whitelistMode") var whitelistMode = false
    @State private var blockedItems = [String]()
    @State private var temp = ""
    @State private var showSheet = false
    @State private var editingIndex: Int?
    
    var body: some View {
        SForm(noSpacer: true) {
            SGroupBox(label: "Blocklist") {
                    SToggle("Allowlist Mode", isOn: $whitelistMode)
                    Divider().opacity(0.5)
                    HStack {
                        Spacer()
                        Text(whitelistMode ? "Only the following devices will be showed" : "The following devices will be ignored")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    ZStack(alignment: Alignment(horizontal: .trailing, vertical: .bottom)) {
                        List {
                            ForEach(0..<blockedItems.count, id: \.self) { index in
                                HStack {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(.red)
                                        .onTapGesture { if editingIndex == nil { blockedItems.remove(at: index) } }
                                    Text(blockedItems[index])
                                }
                            }
                        }
                        Button(action: {
                            showSheet = true
                        }) {
                            Image(systemName: "plus.square.fill")
                                .font(.system(size: 20))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .sheet(isPresented: $showSheet){
                            VStack {
                                TextField("Enter Device Name".local, text: $temp).frame(width: 300)
                                HStack(spacing: 20) {
                                    Button {
                                        if temp == "" { return }
                                        if !blockedItems.contains(temp) { blockedItems.append(temp) }
                                        temp = ""
                                        showSheet = false
                                    } label: {
                                        Text("Add to List").frame(width: 80)
                                    }.keyboardShortcut(.defaultAction)
                                    Button {
                                        showSheet = false
                                    } label: {
                                        Text("Cancel").frame(width: 80)
                                    }
                                }.padding(.top, 10)
                            }.padding()
                        }
                    }
            }
            .onAppear { blockedItems = (ud.object(forKey: "blockedDevices") as? [String]) ?? [String]() }
            .onChange(of: blockedItems) { _, b in ud.setValue(b, forKey: "blockedDevices") }
        }
    }
}

struct DebugView: View {
    @AppStorage("test_debug") var test_debug = false
    @AppStorage("test_hasib") var test_hasib = false
    @AppStorage("test_acpower") var test_ac = false
    @AppStorage("test_full") var test_full = false
    @AppStorage("test_iblevel") var test_iblevel = 100
    @AppStorage("showDebug") var showDebug: Bool = false
    
    @State private var deviceID: String = ""
    @State private var deviceType: String = ""
    @State private var deviceName: String = ""
    @State private var deviceModel: String = ""
    @State private var parentName: String = ""
    @State private var batteryLevel: Int = 0
    @State private var lowPower: Bool = false
    @State private var isCharging: Bool = false
    @State private var fullCharged: Bool = false
    @State private var isPresented: Bool = false
    
    @Binding var selectedItem: String?
    
    var body: some View {
        SForm(noSpacer: true) {
            SGroupBox {
                SToggle("Debug Mode", isOn: $test_debug)
                Divider().opacity(0.5)
                SButton("Data Folder", buttonTitle: "Open") {
                    NSWorkspace.shared.open(ncFolder.deletingLastPathComponent())
                }
            }
            SGroupBox(label: "Built-in Battery") {
                SToggle("Built-in Battery", isOn: $test_hasib)
                Divider().opacity(0.5)
                SToggle("AC Powered", isOn: $test_ac)
                Divider().opacity(0.5)
                SToggle("Paused", isOn: $test_full)
                Divider().opacity(0.5)
                SSteper("Level", value: $test_iblevel, min: 1)
            }
            SGroupBox(label: "Remote Battery") {
                HStack {
                    Text("Create Item")
                    Spacer()
                    Button(action: {
                        isPresented = true
                    }, label: {
                        Image(systemName: "plus.circle.fill")
                    })
                    .buttonStyle(.plain)
                    .sheet(isPresented: $isPresented) {
                        VStack {
                            SGroupBox(label: "Remote Battery") {
                                SField("Device ID", text: $deviceID)
                                Divider().opacity(0.5)
                                SField("Device Name", text: $deviceName)
                                Divider().opacity(0.5)
                                SField("Device Type", text: $deviceType)
                                Divider().opacity(0.5)
                                SField("Device Model", text: $deviceModel)
                                Divider().opacity(0.5)
                                HStack {
                                    SField("Parent Name", text: $parentName)
                                    Button(action: {
                                        parentName = getMacDeviceName()
                                    }, label: {
                                        let ib = ib2ab(InternalBattery.status)
                                        Image(getDeviceIcon(ib))
                                            .resizable().scaledToFit()
                                            .frame(width: 16, height: 16)
                                    }).buttonStyle(.plain)
                                }
                                Divider().opacity(0.5)
                                SSteper("Level", value: $batteryLevel)
                                Divider().opacity(0.5)
                                SToggle("Charging", isOn: $isCharging)
                                Divider().opacity(0.5)
                                SToggle("Paused", isOn: $fullCharged)
                                Divider().opacity(0.5)
                                SToggle("Low Power", isOn: $lowPower)
                            }
                            HStack {
                                Spacer()
                                Button(action: {
                                    isPresented = false
                                }, label: {
                                    Text("Cancle").frame(width: 50)
                                })
                                Button(action: {
                                    let device = Device(deviceID: deviceID, deviceType: deviceType, deviceName: deviceName, batteryLevel: batteryLevel, isCharging: isCharging ? 1 : (fullCharged ? 5 : 0), lowPower: lowPower, parentName: parentName,lastUpdate: Date().timeIntervalSince1970)
                                    AirBatteryModel.updateDevice(device)
                                    isPresented = false
                                }, label: {
                                    Text("Add").frame(width: 50)
                                }).keyboardShortcut(.defaultAction)
                            }
                        }
                        .padding()
                        .onAppear {
                            deviceID = randomString(length: 10)
                            deviceType = "virtual"
                            deviceName = "Virtual Device"
                            deviceModel = ""
                            parentName = ""
                            batteryLevel = 100
                            lowPower = false
                            isCharging = false
                            fullCharged = false
                        }
                    }
                }
            }
            Button("Hide Debug Menu", action: {
                test_debug = false
                showDebug = false
                selectedItem = "General"
            })
            .padding(.top, -6)
        }
    }
}
