//
//  AirpodsBattery.swift
//  AirBattery
//
//  Created by apple on 2024/2/9.
//
//  =================================================
//  AirPods Pro/Beats BLE regular broadcast packet format analysis:
//  advertisementData length = 29 bytes
//  00~01: Manufacturer ID, fixed 4c00
//  02~04: Unknown
//  05~06: Device model ID:
//           0220 = Airpods
//           0e20 = Airpods Pro
//           0a20 = Airpods Max
//           0f20 = Airpods 2
//           1320 = Airpods 3
//           1420 = Airpods Pro 2
//           0320 = PowerBeats
//           0b20 = PowerBeats Pro
//           0c20 = Beats Solo Pro
//           1120 = Beats Studio Buds
//           1020 = Beats Flex
//           0520 = BeatsX
//           0620 = Beats Solo3
//           0920 = Beats Studio3
//           1720 = Beats Studio Pro
//           1220 = Beats Fit Pro
//           1620 = Beats Studio Buds+
//  07.1:  Unknown
//  07.2:  Earbud-out-of-case status:
//           5 = both earbuds in the case
//           1 = either earbud taken out
//  08.1:  Rough battery level (left earbud):
//           0~10: x10 = battery level, f: no signal
//  08.2:  Rough battery level (right earbud):
//           0~10: x10 = battery level, f: no signal
//  09.1:  Unknown
//  09.2:  Charging status
//  10.1:  Lid-flip indicator
//  10.2:  Unknown
//  14:    Left earbud battery/charging indicator
//           ff = no signal
//           <64(hex) = not charging, current battery level
//           >64(hex) = charging, subtract 80(hex) for current battery level
//  15:    Right earbud battery/charging indicator
//           ff = no signal
//           <64(hex) = not charging, current battery level
//           >64(hex) = battery level (charging, subtract 80(hex) for current battery level)
//  16:    Case battery/charging indicator
//           ff = no signal
//           <64(hex) = not charging
//           >64(hex) = charging, subtract 80(hex) for current battery level
//  17~19: Unknown
//  20~23: Unknown
//  24~28: Unknown
//  =================================================
//  AirPods Pro 2 BLE lid-closed broadcast packet format analysis:
//  advertisementData length = 25 bytes
//  00~01: Manufacturer ID, fixed 4c00
//  02~03: Unknown
//  04:    Earbud-out-of-case status:
//           24 = both earbuds out of the case
//           26 = only right earbud taken out
//           2c = only left earbud taken out
//           2e = both earbuds in the case
//  05:    Unknown
//  06~10: Unknown
//  11:    Unknown
//  12:    Case battery/charging indicator
//           no signal = ff
//           <64(hex) = battery level (not charging)
//           >64(hex) = battery level (charging, subtract 80(hex) for current battery level)
//  13:    Left earbud battery/charging indicator
//           taken out = ff
//           >64(hex) = battery level (charging, subtract 80(hex) for current battery level)
//  14:    Right earbud battery/charging indicator
//           taken out = ff
//           >64(hex) = battery level (charging, subtract 80(hex) for current battery level)
//  15~20: Unknown
//  21~22: Unknown
//  23~24: Unknown
//  =================================================
import SwiftUI
import Foundation
import CoreBluetooth
import IOBluetooth

/// Keeps the authorization and retry rules independent from CoreBluetooth so
/// an advertisement can never connect a new iOS device by itself.
struct IOSBLEConnectionPolicy {
    private(set) var authorizedIDs: Set<UUID>
    private(set) var pendingAuthorizationIDs: Set<UUID> = []
    private(set) var connectingIDs: Set<UUID> = []
    private(set) var lastFailure: [UUID: Date] = [:]
    let retryInterval: TimeInterval

    init(authorizedIDs: Set<UUID> = [], retryInterval: TimeInterval = 60 * 60) {
        self.authorizedIDs = authorizedIDs
        self.retryInterval = retryInterval
    }

    func isAuthorized(_ identifier: UUID) -> Bool {
        authorizedIDs.contains(identifier)
    }

    func isAuthorizationPending(_ identifier: UUID) -> Bool {
        pendingAuthorizationIDs.contains(identifier)
    }

    func canConnect(_ identifier: UUID, now: Date = Date()) -> Bool {
        guard authorizedIDs.contains(identifier) || pendingAuthorizationIDs.contains(identifier) else { return false }
        guard !connectingIDs.contains(identifier) else { return false }
        if let failedAt = lastFailure[identifier], now.timeIntervalSince(failedAt) < retryInterval { return false }
        return true
    }

    mutating func requestAuthorization(_ identifier: UUID) {
        pendingAuthorizationIDs.insert(identifier)
        // An explicit user action is allowed to retry immediately.
        lastFailure.removeValue(forKey: identifier)
    }

    @discardableResult
    mutating func markConnectionStarted(_ identifier: UUID, now: Date = Date()) -> Bool {
        guard canConnect(identifier, now: now) else { return false }
        connectingIDs.insert(identifier)
        return true
    }

