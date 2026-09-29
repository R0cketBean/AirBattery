//
//  AirBatteryModel.swift
//  AirBattery
//
//  Created by apple on 2024/2/9.
//

import Foundation

struct btdDevice: Codable, Equatable {
    let time: Date
    let vid: String
    let pid: String
    let type: String
    let mac: String
    let name: String
    let level: Int
}

struct Device: Hashable, Codable {
    var hasBattery: Bool = true
    var deviceID: String
    var deviceType: String
    var deviceName: String
    var deviceModel: String?
    var batteryLevel: Int
    var isCharging: Int
    var isCharged: Bool = false
    var isPaused: Bool = false
    var acPowered: Bool = false
    var isHidden: Bool = false
    var lowPower: Bool = false
    var parentName: String = ""
    var lastUpdate: Double
    var realUpdate: Double = 0.0
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(hasBattery)
        hasher.combine(deviceID)
        hasher.combine(deviceType)
        hasher.combine(deviceName)
        hasher.combine(deviceModel)
        hasher.combine(batteryLevel)
        hasher.combine(isCharging)
        hasher.combine(isCharged)
        hasher.combine(isPaused)
        hasher.combine(acPowered)
        hasher.combine(isHidden)
        hasher.combine(lowPower)
        hasher.combine(lastUpdate)
        hasher.combine(realUpdate)
        hasher.combine(parentName)
    }
}

class AirBatteryModel {
    // Devices is updated from several threads (Bluetooth callbacks, background scans),
    // so every access goes through a real lock. Unsynchronized access corrupted memory.
    private static let devicesLock = NSLock()
    private static var _devices: [Device] = []
    static var Devices: [Device] {
        get { devicesLock.lock(); defer { devicesLock.unlock() }; return _devices }
        set { devicesLock.lock(); defer { devicesLock.unlock() }; _devices = newValue }
    }
    // Device IDs that already got a low-battery notification, so each drop below the
    // threshold notifies once instead of on every scan. Guarded by its own lock because
    // updateDevice() is called from several threads.
    private static let lowBatteryLock = NSLock()
    private static var lowBatteryNotified: Set<String> = []
    static let machineType = ud.string(forKey: "machineType") ?? "Mac"
    static let key = "com.lihaoyun6.AirBattery.widget"

    static func updateDevice(_ device: Device) {
        //let blockedItems = (ud.object(forKey: "blockedDevices") as? [String]) ?? [String]()
        //if blockedItems.contains(device.deviceName) { return }
        devicesLock.lock()
        //self.Devices.removeAll(where: {blockedItems.contains($0.deviceName)})
        if let index = _devices.firstIndex(where: { $0.deviceName == device.deviceName }) {
            _devices[index] = device
        } else {
            _devices.append(device)
        }
        devicesLock.unlock()
        checkLowBattery(device)
    }

    // Low-battery notification (off by default, see GeneralView in SettingsView.swift).
    // Devices can be muted individually via the "mutedDevices" list (ContentView.swift).
    static func checkLowBattery(_ device: Device) {
        guard device.hasBattery, device.batteryLevel > 0 else { return }
        guard (ud.object(forKey: "lowBatteryAlert") as? Bool) ?? false else { return }
        let mutedDevices = (ud.object(forKey: "mutedDevices") as? [String]) ?? []
        if mutedDevices.contains(device.deviceName) { return }
        let threshold = (ud.object(forKey: "lowBatteryThreshold") as? Int) ?? 20
        let isCharging = device.isCharging != 0 || device.acPowered
        lowBatteryLock.lock()
        if device.batteryLevel <= threshold && !isCharging && !device.isPaused {
            let isNew = lowBatteryNotified.insert(device.deviceID).inserted
            lowBatteryLock.unlock()
            if isNew {
                createNotification(
                    title: "Low Battery".local,
                    message: String(format: "%@ is at %d%%".local, device.deviceName, device.batteryLevel)
                )
            }
        } else {
            // Reset once clearly recovered; the +5 buffer avoids re-notifying while a
            // device hovers right at the threshold.
            if device.batteryLevel > threshold + 5 || isCharging { lowBatteryNotified.remove(device.deviceID) }
            lowBatteryLock.unlock()
        }
    }

