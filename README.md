# net-doctor

A `net` command for macOS that says in plain words why your internet is failing.

Most "no internet" moments on a Mac are not DNS or proxy problems, whatever the error
message says. Often the Wi-Fi radio is stalling on a crowded channel while the Mac stays
"connected". `net check` reads what the Mac already knows (signal, noise, channel, the
Wi-Fi driver's own stall counters) and probes each layer in order, then ends with a verdict
that names the layer at fault.

```
$ net check
net check  13:18:44

  Link      Wi-Fi (en0) → 192.168.1.182, router 192.168.1.254, DNS 192.168.1.254
  Radio     ch 132 (5 GHz, 80 MHz) · signal -70 dBm · noise -86 dBm · SNR 16 dB (fair) · 292 Mb/s
  Stalls    last 10 min: none logged by the driver
  Router    192.168.1.254: 0% loss, avg 3 ms
  Internet  1.1.1.1: 0% loss, avg 10 ms
  DNS       via 192.168.1.254: 3 ms · direct 1.1.1.1: 10 ms
  HTTPS     google.com/generate_204: HTTP 204 in 62 ms
  Config    proxy: none · VPN connected: 0 · network extensions enabled: 2

Verdict:
  Everything is working right now. Wi-Fi margin is fair (SNR 16 dB).
```

## Commands

| Command | What it does |
|---|---|
| `net check` | Diagnose the current connection: radio quality, driver stalls in the last 10 minutes, then router → internet → DNS → HTTPS probes, then a verdict |
| `net scan` | Nearby Wi-Fi networks with channel, width and signal; which 5 GHz channel block is quietest from where you sit |

Diagnosis never needs `sudo`.

## The verdicts

| Where the chain breaks | Verdict |
|---|---|
| Pings to the router are lost, or the driver logged stalls | The Wi-Fi link to the router. Shows SNR and how busy the channel was |
| Router fine, internet IP unreachable | The router's uplink or the ISP |
| Internet fine, router's DNS silent, direct DNS works | The router's DNS |
| Internet fine, all DNS silent | Something blocking DNS: VPN, filter, captive portal |
| Ping and DNS fine, HTTPS fails | Something intercepting traffic: proxy, VPN, network extension |
| All fine | Working now, with the Wi-Fi margin graded good / fair / poor |

## Install

Requires Xcode command line tools (for `swiftc`).

```
git clone https://github.com/bigbwolf/net-doctor.git
cd net-doctor
make install        # builds the helper, symlinks `net` into ~/.local/bin
```

`PREFIX=/usr/local make install` to put it elsewhere.

## How it works

- `net` is a zsh script. It uses `route`, `ipconfig`, `ping`, `dig`, `curl`, `scutil` and
  `log show`, all of which ship with macOS.
- `wifiinfo` is a 100-line Swift helper around CoreWLAN for the readings the shell cannot
  get: RSSI, noise, channel, width, transmit rate, and the scan.
- Driver stall counters (`DPS Symptoms`, `Datapath timeout`, channel-busy %) come from the
  kernel's unified log; reading 10 minutes of it takes a few seconds.
- Network names are hidden unless your terminal app has Location Services access
  (System Settings › Privacy & Security › Location Services). Everything else works without it.

## License

MIT
