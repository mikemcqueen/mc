# AltStore / SideStore: Sideloading on iOS Without a Paid Developer Account

## The Core Problem They Solve

Without a paid Apple Developer account ($99/yr), apps installed via Xcode expire after **7 days** — the app simply stops launching. The normal fix is to reconnect to Xcode and reinstall, which re-signs the app for another 7 days.

AltStore and SideStore automate this resign-and-reinstall cycle using your free Apple ID.

---

## How They Work

Apple's free developer program lets any Apple ID sign apps to personal devices — the same mechanism Xcode uses. AltStore/SideStore exploit this legitimately:

1. You provide your Apple ID credentials to the tool
2. It signs the app with your personal certificate (same as Xcode would)
3. It automates the refresh before the 7-day window expires

The 7-day limit still applies — they just handle the renewal without you needing to open Xcode or plug in your phone.

---

## AltStore vs SideStore

| | AltStore | SideStore |
|---|---|---|
| **Origin** | Original project | Community fork of AltStore |
| **Refresh method** | Requires companion app running on Mac/PC | On-device refresh via VPN loopback trick |
| **Mac required for refresh?** | Yes (or PC) | No |
| **Open source** | Partially | Yes |
| **EU App Marketplace** | Yes (officially approved) | No |

**AltStore** is the more established project and requires a "AltServer" companion app running on your Mac (or PC) to refresh apps — either over USB or on the same WiFi network.

**SideStore** is more independent: it uses an on-device WireGuard VPN loopback to trick iOS into thinking it's talking to a local server, enabling fully on-device refresh without needing a Mac present. More hacker-y but very capable.

---

## Standing with Apple

- **Not officially supported** but not actively blocked
- Apple tolerates it because it exploits a legitimate mechanism (personal device signing via free Apple ID)
- In **2024**, EU regulations forced Apple to allow alternative app marketplaces, and **AltStore became one of the first officially approved alternative marketplaces in the EU** — a significant legitimacy signal
- Apple could shut down the underlying mechanism but hasn't, likely because usage is personal-scale and low-volume

---

## Community Standing

Well-respected in the iOS dev and enthusiast community. Not considered a piracy or jailbreak tool:

- Primarily used by developers testing their own apps and hobbyists installing open-source apps not on the App Store
- Projects are open source and maintained transparently
- AltStore's EU marketplace approval further legitimized it

---

## Risk Assessment for Personal Use

**Essentially none.** Apple's ToS technically restricts distributing apps outside the App Store, but sideloading your *own* app to your *own* device for personal use is exactly what the free developer program is designed for. AltStore/SideStore just remove the manual friction.

---

## Practical Workflow for iOS Dev Without Paid Account

1. Build and install via Xcode initially (establishes the bundle ID and device trust)
2. Install AltStore or SideStore on the device
3. Use AltStore/SideStore to manage ongoing 7-day refresh automatically

**App data is preserved** across reinstalls as long as the bundle ID stays the same.

---

## Alternatives

| Option | Cost | Install Duration | Notes |
|---|---|---|---|
| Xcode manual reinstall | Free | 7 days | Requires Mac + USB every ~6 days |
| AltStore/SideStore | Free | 7 days (auto-renewed) | Reduces friction significantly |
| TestFlight | Paid ($99/yr dev account) | 90 days | Intended for beta testing |
| Paid dev account personal install | $99/yr | No expiry | Full App Store capability |
