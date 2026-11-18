# ONVPN

ONVPN is an Android VPN client with a dark three-tab interface, subscription import, server profiles, a live connection map and a sing-box networking engine.

## Features

- Home, Servers and Settings bottom navigation.
- sing-box engine through the `sing_box` Flutter plugin.
- VLESS TCP + Reality, VLESS gRPC + Reality and Hysteria2 share links supported by the engine.
- Subscription URL can be changed in Settings. HTTP requests made by ONVPN use:
  `User-Agent: Onvpn/1.0.0/vpnconnection`.
- Imported profile links are kept locally on the device.
- Animated route map: Hysteria2 fast dashes, gRPC medium, TCP slow.
- Ocean area is transparent (the app background shows through); land is slightly brighter.
- Device position is requested only after the user grants location permission. Server position is looked up from its hostname/IP; if lookup is unavailable, the server marker is omitted rather than fabricated.
- GitHub Actions builds a release APK on pushes to main and on manual runs.

## Build

Open **Actions → Build ONVPN APK** in GitHub. Download the `ONVPN-APK` artifact from a successful run.

## Privacy and credentials

Subscription URLs and imported share links are stored locally using Android shared preferences. They are not committed to this repository. The server map lookup sends the selected server hostname/IP to ipwho.is to estimate the server's geographic position. The device location is not sent to that service.

Do not commit private subscription URLs, UUIDs, passwords, or share links.

## Engine and license

The `sing_box` plugin bundles the sing-box core. The plugin and sing-box core are GPL-3.0-or-later; distribution of builds containing them must comply with that license and preserve third-party notices. ONVPN source is provided under GPL-3.0-or-later.
