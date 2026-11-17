// wifiinfo — tiny CoreWLAN helper for `net`, built into net-doctor.app.
//   wifiinfo info [--out FILE]   key=value lines about the current Wi-Fi link
//   wifiinfo scan [--out FILE]   one line per nearby network: channel width band rssi bssid ssid
//   wifiinfo auth [--out FILE]   request Location Services (needed for network names)
//   wifiinfo bt   [--out FILE]   nearby Bluetooth LE devices: rssi vendor kind name id
//
// macOS only reveals SSIDs/BSSIDs to a process that (a) is a signed app bundle with Location
// Services granted and (b) was launched as a real app session, not spawned by a shell. `net`
// therefore runs this through `open -W net-doctor.app --args <cmd> --out FILE` and reads
// FILE; run directly from a shell it still works, just with names hidden.

import CoreBluetooth
import CoreLocation
import CoreWLAN
import Foundation

// ---------- output: to --out FILE when given, else stdout ----------

let args = CommandLine.arguments
let cmd = args.count > 1 ? args[1] : "info"
var outPath: String? = nil
if let i = args.firstIndex(of: "--out"), i + 1 < args.count { outPath = args[i + 1] }
var buffer = ""

func emit(_ s: String) { buffer += s + "\n" }

func finish(_ code: Int32) -> Never {
    if let p = outPath {
        try? buffer.write(toFile: p, atomically: true, encoding: .utf8)
    } else {
        FileHandle.standardOutput.write(buffer.data(using: .utf8)!)
    }
    exit(code)
}

func note(_ s: String) {
    // progress for a human watching a terminal; never part of the result
    if outPath == nil { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
}

// ---------- CoreWLAN helpers ----------

func widthMHz(_ w: CWChannelWidth) -> Int {
    switch w {
    case .width20MHz: return 20
    case .width40MHz: return 40
    case .width80MHz: return 80
    case .width160MHz: return 160
    default: return 0
    }
}

func bandName(_ b: CWChannelBand) -> String {
    switch b {
    case .band2GHz: return "2.4"
    case .band5GHz: return "5"
    case .band6GHz: return "6"
    default: return "?"
    }
}

func phyName(_ p: CWPHYMode) -> String {
    switch p {
    case .mode11a: return "802.11a"
    case .mode11b: return "802.11b"
    case .mode11g: return "802.11g"
    case .mode11n: return "802.11n"
    case .mode11ac: return "802.11ac"
    case .mode11ax: return "802.11ax"
    default: return "none"
    }
}

func securityName(_ s: CWSecurity) -> String {
    switch s {
    case .none: return "open"
    case .WEP: return "WEP"
    case .wpaPersonal, .wpaPersonalMixed: return "WPA"
    case .wpa2Personal, .personal: return "WPA2"
    case .wpa3Personal: return "WPA3"
    case .wpa3Transition: return "WPA2/WPA3"
    case .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise, .enterprise, .wpa3Enterprise: return "Enterprise"
    case .OWE, .oweTransition: return "OWE"
    default: return "unknown"
    }
}

// ---------- location session ----------

final class LocationDelegate: NSObject, CLLocationManagerDelegate {
    var sawPrompt = false
    var gotFix = false
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if m.authorizationStatus == .notDetermined && !sawPrompt && cmd == "auth" {
            sawPrompt = true
            note("waiting for the Location Services dialog…")
        }
    }
    func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) { gotFix = true }
    func locationManager(_ m: CLLocationManager, didFailWithError e: Error) {}
}
let locationDelegate = LocationDelegate()
let location = CLLocationManager()
location.delegate = locationDelegate

