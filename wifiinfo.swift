// wifiinfo — tiny CoreWLAN helper for `net`, built into net-doctor.app.
//   wifiinfo info [--out FILE]   key=value lines about the current Wi-Fi link
//   wifiinfo scan [--out FILE]   one line per nearby network: channel width band rssi bssid ssid
//   wifiinfo auth [--out FILE]   request Location Services (needed for network names)
//
// macOS only reveals SSIDs/BSSIDs to a process that (a) is a signed app bundle with Location
// Services granted and (b) was launched as a real app session, not spawned by a shell. `net`
// therefore runs this through `open -W net-doctor.app --args <cmd> --out FILE` and reads
// FILE; run directly from a shell it still works, just with names hidden.

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

default:
    emit("usage: wifiinfo [info|scan|auth] [--out FILE]")
    finish(2)
}