    /// Returns true when an explicit authorization has just been promoted to
    /// the persistent allowlist.
    @discardableResult
    mutating func markConnectionSucceeded(_ identifier: UUID) -> Bool {
        connectingIDs.remove(identifier)
        lastFailure.removeValue(forKey: identifier)
        guard pendingAuthorizationIDs.remove(identifier) != nil else { return false }
        authorizedIDs.insert(identifier)
        return true
    }

    mutating func markConnectionFailed(_ identifier: UUID, at date: Date = Date()) {
        connectingIDs.remove(identifier)
        pendingAuthorizationIDs.remove(identifier)
        lastFailure[identifier] = date
    }

    mutating func markDisconnected(_ identifier: UUID) {
        connectingIDs.remove(identifier)
    }

    mutating func cancelConnection(_ identifier: UUID) {
        connectingIDs.remove(identifier)
        pendingAuthorizationIDs.remove(identifier)
    }

    mutating func forget(_ identifier: UUID) {
        authorizedIDs.remove(identifier)
        pendingAuthorizationIDs.remove(identifier)
        connectingIDs.remove(identifier)
        lastFailure.removeValue(forKey: identifier)
    }
}

struct IOSBLEDevice: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
    var lastSeen: Date
}

struct IOSBLEFailure: Identifiable {
    let id = UUID()
    let message: String
}