/// Open a location session and wait for authorization to settle (and, when authorized,
/// for a first fix) so CoreWLAN treats this process as actively using location.
func startLocation(waitUpTo seconds: TimeInterval) -> CLAuthorizationStatus {
    location.requestWhenInUseAuthorization()
    location.startUpdatingLocation()   // the dialog often appears only on a real request
    let deadline = Date(timeIntervalSinceNow: seconds)
    while Date() < deadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        if location.authorizationStatus != .notDetermined { break }
    }
    if location.authorizationStatus == .authorizedAlways || location.authorizationStatus == .authorized {
        let fixDeadline = Date(timeIntervalSinceNow: 3)
        while !locationDelegate.gotFix && Date() < fixDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        }
    }
    return location.authorizationStatus
}

// ---------- commands ----------

guard let iface = CWWiFiClient.shared().interface() else {
    emit("error=no Wi-Fi interface")
    finish(1)
}

switch cmd {
case "info":
    _ = startLocation(waitUpTo: 2)
    emit("iface=\(iface.interfaceName ?? "")")
    emit("power=\(iface.powerOn() ? 1 : 0)")
    emit("ssid=\(iface.ssid() ?? "")")
    emit("bssid=\(iface.bssid() ?? "")")
    if let ch = iface.wlanChannel() {
        emit("channel=\(ch.channelNumber)")
        emit("width=\(widthMHz(ch.channelWidth))")
        emit("band=\(bandName(ch.channelBand))")
    } else {
        emit("channel=0")
        emit("width=0")
        emit("band=")
    }
    emit("rssi=\(iface.rssiValue())")
    emit("noise=\(iface.noiseMeasurement())")
    emit("txrate=\(Int(iface.transmitRate()))")
    emit("phy=\(phyName(iface.activePHYMode()))")
    emit("security=\(securityName(iface.security()))")
    finish(0)

case "scan":
    _ = startLocation(waitUpTo: 2)
    // Two passes catch networks a single scan misses. Keyed by BSSID when visible,
    // otherwise by channel+rssi so the same hidden network does not show twice.
    var seen: [String: CWNetwork] = [:]
    for _ in 0..<2 {
        guard let nets = try? iface.scanForNetworks(withSSID: nil) else { continue }
        for n in nets {
            let ch = n.wlanChannel?.channelNumber ?? 0
            let key = n.bssid ?? "\(ch)/\(n.rssiValue)/\(n.ssid ?? "")"
            seen[key] = n
        }
    }
    let sorted = seen.values.sorted { a, b in
        let ca = a.wlanChannel?.channelNumber ?? 0, cb = b.wlanChannel?.channelNumber ?? 0
        return ca != cb ? ca < cb : a.rssiValue > b.rssiValue
    }
    for n in sorted {
        let ch = n.wlanChannel
        emit("\(ch?.channelNumber ?? 0)\t\(widthMHz(ch?.channelWidth ?? .widthUnknown))\t\(bandName(ch?.channelBand ?? .bandUnknown))\t\(n.rssiValue)\t\(n.bssid ?? "")\t\(n.ssid ?? "")")
    }
    finish(0)

case "auth":
    if !CLLocationManager.locationServicesEnabled() {
        emit("status=services-off")
        finish(1)
    }
    switch startLocation(waitUpTo: 120) {
    case .authorizedAlways, .authorized: emit("status=granted")
    case .denied: emit("status=denied")
    case .restricted: emit("status=restricted")
    case .notDetermined: emit("status=timeout"); finish(1)
    @unknown default: emit("status=unknown")
    }
    finish(0)

case "bt":
    // Listen to BLE advertisements for a few seconds. Addresses are randomized by most
    // devices, so the id is only stable within one scan.
    final class BT: NSObject, CBCentralManagerDelegate {
        struct Seen { var name: String?; var rssi: Int; var mfg: Data?; var services: [CBUUID]; var hits: Int; var raw: [String: Any] = [:] }
        var found: [UUID: Seen] = [:]
        var unauthorized = false, off = false, unsupported = false
        func centralManagerDidUpdateState(_ c: CBCentralManager) {
            switch c.state {
            case .poweredOn:
                c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            case .unauthorized: unauthorized = true
            case .poweredOff: off = true
            case .unsupported: unsupported = true
            default: break
            }
        }
        func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
            var e = found[p.identifier] ?? Seen(name: nil, rssi: -200, mfg: nil, services: [], hits: 0)
            if let n = ad[CBAdvertisementDataLocalNameKey] as? String, !n.isEmpty { e.name = n } else if e.name == nil { e.name = p.name }
            if rssi.intValue < 0 { e.rssi = max(e.rssi, rssi.intValue) }
            if let m = ad[CBAdvertisementDataManufacturerDataKey] as? Data, m.count >= 2 { e.mfg = m }
            if let s = ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] { e.services = s }
            e.hits += 1
            for (k, v) in ad { e.raw[k] = v }
            found[p.identifier] = e
        }
    }
    let vendors: [UInt16: String] = [
        0x004C: "Apple", 0x0006: "Microsoft", 0x0075: "Samsung", 0x00E0: "Google", 0x0087: "Garmin",
        0x038F: "Xiaomi", 0x0157: "Amazfit", 0x0171: "Amazon", 0x012D: "Sony", 0x0117: "Bose",
        0x00C4: "LG", 0x01DA: "Logitech", 0x0002: "Intel", 0x0059: "Nordic", 0x0046: "MediaTek",
        0x01D7: "Qualcomm", 0x0310: "Fitbit", 0x0D0D: "Oura", 0x0822: "Tile", 0x05A7: "Sonos", 0x07D0: "Tuya (smart home)",
    ]
    let appleKinds: [UInt8: String] = [
        0x02: "iBeacon", 0x05: "AirDrop", 0x07: "AirPods/Beats", 0x09: "AirPlay target", 0x0a: "AirPlay source",
        0x0c: "Handoff", 0x0e: "Personal Hotspot", 0x0f: "Nearby action", 0x10: "iPhone/iPad/Mac/Watch",
        0x12: "Find My (AirTag or device)", 0x13: "Find My",
    ]
    let serviceKinds: [String: String] = [
        "FE2C": "Google Fast Pair", "FEED": "Tile tracker", "FD6F": "Exposure notification", "FEAA": "Eddystone beacon",
        "180D": "Heart-rate sensor", "1812": "Keyboard/mouse", "FD5A": "Samsung SmartTag", "FEF3": "Google",
        "FE9F": "Google", "FDF0": "Samsung Galaxy Buds", "FE07": "Sonos", "FEF5": "Dialog Semi", "FE0F": "Philips Hue",
    ]
    let d = BT()
    let central = CBCentralManager(delegate: d, queue: nil)
    _ = central
    let deadline = Date(timeIntervalSinceNow: 6)
    while Date() < deadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        if d.unauthorized || d.off || d.unsupported { break }
    }
    if d.unauthorized { emit("error=bluetooth-unauthorized"); finish(1) }
    if d.off { emit("error=bluetooth-off"); finish(1) }
    if d.unsupported { emit("error=bluetooth-unsupported"); finish(1) }
    if args.count > 2, args[2] != "--out" {
        // detail mode: wifiinfo bt <name-or-id-fragment> → every advertised field
        let want = args[2].lowercased()
        for (id, e) in d.found where (e.name ?? "").lowercased().contains(want) || id.uuidString.lowercased().hasPrefix(want) {
            emit("device \(id.uuidString.prefix(8))  rssi \(e.rssi)  heard \(e.hits)x  name \(e.name ?? "-")")
            for (k, v) in e.raw.sorted(by: { $0.key < $1.key }) {
                let key = k.replacingOccurrences(of: "kCBAdvData", with: "")
                if let dta = v as? Data { emit("  \(key): \(dta.map { String(format: "%02x", $0) }.joined(separator: " "))") }
                else if let sd = v as? [CBUUID: Data] { for (u, dta) in sd { emit("  \(key) \(u.uuidString): \(dta.map { String(format: "%02x", $0) }.joined(separator: " "))") } }
                else { emit("  \(key): \(v)") }
            }
        }
        finish(0)
    }
    for (id, e) in d.found.sorted(by: { $0.value.rssi > $1.value.rssi }) {
        var vendor = "", kind = ""
        if let m = e.mfg {
            let company = UInt16(m[m.startIndex]) | (UInt16(m[m.startIndex + 1]) << 8)
            vendor = vendors[company] ?? String(format: "vendor 0x%04X", company)
            if company == 0x004C, m.count >= 3 { kind = appleKinds[m[m.startIndex + 2]] ?? "Apple device" }
        }
        if kind.isEmpty {
            for s in e.services { if let k = serviceKinds[s.uuidString] { kind = k; break } }
        }
        if vendor.isEmpty, !e.services.isEmpty, kind.isEmpty { kind = "services " + e.services.map { $0.uuidString }.prefix(2).joined(separator: ",") }
        // unit separator rather than tab: zsh collapses empty tab fields
        let name = (e.name ?? "").trimmingCharacters(in: .whitespaces)
        emit([String(e.rssi), vendor, kind, name, String(id.uuidString.prefix(8)), String(e.hits)].joined(separator: "\u{1F}"))
    }
    finish(0)