    static func hideDevice(_ name: String) {
        devicesLock.lock(); defer { devicesLock.unlock() }
        for index in _devices.indices {
            if _devices[index].deviceName == name {
                _devices[index].isHidden = true
            }
        }
    }

    static func unhideDevice(_ name: String) {
        devicesLock.lock(); defer { devicesLock.unlock() }
        for index in _devices.indices {
            if _devices[index].deviceName == name {
                _devices[index].isHidden = false
            }
        }
    }
    
    static func getBlackList() -> [Device] {
        let blackList = (ud.object(forKey: "blackList") ?? []) as! [String]
        let devices = getAll(noFilter: true)
        return devices.filter({ blackList.contains($0.deviceName) })
    }
    
    static func getAll(reverse: Bool = false, noFilter: Bool = false) -> [Device] {
        let thisMac = ud.string(forKey: "deviceName")
        let disappearTime = (ud.object(forKey: "disappearTime") ?? 20) as! Int
        let blackList = (ud.object(forKey: "blackList") ?? []) as! [String]
        let now = Double(Date().timeIntervalSince1970)
        // -1 is the "Never" sentinel from the Remove Offline Device picker in Settings -
        // skip the time filter entirely rather than multiplying it into the comparison
        // (disappearTime * 60 would also risk overflow if a huge sentinel were used instead).
        var list = (reverse ? Array(Devices.reversed()) : Devices).filter { disappearTime == -1 || (now - $0.lastUpdate < Double(disappearTime * 60)) }
        // Fixes issues #127/#109 (defense-in-depth): two independent scan paths often both
        // report the same physical non-Apple Bluetooth device under the identical name (e.g.
        // MagicBattery.swift's getOtherBTBattery() via system_profiler AND getIOBTBattery() via
        // IOBluetoothDevice directly, for the same mouse/keyboard). updateDevice() already
        // dedupes by exact deviceName on every write, but before this build's #124/#128/#111
        // fix (a non-atomic Bool used as a hand-rolled lock) two concurrent updateDevice() calls
        // could each miss the other's not-yet-committed insert and both append, leaving two
        // same-named entries sitting in Devices - which also explains why hiding one hid both
        // (the blackList/hidden filters above match by name across the whole list, not by a
        // specific entry). That race is fixed now, but this keeps only the most-recently-updated
        // entry per deviceName here too, as a cheap guardrail against this exact symptom
        // recurring from any other source.
        var latestByName: [String: Device] = [:]
        for d in list {
            if let existing = latestByName[d.deviceName], existing.lastUpdate > d.lastUpdate { continue }
            latestByName[d.deviceName] = d
        }
        var seenNames = Set<String>()
        list = list.compactMap { d -> Device? in
            guard !seenNames.contains(d.deviceName) else { return nil }
            seenNames.insert(d.deviceName)
            return latestByName[d.deviceName]
        }
        if !noFilter { list = list.filter { !blackList.contains($0.deviceName) && !$0.isHidden } }
        var newList: [Device] = list.filter({ $0.parentName == thisMac })
        for d in list {
            if d.parentName == "" && d.parentName != thisMac {
                newList.append(d)
                for sd in list.filter({ $0.parentName == d.deviceName }) {
                    newList.append(sd)
                }
            }
        }
        for dd in list.filter({ !newList.contains($0) }) { newList.append(dd) }
        // Fixes issue #56 (feature request): a user-configurable sort order for the device
        // list, applied as a final pass over the already-grouped list above. Groups newList
        // into (top-level device, [its own sub-devices]) chunks first, then sorts only the
        // chunks relative to each other - so a device's sub-devices (e.g. an AirPods Case,
        // Left, and Right) always stay grouped together right after it no matter which sort
        // order is chosen, instead of getting scattered by an alphabetical/level sort.
        let sortOrder = ud.string(forKey: "deviceSortOrder") ?? "default"
        if sortOrder != "default" {
            let topLevelNames = Set(newList.map { $0.deviceName })
            var groups: [[Device]] = []
            // Fixes a reported bug: "Battery Level (Low to High)" left some devices stuck in
            // the wrong place (e.g. an Apple Watch stuck right after its paired iPhone even
            // though it had by far the lowest battery), while "High to Low" looked fine. Root
            // cause: this grouping check only looked at parentName matching another device's
            // deviceName, but parentName is reused for two unrelated relationships - true
            // physically-bundled accessory parts (an AirPods case's Left/Right buds, whose
            // deviceType is always "ap_pod_*") AND devices that just happen to be *reported
            // via* another device without being physically part of it (an Apple Watch's
            // parentName is set to its paired iPhone's name in IDeviceBattery.swift, same for
            // an Apple Pencil and its iPad). That second case was wrongly being pinned
            // immediately after its "parent" and sorted using the parent's battery level
            // instead of its own - which happened to look correct for descending order (when
            // the parent had a high level) but visibly broke ascending order (a low-level
            // child never floated to the front). Restricting this merge to genuine ap_pod_*
            // sub-parts lets every other device sort independently by its own battery level,
            // while AirPods case/earbuds grouping keeps working exactly as before.
            for d in newList {
                if d.deviceType.hasPrefix("ap_pod"), topLevelNames.contains(d.parentName), !groups.isEmpty {
                    groups[groups.count - 1].append(d)
                } else {
                    groups.append([d])
                }
            }
            switch sortOrder {
            case "name":
                groups.sort { ($0.first?.deviceName ?? "").localizedCaseInsensitiveCompare($1.first?.deviceName ?? "") == .orderedAscending }
            case "level_asc":
                groups.sort { ($0.first?.batteryLevel ?? 0) < ($1.first?.batteryLevel ?? 0) }
            case "level_desc":
                groups.sort { ($0.first?.batteryLevel ?? 0) > ($1.first?.batteryLevel ?? 0) }
            default: break
            }
            newList = groups.flatMap { $0 }
        }
        return newList.filter({ !checkIfBlocked(name: $0.deviceName) })
    }
    