class BLEBattery: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let authorizedIOSDevicesKey = "authorizedIOSBLEDevices"

    @AppStorage("ideviceOverBLE") var ideviceOverBLE = false
    //@AppStorage("cStatusOfBLE") var cStatusOfBLE = false
    @AppStorage("readBTDevice") var readBTDevice = true
    @AppStorage("readBLEDevice") var readBLEDevice = false
    @AppStorage("updateInterval") var updateInterval = 1
    @AppStorage("twsMerge") var twsMerge = 5
    // Fixes issue #116 (feature request): lets the user force AirPods-style earbuds to
    // always display as separate Left/Right(/Case) entries, instead of the automatic
    // merge-into-one-entry behavior below when their battery levels are close together.
    @AppStorage("neverMergeTws") var neverMergeTws = false

    var centralManager: CBCentralManager!
    @Published private(set) var nearbyIOSDevices: [IOSBLEDevice] = []
    @Published private(set) var authorizedIOSDevices: [String: String]
    @Published private(set) var pendingIOSDeviceIDs: Set<UUID> = []
    @Published var iosConnectionFailure: IOSBLEFailure?
    private var iosAttemptTokens: [UUID: UUID] = [:]

    var peripherals: [CBPeripheral?] = []
    var otherAppleDevices: Set<UUID> = []
    var bleDevicesLevel: [String:UInt8] = [:]
    var bleDevicesVendor: [String:String] = [:]
    var scanTimer: Timer?
    private var discoveredIOSPeripherals: [UUID: CBPeripheral] = [:]
    private var iosConnectionPolicy: IOSBLEConnectionPolicy
    private var iosServicesRemaining: [UUID: Int] = [:]
    private var iosReadsRemaining: [UUID: Int] = [:]
    private var iosConnectionsWithErrors: Set<UUID> = []
    private var iosBatteryReadSucceeded: Set<UUID> = []
    // Tracks how many characteristic reads are still outstanding for a peripheral we
    // connected to just to read its battery/model/vendor info, keyed by peripheral
    // identifier. See disconnectWhenDone()/finishedRead() below.
    var pendingReads: [String: Int] = [:]
    // Support for the issue #132 fix above: peripheral identifiers already connected-to and
    // confirmed (via GATT service discovery) not to expose a battery characteristic, so they
    // aren't reconnected-to every scan cycle. Cleared implicitly on relaunch, so a device that
    // adds battery support later (e.g. a firmware update) is naturally re-probed next launch.
    var knownNonBatteryPeripherals: Set<String> = []
    // Marked true for a peripheral identifier the moment a battery-relevant characteristic
    // (2A19/2A24/2A29 on service 180F/180A) is actually found, so the 8-second safety-net
    // disconnect below can tell a genuine battery device apart from one that truly has none.
    var hasBatteryCharacteristic: Set<String> = []
    //var a = 1
    //var mfgData: Data!
    
    override init() {
        let savedDevices = UserDefaults.standard.dictionary(forKey: Self.authorizedIOSDevicesKey)?
            .compactMapValues { $0 as? String } ?? [:]
        authorizedIOSDevices = savedDevices
        iosConnectionPolicy = IOSBLEConnectionPolicy(
            authorizedIDs: Set(savedDevices.keys.compactMap(UUID.init(uuidString:)))
        )
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            // Start scanning
            scan(longScan: true)
        } else {
            // Bluetooth unavailable, stop scanning
            //stopScan()
        }
    }

    func startScan() {
        // Start a scan periodically
        let interval = TimeInterval(29 * updateInterval)
        scanTimer = Timer.scheduledTimer(timeInterval: interval, target: self, selector: #selector(scan), userInfo: nil, repeats: true)
        print("ℹ️ Start scanning BLE devices...")
        // Start a scan immediately
        scan(longScan: true)
    }

    @objc func scan(longScan: Bool = false) {
        if centralManager.state == .poweredOn && !centralManager.isScanning {
            centralManager.scanForPeripherals(withServices: nil, options: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + (longScan ? 15.0 : 5.0)) {
                self.stopScan()
            }
        }
    }

    func stopScan() {
        centralManager.stopScan()
    }

    func refreshIOSDevices() {
        nearbyIOSDevices.removeAll()
        discoveredIOSPeripherals.removeAll()
        scan(longScan: true)
    }

    func authorizeIOSDevice(_ identifier: UUID) {
        guard !iosConnectionPolicy.connectingIDs.contains(identifier) else { return }
        guard ideviceOverBLE, centralManager.state == .poweredOn else {
            reportIOSFailure("Enable Bluetooth and iOS discovery before trying again.")
            return
        }
        guard let peripheral = discoveredIOSPeripherals[identifier] else {
            reportIOSFailure("Device is no longer available. Scan again and retry.")
            return
        }
        // Do not publish a pending authorization unless a request can start.
        // Cancellation is asynchronous: the previous peripheral may still be
        // disconnecting when the user retries.
        guard peripheral.state == .disconnected else {
            reportIOSFailure("The previous connection is still closing. Wait a moment and retry.")
            return
        }
        guard !otherAppleDevices.contains(identifier) else {
            reportIOSFailure("This device is not supported by iPhone / iPad Bluetooth discovery.")
            return
        }
        iosConnectionFailure = nil
        iosConnectionPolicy.requestAuthorization(identifier)
        pendingIOSDeviceIDs = iosConnectionPolicy.pendingAuthorizationIDs
        connectIOSPeripheral(peripheral)
    }

    func cancelIOSConnections() {
        for identifier in iosConnectionPolicy.connectingIDs {
            iosConnectionPolicy.cancelConnection(identifier)
            clearIOSConnectionState(identifier)
            let peripheral = discoveredIOSPeripherals[identifier]
                ?? peripherals.compactMap { $0 }.first(where: { $0.identifier == identifier })
            if let peripheral = peripheral, peripheral.state != .disconnected {
                centralManager.cancelPeripheralConnection(peripheral)
            }
        }
        pendingIOSDeviceIDs = iosConnectionPolicy.pendingAuthorizationIDs
    }

    func forgetIOSDevice(_ identifier: UUID) {
        iosConnectionPolicy.forget(identifier)
        clearIOSConnectionState(identifier)
        pendingIOSDeviceIDs = iosConnectionPolicy.pendingAuthorizationIDs
        authorizedIOSDevices.removeValue(forKey: identifier.uuidString)
        saveAuthorizedIOSDevices()
        if let peripheral = discoveredIOSPeripherals[identifier]
            ?? peripherals.compactMap({ $0 }).first(where: { $0.identifier == identifier }), peripheral.state != .disconnected {
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    func isIOSDeviceAuthorized(_ identifier: UUID) -> Bool {
        iosConnectionPolicy.isAuthorized(identifier)
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        failIOSConnection(peripheral, message: error?.localizedDescription ?? "Bluetooth connection failed. Move the device closer and retry.".local)
        releasePeripheral(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let identifier = peripheral.identifier
        if error != nil || iosConnectionPolicy.connectingIDs.contains(identifier) {
            failIOSConnection(peripheral, message: error?.localizedDescription ?? "The device disconnected before its battery could be read.".local)
        } else {
            iosConnectionPolicy.markDisconnected(identifier)
        }
        clearIOSConnectionState(identifier)
        releasePeripheral(peripheral)
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        var get = false
        let now = Double(Date().timeIntervalSince1970)
        if let deviceName = peripheral.name{
            if AirBatteryModel.checkIfBlocked(name: deviceName) { return }
            if let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, data.count > 0 {
                if data[0] != 76 {
                    //Get regular non-Apple BLE device data
                    // Fixes issue #132: this used to attempt a full GATT connection to EVERY
                    // unrecognized non-Apple BLE peripheral in range, every ~29 second scan
                    // cycle, FOREVER - because a peripheral only ever gets cached into
                    // AirBatteryModel (making getByName() below return non-nil) once it's
                    // actually found to expose a battery level. Any nearby BLE device that
                    // doesn't report battery at all (a fitness tracker, smart bulb, beacon,
                    // anything) can never satisfy that, so it was connected to, probed, and
                    // disconnected again every single cycle with no memory of having already
                    // tried. Reported (and confirmed by the reporter disabling this exact
                    // toggle) to prevent the Mac from ever sleeping or turning off its display -
                    // macOS treats actively opening/holding Bluetooth connections as ongoing
                    // activity, and this was doing so almost continuously for every non-battery
                    // BLE device in range. Now remembers (for this launch) any peripheral
                    // that's already been connected to and confirmed NOT to expose a battery
                    // characteristic (see peripheral(_:didDiscoverCharacteristicsFor:) below,
                    // which populates knownNonBatteryPeripherals), and skips reconnecting to
                    // it - a real battery-reporting device is unaffected since it's never added
                    // to that set.
                    if readBLEDevice && !knownNonBatteryPeripherals.contains(peripheral.identifier.uuidString) {
                        if let device = AirBatteryModel.getByName(deviceName) {
                            if now - device.lastUpdate > Double(60 * updateInterval) { get = true } } else { get = true }
                    }
                } else {
                    if data.count > 2 {
                        //获取ios个人热点广播数据
                        if [16, 12].contains(data[2]) && !otherAppleDevices.contains(peripheral.identifier) && ideviceOverBLE {
                            updateIOSDevice(peripheral, name: deviceName, rssi: RSSI.intValue)
                            if iosConnectionPolicy.isAuthorized(peripheral.identifier) {
                                if let device = AirBatteryModel.getByID(peripheral.identifier.uuidString) {
                                    if now - device.lastUpdate > Double(60 * updateInterval) { connectIOSPeripheral(peripheral) }
                                } else {
                                    connectIOSPeripheral(peripheral)
                                }
                            }
                        }
                        //Get AirPods lid-closed status message
                        if data.count == 25 && data[2] == 18 && readBTDevice { getAirpods(peripheral: peripheral, data: data, messageType: "close") }
                        //Get AirPods lid-open status message
                        if data.count == 29 && data[2] == 7 && readBTDevice { getAirpods(peripheral: peripheral, data: data, messageType: "open") }
                    }
                }
            }
        }
        if get && peripheral.state == .disconnected {
            retainPeripheral(peripheral)
            centralManager.connect(peripheral, options: nil)
            // Safety net: if we never end up reading any characteristic on this peripheral
            // (e.g. it doesn't expose the services we're looking for, or a read never
            // completes/errors silently), make sure the GATT connection still gets torn
            // down instead of being held open forever. See disconnectWhenDone() below for
            // why this matters.
            let id = peripheral.identifier.uuidString
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self = self else { return }
                self.disconnectWhenDone(peripheral, force: true, id: id)
                // Part of the issue #132 fix: 8 seconds is ample time for service and
                // characteristic discovery to have completed. If nothing relevant ever showed
                // up for this peripheral in that window, remember it so it isn't
                // reconnected-to again every ~29 second scan cycle for the rest of this
                // launch - see the readBLEDevice check above.
                if !self.hasBatteryCharacteristic.contains(id) { self.knownNonBatteryPeripherals.insert(id) }
            }
        }
    }

    // Every ~29s (default interval) this app connects to any nearby BLE peripheral just
    // to read a couple of GATT characteristics for battery/model info, then used to leave
    // the connection open indefinitely (the disconnect call below was commented out).
    // Reported as issue #178: on macOS 26 this was causing real Bluetooth audio devices
    // (headphones, speakers) to stutter badly while AirBattery was running, and uninstalling
    // it fixed the stutter - consistent with AirBattery silently holding open extra GATT
    // connections to devices (including ones the user is actively streaming audio to over
    // classic Bluetooth) and never releasing them, competing for the shared radio/connection
    // slots. Disconnect as soon as we've read everything we came for.
    func disconnectWhenDone(_ peripheral: CBPeripheral, force: Bool = false, id: String) {
        if !force {
            let remaining = (pendingReads[id] ?? 1) - 1
            pendingReads[id] = remaining
            if remaining > 0 { return }
        }
        pendingReads.removeValue(forKey: id)
        if peripheral.state == .connected || peripheral.state == .connecting {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        if let index = self.peripherals.firstIndex(of: peripheral) { self.peripherals.remove(at: index) }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        //guard let name = peripheral.name else { return }
        //let blockedItems = (ud.object(forKey: "blockedDevices") as? [String]) ?? [String]()
        //if blockedItems.contains(name) && !whitelistMode { return }
        //if !blockedItems.contains(name) && whitelistMode { return }
        let isIOSConnection = isIOSConnection(peripheral.identifier)
        if isIOSConnection && error != nil { iosConnectionsWithErrors.insert(peripheral.identifier) }
        guard let services = peripheral.services else {
            if isIOSConnection { finishIOSConnectionIfReady(peripheral, force: true) }
            return
        }
        if isIOSConnection {
            iosServicesRemaining[peripheral.identifier] = services.count
            if services.isEmpty {
                iosConnectionsWithErrors.insert(peripheral.identifier)
                finishIOSConnectionIfReady(peripheral)
            }
        }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        //guard let name = peripheral.name else { return }
        //let blockedItems = (ud.object(forKey: "blockedDevices") as? [String]) ?? [String]()
        //if blockedItems.contains(name) && !whitelistMode { return }
        //if !blockedItems.contains(name) && whitelistMode { return }
        let identifier = peripheral.identifier
        let isIOSConnection = isIOSConnection(identifier)
        let targetService = service.uuid == CBUUID(string: "180F") || service.uuid == CBUUID(string: "180A")
        if isIOSConnection && targetService && error != nil { iosConnectionsWithErrors.insert(identifier) }
        guard let characteristics = service.characteristics else {
            if isIOSConnection {
                iosServicesRemaining[identifier, default: 1] -= 1
                finishIOSConnectionIfReady(peripheral)
            }
            return
        }
        var clear = true
        if targetService {
            for characteristic in characteristics {
                if characteristic.uuid == CBUUID(string: "2A19") || characteristic.uuid == CBUUID(string: "2A24") || characteristic.uuid == CBUUID(string: "2A29") {
                    clear = false
                    if isIOSConnection {
                        iosReadsRemaining[identifier, default: 0] += 1
                    } else {
                        let id = identifier.uuidString
                        hasBatteryCharacteristic.insert(id)
                        pendingReads[id] = (pendingReads[id] ?? 0) + 1
                    }
                    peripheral.readValue(for: characteristic)
                }
            }
        }
        if isIOSConnection {
            iosServicesRemaining[identifier, default: 1] -= 1
            finishIOSConnectionIfReady(peripheral)
        } else if clear && (pendingReads[identifier.uuidString] ?? 0) == 0 {
            // Nothing to read on this service and no reads pending from another service:
            // release the connection instead of holding it open.
            disconnectWhenDone(peripheral, force: true, id: identifier.uuidString)
        }

    }
    
    //Battery info
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        //guard let name = peripheral.name else { return }
        //let blockedItems = (ud.object(forKey: "blockedDevices") as? [String]) ?? [String]()
        //if blockedItems.contains(name) && !whitelistMode { return }
        //if !blockedItems.contains(name) && whitelistMode { return }
        
        let identifier = peripheral.identifier
        let isIOSConnection = isIOSConnection(identifier)
        if isIOSConnection && error != nil { iosConnectionsWithErrors.insert(identifier) }

        if error == nil && characteristic.uuid == CBUUID(string: "2A19"){
            if let data = characteristic.value, let deviceName = peripheral.name {
                let now = Date().timeIntervalSince1970
                guard !data.isEmpty else {
                    if isIOSConnection { iosConnectionsWithErrors.insert(identifier) }
                    completeIOSRead(peripheral)
                    return
                }
                let level = Int(data[0])
                guard level <= 100 else {
                    if isIOSConnection { iosConnectionsWithErrors.insert(identifier) }
                    completeIOSRead(peripheral)
                    return
                }
                if isIOSConnection { iosBatteryReadSucceeded.insert(identifier) }
                var charging = 0
                //if let lastLevel = bleDevicesLevel[deviceName], cStatusOfBLE {
                if let lastLevel = bleDevicesLevel[deviceName] {
                    if level > lastLevel { charging = 1 }
                    //if level < lastLevel { charging = 0 }
                }
                bleDevicesLevel[deviceName] = data[0]
                if var device = AirBatteryModel.getByName(deviceName) {
                    device.deviceID = peripheral.identifier.uuidString
                    device.batteryLevel = level
                    device.lastUpdate = now
                    if charging != -1 { device.isCharging = charging }
                    AirBatteryModel.updateDevice(device)
                } else {
                    let device = Device(deviceID: peripheral.identifier.uuidString, deviceType: getType(deviceName), deviceName: deviceName, batteryLevel: level, isCharging: charging, lastUpdate: now)
                    AirBatteryModel.updateDevice(device)
                }
            }
        }
        
        //设备型号
        if error == nil && characteristic.uuid == CBUUID(string: "2A24") {
            if isIOSConnection, let model = characteristic.value?.ascii(), model.contains("Watch") {
                otherAppleDevices.insert(identifier)
                failIOSConnection(peripheral, message: "Apple Watch is not supported by iPhone / iPad Bluetooth discovery.".local)
                nearbyIOSDevices.removeAll { $0.id == identifier }
                centralManager.cancelPeripheralConnection(peripheral)
                return
            }
            if let data = characteristic.value, let model = data.ascii(), let deviceName = peripheral.name, let vendor = bleDevicesVendor[deviceName] {
                if vendor == "Apple Inc." && model.contains("Watch") { otherAppleDevices.insert(identifier) }
                if var device = AirBatteryModel.getByName(deviceName), device.deviceModel != model{
                    // AirPods-family devices already get their friendly model name (e.g. "Airpods Pro 2")
                    // from the manufacturer-data broadcast in getAirpods(). The generic Device Information
                    // Service "Model Number" characteristic (2A24) returns Apple's internal hardware model
                    // string instead, which was overwriting the correct name here and breaking icon lookup
                    // in getDeviceIcon() (falls through to the "regular AirPods" default). Skip the overwrite
                    // for those device types so the icon stays correct.
                    if device.deviceType.hasPrefix("ap_") { return }
                    if vendor == "Apple Inc." {
                        device.deviceType = model.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "\\d", with: "", options: .regularExpression, range: nil)
                        device.deviceModel = model
                    } else {
                        device.deviceType = getType(deviceName)
                    }
                    device.lastUpdate = Date().timeIntervalSince1970
                    AirBatteryModel.updateDevice(device)
                }
            }
        }
        
        //厂商信息
        if error == nil && characteristic.uuid == CBUUID(string: "2A29") {
            if let deviceName = peripheral.name {
                //Apple = Apple Inc.
                if let data = characteristic.value, let vendor = data.ascii() { bleDevicesVendor[deviceName] = vendor }
            }
        }
        if isIOSConnection {
            completeIOSRead(peripheral)
        } else {
            disconnectWhenDone(peripheral, id: identifier.uuidString)
        }
    }

    private func updateIOSDevice(_ peripheral: CBPeripheral, name: String, rssi: Int) {
        let identifier = peripheral.identifier
        let now = Date()
        discoveredIOSPeripherals[identifier] = peripheral
        nearbyIOSDevices.removeAll { now.timeIntervalSince($0.lastSeen) > 120 }
        if let index = nearbyIOSDevices.firstIndex(where: { $0.id == identifier }) {
            nearbyIOSDevices[index].name = name
            nearbyIOSDevices[index].rssi = rssi
            nearbyIOSDevices[index].lastSeen = now
        } else {
            nearbyIOSDevices.append(IOSBLEDevice(id: identifier, name: name, rssi: rssi, lastSeen: now))
        }
        nearbyIOSDevices.sort { $0.rssi > $1.rssi }
    }

    private func connectIOSPeripheral(_ peripheral: CBPeripheral) {
        let identifier = peripheral.identifier
        guard peripheral.state == .disconnected else { return }
        guard iosConnectionPolicy.markConnectionStarted(identifier) else { return }
        pendingIOSDeviceIDs = iosConnectionPolicy.pendingAuthorizationIDs
        retainPeripheral(peripheral)
        let attemptToken = UUID()
        iosAttemptTokens[identifier] = attemptToken
        centralManager.connect(peripheral, options: nil)

        // CoreBluetooth does not guarantee a timely failure callback. Keep a
        // hung request from blocking the device forever while also preventing
        // immediate retry loops.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self, weak peripheral] in
            guard let self = self, let peripheral = peripheral else { return }
            guard self.iosAttemptTokens[identifier] == attemptToken else { return }
            guard self.iosConnectionPolicy.connectingIDs.contains(identifier) else { return }
            self.failIOSConnection(peripheral, message: "Connection timed out. Move the device closer, unlock it and open Personal Hotspot, then retry.".local)
            self.centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    private func finishIOSConnectionIfReady(_ peripheral: CBPeripheral, force: Bool = false) {
        let identifier = peripheral.identifier
        guard isIOSConnection(identifier) else { return }
        if !force {
            guard iosServicesRemaining[identifier, default: 0] <= 0,
                  iosReadsRemaining[identifier, default: 0] <= 0 else { return }
        }

        let failed = iosConnectionsWithErrors.contains(identifier) || !iosBatteryReadSucceeded.contains(identifier)
        if failed {
            if iosConnectionPolicy.isAuthorizationPending(identifier) {
                reportIOSFailure("Could not read the battery. The device may not support this feature or may have denied access.")
            }
            iosConnectionPolicy.markConnectionFailed(identifier)
        } else {
            let newlyAuthorized = iosConnectionPolicy.markConnectionSucceeded(identifier)
            if newlyAuthorized {
                authorizedIOSDevices[identifier.uuidString] = peripheral.name ?? "iPhone / iPad"
                saveAuthorizedIOSDevices()
            }
        }
        pendingIOSDeviceIDs = iosConnectionPolicy.pendingAuthorizationIDs
        clearIOSConnectionState(identifier)
        if peripheral.state != .disconnected {
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    private func completeIOSRead(_ peripheral: CBPeripheral) {
        let identifier = peripheral.identifier
        guard isIOSConnection(identifier), let remaining = iosReadsRemaining[identifier], remaining > 0 else { return }
        iosReadsRemaining[identifier] = remaining - 1
        finishIOSConnectionIfReady(peripheral)
    }

    private func reportIOSFailure(_ message: String) {
        iosConnectionFailure = IOSBLEFailure(message: message.local)
    }

    private func failIOSConnection(_ peripheral: CBPeripheral, message: String = "Bluetooth connection failed. Move the device closer and retry.".local) {
        let identifier = peripheral.identifier
        guard isIOSConnection(identifier) else { return }
        if iosConnectionPolicy.isAuthorizationPending(identifier) {
            reportIOSFailure(message)
        }
        iosConnectionPolicy.markConnectionFailed(identifier)
        pendingIOSDeviceIDs = iosConnectionPolicy.pendingAuthorizationIDs
        clearIOSConnectionState(identifier)
    }

    private func isIOSConnection(_ identifier: UUID) -> Bool {
        iosConnectionPolicy.isAuthorized(identifier)
            || iosConnectionPolicy.isAuthorizationPending(identifier)
            || iosConnectionPolicy.connectingIDs.contains(identifier)
    }

    private func clearIOSConnectionState(_ identifier: UUID) {
        iosAttemptTokens.removeValue(forKey: identifier)
        iosServicesRemaining.removeValue(forKey: identifier)
        iosReadsRemaining.removeValue(forKey: identifier)
        iosConnectionsWithErrors.remove(identifier)
        iosBatteryReadSucceeded.remove(identifier)
    }

    private func retainPeripheral(_ peripheral: CBPeripheral) {
        guard !peripherals.contains(where: { $0?.identifier == peripheral.identifier }) else { return }
        peripherals.append(peripheral)
    }

    private func releasePeripheral(_ peripheral: CBPeripheral) {
        peripherals.removeAll { $0?.identifier == peripheral.identifier }
    }

    private func saveAuthorizedIOSDevices() {
        UserDefaults.standard.set(authorizedIOSDevices, forKey: Self.authorizedIOSDevicesKey)
    }
    
    func getLevel(_ name: String, _ side: String) -> UInt8{
        //guard let result = process(path: "/usr/sbin/system_profiler", arguments: ["SPBluetoothDataType", "-json"]) else { return 255 }
        if let json = try? JSONSerialization.jsonObject(with: Data(SPBluetoothDataModel.shared.data.utf8), options: []) as? [String: Any],
        let SPBluetoothDataTypeRaw = json["SPBluetoothDataType"] as? [Any],
        let SPBluetoothDataType = SPBluetoothDataTypeRaw[0] as? [String: Any],
        let device_connected = SPBluetoothDataType["device_connected"] as? [Any] {
            for device in device_connected{
                let d = device as! [String: Any]
                if let n = d.keys.first,n == name,let info = d[n] as? [String: Any] {
                    if let level = info["device_batteryLevel"+side] as? String {
                        return UInt8(level.replacingOccurrences(of: "%", with: "")) ?? 255
                    }
                }
            }
        }
        return 255
    }
    
    func getType(_ name: String) -> String{
        //guard let result = process(path: "/usr/sbin/system_profiler", arguments: ["SPBluetoothDataType", "-json"]) else { return "general_bt" }
        if let json = try? JSONSerialization.jsonObject(with: Data(SPBluetoothDataModel.shared.data.utf8), options: []) as? [String: Any],
        let SPBluetoothDataTypeRaw = json["SPBluetoothDataType"] as? [Any],
        let SPBluetoothDataType = SPBluetoothDataTypeRaw[0] as? [String: Any],
        let device_connected = SPBluetoothDataType["device_connected"] as? [Any] {
            for device in device_connected{
                let d = device as! [String: Any]
                if let n = d.keys.first,n == name,let info = d[n] as? [String: Any] {
                    if let type = info["device_minorType"] as? String {
                        return type
                    }
                }
            }
        }
        return "general_bt"
    }
    
    func getAirpods(peripheral: CBPeripheral, data: Data, messageType: String) {
        guard let name = peripheral.name else { return }
        if AirBatteryModel.checkIfBlocked(name: name) { return }
        
        if var deviceName = peripheral.name{
            //NSLog("AirPods: \(messageType) message [\(data.hexEncodedString())]")
            let now = Date().timeIntervalSince1970
            let dataHex = data.hexEncodedString()
            let index = dataHex.index(dataHex.startIndex, offsetBy: 14)
            let flip = (strtoul(String(dataHex[index]), nil, 16) & 0x02) == 0
            let deviceID = peripheral.identifier.uuidString
            var model = (messageType == "open" ? getHeadphoneModel(String(format: "%02x%02x", data[6], data[5])) : "Airpods Pro 2")
            if let Case = AirBatteryModel.getByName(deviceName + " (Case)".local) { model = Case.deviceModel ?? model }
            // Fixes issue #172: on macOS 26, CoreBluetooth's peripheral.name for an AirPods/
            // Beats accessory's BLE broadcast can come back as something clearly wrong for
            // this device - reported as literally "iPhone" for AirPods 3, both the case and
            // the buds. deviceName here is only ever sourced from peripheral.name (a value we
            // don't control, coming straight from the OS/CoreBluetooth), while model just
            // above is decoded independently and reliably from the manufacturer-data bytes in
            // this same advertisement packet via the ID table in getHeadphoneModel(). When
            // deviceName clearly doesn't match what the packet itself says this device is
            // (an Apple phone name for hardware whose own advertisement decodes as
            // AirPods/Beats), prefer the decoded model name instead of trusting peripheral.name.
            // This won't recover a user's custom nickname for the accessory (that's not present
            // in this BLE broadcast at all), but "AirPods 3" is a large improvement over "iPhone".
            if model != "Headphones", deviceName.lowercased().contains("iphone") || deviceName.lowercased().contains("ipad") {
                deviceName = model
            }
            
            // Fixes issue #76 (AirPods showing an impossible >100% level, e.g. 125%): the
            // "clear the charging bit" formula below (caseLevel ^ 128) & caseLevel only
            // actually clears bit 7 when it was set in the first place. A raw byte in the
            // 101-127 range - which has bit 7 unset but is still above 100 - passes straight
            // through unchanged (caseCharging still gets set to 1 since the raw byte > 100,
            // but the level itself is never brought back into range). This can happen from a
            // stray/corrupted advertisement byte, similar in spirit to the out-of-range 108%
            // already fixed for issue #106. Clamping to a sane 0...100 range after the
            // existing decode is a cheap, universal safety net regardless of the exact byte
            // that produced the bad value.
            var caseLevel = data[messageType == "open" ? 16 : 12]
            var caseCharging = 0
            if caseLevel != 255 {
                caseCharging = caseLevel > 100 ? 1 : 0
                caseLevel = min((caseLevel ^ 128) & caseLevel, 100)
            }else{ caseLevel = getLevel(deviceName, "Case") }

            var leftLevel = data[messageType == "open" ? (flip ? 15 : 14) : 13]
            var leftCharging = 0
            if leftLevel != 255 {
                leftCharging = leftLevel > 100 ? 1 : 0
                leftLevel = min((leftLevel ^ 128) & leftLevel, 100)
            }else{ leftLevel = getLevel(deviceName, "Left") }

            var rightLevel = data[messageType == "open" ? (flip ? 14 : 15) : 14]
            var rightCharging = 0
            if rightLevel != 255 {
                rightCharging = rightLevel > 100 ? 1 : 0
                rightLevel = min((rightLevel ^ 128) & rightLevel, 100)
            }else{ rightLevel = getLevel(deviceName, "Right") }
            
            // Same reasoning as the deviceName "max" check in getDeviceIcon(): a newer over-ear
            // model (e.g. "AirPods Max 2") won't resolve to exactly "Airpods Max" here since its
            // BLE bytes aren't in the table above, so it would otherwise fall through to the
            // earbud-style path below and get incorrectly split into fake Case/Left/Right entries
            // instead of being treated as one single device.
            let isOverEar = ["Airpods Max", "Beats Solo Pro", "Beats Solo 3", "Beats Studio Pro"].contains(model) || deviceName.lowercased().contains("max")
            if !isOverEar {
                if caseLevel != 255 { AirBatteryModel.updateDevice(Device(deviceID: deviceID, deviceType: "ap_case", deviceName: deviceName + " (Case)".local, deviceModel: model, batteryLevel: Int(caseLevel), isCharging: caseCharging, lastUpdate: now)) }
                
                if !neverMergeTws && leftLevel != 255 && rightLevel != 255 && (abs(Int(leftLevel) - Int(rightLevel)) < twsMerge) && leftCharging == rightCharging {
                    AirBatteryModel.hideDevice(deviceName + " 🄻")
                    AirBatteryModel.hideDevice(deviceName + " 🅁")
                    AirBatteryModel.updateDevice(Device(deviceID: deviceID + "_All", deviceType: "ap_pod_all", deviceName: deviceName + " 🄻🅁", deviceModel: model, batteryLevel: Int(min(leftLevel, rightLevel)), isCharging: leftCharging, isHidden: false, parentName: deviceName + " (Case)".local, lastUpdate: now))
                } else {
                    AirBatteryModel.hideDevice(deviceName + " 🄻🅁")
                    if leftLevel != 255 { AirBatteryModel.updateDevice(Device(deviceID: deviceID + "_Left", deviceType: "ap_pod_left", deviceName: deviceName + " 🄻", deviceModel: model, batteryLevel: Int(leftLevel), isCharging: leftCharging, isHidden: false, parentName: deviceName + " (Case)".local ,lastUpdate: now)) }
                    if rightLevel != 255 { AirBatteryModel.updateDevice(Device(deviceID: deviceID + "_Right", deviceType: "ap_pod_right", deviceName: deviceName + " 🅁", deviceModel: model, batteryLevel: Int(rightLevel), isCharging: rightCharging, isHidden: false, parentName: deviceName + " (Case)".local, lastUpdate: now)) }
                }
            } else {
                if model == "Beats Studio Pro" {
                    AirBatteryModel.updateDevice(Device(deviceID: deviceID, deviceType: "ap_case", deviceName: deviceName, deviceModel: model, batteryLevel: Int(rightLevel), isCharging: rightCharging, lastUpdate: now))
                } else {
                    leftLevel = leftLevel != 255 ? leftLevel : 0
                    rightLevel = rightLevel != 255 ? rightLevel : 0
                    AirBatteryModel.updateDevice(Device(deviceID: deviceID, deviceType: "ap_case", deviceName: deviceName, deviceModel: model, batteryLevel: Int(max(rightLevel, leftLevel)), isCharging: rightCharging + leftCharging > 0 ? 1 : 0, lastUpdate: now))
                }
            }
            //print("Type: \(messageType), C:\(caseLevel), L:\(leftLevel), R:\(rightLevel), Flip:\(messageType == "open" ? "\(flip)" : "none")")
            //print("Raw Data: \(data.hexEncodedString())")
        }
    }
    
    func getPaired() -> [String]{
        var paired:[String] = []
        //guard let result = process(path: "/usr/sbin/system_profiler", arguments: ["SPBluetoothDataType", "-json"]) else { return paired }
        if let json = try? JSONSerialization.jsonObject(with: Data(SPBluetoothDataModel.shared.data.utf8), options: []) as? [String: Any],
        let SPBluetoothDataTypeRaw = json["SPBluetoothDataType"] as? [Any],
        let SPBluetoothDataType = SPBluetoothDataTypeRaw[0] as? [String: Any]{
            if let device_connected = SPBluetoothDataType["device_connected"] as? [Any]{
                for device in device_connected{
                    let d = device as! [String: Any]
                    if let key = d.keys.first { paired.append(key) }
                }
            }
            if let device_connected = SPBluetoothDataType["device_not_connected"] as? [Any]{
                for device in device_connected{
                    let d = device as! [String: Any]
                    if let key = d.keys.first { paired.append(key) }
                }
            }
        }
        return paired
    }
}