case "btprobe":
    // Connect to one BLE device, read the public Device Information / Generic Access /
    // Battery services, list every other service and characteristic without reading
    // (reads there can trigger a pairing dialog), then disconnect.
    guard args.count > 2, args[2] != "--out" else { emit("error=usage: btprobe <name-or-id-fragment>"); finish(2) }
    let want = args[2].lowercased()
    let svcNames: [String: String] = [
        "1800": "Generic Access", "1801": "Generic Attribute", "180A": "Device Information", "180F": "Battery",
        "180D": "Heart Rate", "1812": "Human Interface Device", "1805": "Current Time", "1802": "Immediate Alert",
        "1803": "Link Loss", "1804": "Tx Power", "FE59": "Nordic DFU", "FFE0": "vendor UART (HM-10 style)",
        "FFF0": "vendor (ISSC style)", "6E400001-B5A3-F393-E0A9-E50E24DCCA9E": "Nordic UART",
        "FE2C": "Google Fast Pair", "FEED": "Tile", "FE0F": "Philips Hue", "D0611E78-BBB4-4591-A5F8-487910AE4366": "Apple Continuity",
        "9FA480E0-4967-4542-9390-D343DC5D04AE": "Apple Nearby", "7905F431-B5CE-4E99-A40F-4B1E122D00D0": "Apple Notification Center",
        "89D3502B-0F36-433A-8EF4-C502AD55F8DC": "Apple Media",
    ]
    let chrNames: [String: String] = [
        "2A00": "Device Name", "2A01": "Appearance", "2A04": "Connection Parameters", "2A05": "Service Changed",
        "2A19": "Battery Level", "2A23": "System ID", "2A24": "Model Number", "2A25": "Serial Number",
        "2A26": "Firmware Revision", "2A27": "Hardware Revision", "2A28": "Software Revision", "2A29": "Manufacturer Name",
        "2A2A": "Regulatory Certification", "2A50": "PnP ID", "2AA6": "Central Address Resolution",
    ]
    let readable: Set<String> = ["1800", "180A", "180F"]
    final class Probe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
        let want: String; var central: CBCentralManager!; var target: CBPeripheral?
        var done = false, pendingServices = 0, pendingReads = 0
        let svcNames: [String: String], chrNames: [String: String], readable: Set<String>
        init(want: String, svcNames: [String: String], chrNames: [String: String], readable: Set<String>) {
            self.want = want; self.svcNames = svcNames; self.chrNames = chrNames; self.readable = readable
        }
        func centralManagerDidUpdateState(_ c: CBCentralManager) {
            switch c.state {
            case .poweredOn: c.scanForPeripherals(withServices: nil, options: nil)
            case .unauthorized: emit("error=bluetooth-unauthorized"); done = true
            case .poweredOff: emit("error=bluetooth-off"); done = true
            default: break
            }
        }
        func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
            guard target == nil else { return }
            let name = (ad[CBAdvertisementDataLocalNameKey] as? String ?? p.name ?? "").lowercased()
            guard name.contains(want) || p.identifier.uuidString.lowercased().hasPrefix(want) else { return }
            c.stopScan(); target = p; p.delegate = self
            emit("device \(p.identifier.uuidString.prefix(8))  rssi \(rssi)  name \(p.name ?? "-")")
            emit("connecting…")
            c.connect(p, options: nil)
        }
        func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
            emit("connected"); p.discoverServices(nil)
        }
        func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
            emit("connect failed: \(error?.localizedDescription ?? "unknown")"); done = true
        }
        func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
            if !done { emit("disconnected early: \(error?.localizedDescription ?? "by device")") }
            done = true
        }
        func name(_ u: CBUUID, _ table: [String: String]) -> String { table[u.uuidString] ?? "" }
        func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
            guard let services = p.services, error == nil else { emit("service discovery failed: \(error?.localizedDescription ?? "")"); finishUp(); return }
            if services.isEmpty { emit("no services exposed"); finishUp(); return }
            for s in services { pendingServices += 1; p.discoverCharacteristics(nil, for: s) }
        }
        func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
            let sn = name(s.uuid, svcNames)
            emit("service \(s.uuid.uuidString)\(sn.isEmpty ? "" : "  (\(sn))")")
            for c in s.characteristics ?? [] {
                var props: [String] = []
                if c.properties.contains(.read) { props.append("read") }
                if c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse) { props.append("write") }
                if c.properties.contains(.notify) || c.properties.contains(.indicate) { props.append("notify") }
                let cn = name(c.uuid, chrNames)
                emit("  \(c.uuid.uuidString)\(cn.isEmpty ? "" : "  \(cn)")  [\(props.joined(separator: ","))]")
                if c.properties.contains(.read) && readable.contains(s.uuid.uuidString) { pendingReads += 1; p.readValue(for: c) }
            }
            pendingServices -= 1
            if pendingServices == 0 && pendingReads == 0 { finishUp() }
        }
        func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
            pendingReads -= 1
            let label = name(c.uuid, chrNames).isEmpty ? c.uuid.uuidString : name(c.uuid, chrNames)
            if let e = error { emit("    \(label) = (not readable: \(e.localizedDescription))") }
            else if let d = c.value {
                if c.uuid.uuidString == "2A19", let b = d.first { emit("    \(label) = \(b)%") }
                else if c.uuid.uuidString == "2A01", d.count >= 2 { emit("    \(label) = 0x\(String(format: "%04x", UInt16(d[0]) | UInt16(d[1]) << 8))") }
                else if let str = String(data: d, encoding: .utf8), !str.isEmpty, str.allSatisfy({ !$0.isASCII || ($0.asciiValue! >= 32 && $0.asciiValue! < 127) }) { emit("    \(label) = \"\(str.trimmingCharacters(in: .controlCharacters))\"") }
                else { emit("    \(label) = \(d.map { String(format: "%02x", $0) }.joined(separator: " "))") }
            }
            if pendingServices == 0 && pendingReads == 0 { finishUp() }
        }
        func finishUp() {
            if let t = target { central.cancelPeripheralConnection(t) }
            emit("disconnected")
            done = true
        }
    }
    let probe = Probe(want: want, svcNames: svcNames, chrNames: chrNames, readable: readable)
    probe.central = CBCentralManager(delegate: probe, queue: nil)
    let deadline = Date(timeIntervalSinceNow: 25)
    while !probe.done && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2)) }
    if !probe.done {
        emit(probe.target == nil ? "no device matching '\(want)' heard in 25 s" : "timed out; the device accepted the connection but stopped answering")
        if let t = probe.target { probe.central.cancelPeripheralConnection(t) }
    }
    finish(0)

default:
    emit("usage: wifiinfo [info|scan|auth|bt|btprobe] [--out FILE]")
    finish(2)
}