    static func getByName(_ name: String) -> Device? {
        for d in getAll(noFilter: true) { if d.deviceName == name { return d } }
        return nil
    }
    
    static func getByID(_ id: String) -> Device? {
        for d in getAll(noFilter: true) { if d.deviceID == id { return d } }
        return nil
    }
    
    static func singleDeviceName() -> String {
        var url: URL
        let bundleIdentifier = Bundle.main.bundleIdentifier
        if bundleIdentifier == key {
            url = fd.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("singleDeviceName")
            let devicename = try? String(contentsOf: url, encoding: .utf8)
            return devicename ?? ""
        } else {
            url = fd.urls(for: .libraryDirectory, in: .userDomainMask).first!.appendingPathComponent("Containers/\(key)/Data/Documents/singleDeviceName")
            try? ud.string(forKey: "deviceOnWidget")?.write(to: url, atomically: true, encoding: .utf8)
        }
        return ""
    }
    
    // Fixes issue #119 (feature request): a plain white widget background option. The widget
    // extension is sandboxed into its own container (widget.entitlements has app-sandbox on)
    // with no App Group configured, while the main app isn't sandboxed at all
    // (AirBattery.entitlements is empty) - so UserDefaults.standard in the two processes are
    // two entirely separate stores, and a simple @AppStorage toggle in the main app can't be
    // read by the widget directly. Reuses the exact same cross-container trick already used
    // for singleDeviceName/data.json just above: the unsandboxed main app writes a tiny text
    // file straight into the widget's own container, and the sandboxed widget reads that same
    // file from its own Documents directory.
    static func getWidgetBackgroundPrefURL() -> URL {
        let bundleIdentifier = Bundle.main.bundleIdentifier
        if bundleIdentifier == key {
            return fd.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("whiteWidgetBackground")
        } else {
            return fd.urls(for: .libraryDirectory, in: .userDomainMask).first!.appendingPathComponent("Containers/\(key)/Data/Documents/whiteWidgetBackground")
        }
    }

