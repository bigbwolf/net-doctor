// wifiinfo — tiny CoreWLAN helper for `net`.
//   wifiinfo info   key=value lines about the current Wi-Fi link
//   wifiinfo scan   one line per nearby network: channel width band rssi bssid ssid
// SSIDs and BSSIDs are empty unless the calling terminal has Location Services access.

import CoreLocation
import CoreWLAN
import Foundation

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

guard let iface = CWWiFiClient.shared().interface() else {
    print("error=no Wi-Fi interface")
    exit(1)
}

let cmd = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "info"

// CoreWLAN only reveals SSIDs/BSSIDs while the process is actively using Location
// Services, so every command opens a location session first and waits briefly for
// the authorization state to settle. `auth` waits long enough for the dialog.
final class LocationDelegate: NSObject, CLLocationManagerDelegate {
    var sawPrompt = false
    var gotFix = false
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if m.authorizationStatus == .notDetermined && !sawPrompt && cmd == "auth" {
            sawPrompt = true
            FileHandle.standardError.write("waiting for the Location Services dialog…\n".data(using: .utf8)!)
        }
    }
    func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) { gotFix = true }
    func locationManager(_ m: CLLocationManager, didFailWithError e: Error) {}
}
let locationDelegate = LocationDelegate()
let location = CLLocationManager()
location.delegate = locationDelegate

func startLocation(waitUpTo seconds: TimeInterval) -> CLAuthorizationStatus {
    location.requestWhenInUseAuthorization()
    location.startUpdatingLocation()   // the dialog often appears only on a real request
    let deadline = Date(timeIntervalSinceNow: seconds)
    while Date() < deadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        if location.authorizationStatus != .notDetermined { break }
    }
    // CoreWLAN treats the process as "using location" once a fix has arrived.
    let fixDeadline = Date(timeIntervalSinceNow: 3)
    while !locationDelegate.gotFix && Date() < fixDeadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
    }
    return location.authorizationStatus
}

switch cmd {
case "info":
    _ = startLocation(waitUpTo: 2)
    print("iface=\(iface.interfaceName ?? "")")
    print("power=\(iface.powerOn() ? 1 : 0)")
    print("ssid=\(iface.ssid() ?? "")")
    print("bssid=\(iface.bssid() ?? "")")
    if let ch = iface.wlanChannel() {
        print("channel=\(ch.channelNumber)")
        print("width=\(widthMHz(ch.channelWidth))")
        print("band=\(bandName(ch.channelBand))")
    } else {
        print("channel=0")
        print("width=0")
        print("band=")
    }
    print("rssi=\(iface.rssiValue())")
    print("noise=\(iface.noiseMeasurement())")
    print("txrate=\(Int(iface.transmitRate()))")
    print("phy=\(phyName(iface.activePHYMode()))")
    print("security=\(securityName(iface.security()))")

case "scan":
    _ = startLocation(waitUpTo: 2)
    // Two passes catch networks a single scan misses. Keyed by BSSID when we can see it,
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
        print("\(ch?.channelNumber ?? 0)\t\(widthMHz(ch?.channelWidth ?? .widthUnknown))\t\(bandName(ch?.channelBand ?? .bandUnknown))\t\(n.rssiValue)\t\(n.bssid ?? "")\t\(n.ssid ?? "")")
    }

case "auth":
    if !CLLocationManager.locationServicesEnabled() {
        print("status=services-off")
        exit(1)
    }
    switch startLocation(waitUpTo: 120) {
    case .authorizedAlways, .authorized: print("status=granted")
    case .denied: print("status=denied")
    case .restricted: print("status=restricted")
    case .notDetermined: print("status=timeout"); exit(1)
    @unknown default: print("status=unknown")
    }

default:
    print("usage: wifiinfo [info|scan|auth]")
    exit(2)
}