    static func setWhiteWidgetBackground(_ enabled: Bool) {
        try? (enabled ? "1" : "0").write(to: getWidgetBackgroundPrefURL(), atomically: true, encoding: .utf8)
    }

    static func getWhiteWidgetBackground() -> Bool {
        return (try? String(contentsOf: getWidgetBackgroundPrefURL(), encoding: .utf8)) == "1"
    }

    static func getJsonURL() -> URL {
        var url: URL
        let bundleIdentifier = Bundle.main.bundleIdentifier
        if bundleIdentifier == key {
            url = fd.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("data.json")
        } else {
            url = fd.urls(for: .libraryDirectory, in: .userDomainMask).first!.appendingPathComponent("Containers/\(key)/Data/Documents/data.json")
        }
        return url
    }
    
    static func writeData(){
        //let showMac = ud.object(forKey: "showMacOnWidget") as? Bool ?? true
        let revList = ud.object(forKey: "revListOnWidget") as? Bool ?? false
        
        var devices = getAll(reverse: revList)
        let ibStatus = InternalBattery.status
        if ibStatus.hasBattery { devices.insert(ib2ab(ibStatus), at: 0) }
        do {
            let jsonData = try JSONEncoder().encode(devices)
            try jsonData.write(to: getJsonURL())
        } catch {
            print("Write JSON error：\(error)")
        }
    }
    
    static func readData(url: URL = getJsonURL()) -> [Device]{
        do {
            let jsonData = try Data(contentsOf: url)
            let list = try JSONDecoder().decode([Device].self, from: jsonData)
            return list
        } catch {
            print("Read JSON error：\(error)")
        }
        return []
    }
    
    static func ncGetAll(url: URL, fromWidget: Bool = false) -> [Device] {
        let disappearTime = (ud.object(forKey: "disappearTime") ?? 20) as! Int
        let devices = readData(url: url)
        let now = Double(Date().timeIntervalSince1970)
        var localDevices = getAll().map({ $0.deviceName })
        if fromWidget { localDevices = readData().map({ $0.deviceName }) }
        var list = devices.filter{disappearTime == -1 || (now - $0.lastUpdate < Double(disappearTime * 60))}.filter({!localDevices.contains($0.deviceName)})
        if let first = devices.first { if !list.contains(first) && list.count != 0 { list.insert(first, at: 0) }}
        if let first = list.first { if list.count == 1 && !first.hasBattery { return [] }}
        return list
    }
    
    // Fixes issue #149: a whitelist entry like "BlueSkyXN AirPods Pro 2" (the plain Bluetooth
    // broadcast name) failed to match the earbud/case entries AirBattery itself generates for
    // AirPods-family devices, which all carry an appended suffix - " (Case)", " 🄻🅁", " 🄻",
    // or " 🅁" (see getAirpods() in BLEBattery.swift and its MagicBattery.swift counterpart).
    // checkIfBlocked() is called twice: once early with the plain broadcast name (which matched
    // the whitelist entry fine), and again later in getAll() against each split sub-device's
    // already-suffixed deviceName (which never matched a plain whitelist entry). Users had to
    // work around this by manually adding every suffixed variant to the whitelist too. Now
    // strips a known AirPods suffix before comparing, in addition to trying the exact name
    // first (so anyone who already added the suffixed variants as a workaround keeps working).
    static func baseDeviceName(_ name: String) -> String {
        let suffixes = [" (Case)".local, " 🄻🅁", " 🄻", " 🅁"]
        for suffix in suffixes {
            if name.hasSuffix(suffix) { return String(name.dropLast(suffix.count)) }
        }
        return name
    }

    static func checkIfBlocked(name: String) -> Bool {
        let whitelistMode = ud.bool(forKey: "whitelistMode")
        let blockedItems = (ud.object(forKey: "blockedDevices") as? [String]) ?? [String]()
        let isListed = blockedItems.contains(name) || blockedItems.contains(baseDeviceName(name))
        if (isListed && !whitelistMode) || (!isListed && whitelistMode) {
            return true
        }
        return false
    }
}
