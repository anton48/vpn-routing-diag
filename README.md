# iOS VPN Routing Diagnostic

A minimal iOS app + packet-tunnel extension that applies VPN network
settings with user-chosen `includeAllNetworks` / `excludeAPNs` /
`excludeCellularServices` / `excludeLocalNetworks` flags, and dumps the
kernel routing table + interface list at key moments so the resulting
policies can be inspected.

## Purpose

`NEVPNProtocol.excludeAPNs` (iOS 16.4+) is only available when
`includeAllNetworks` is `true`. This tool lets us empirically determine
**how** iOS implements the `excludeAPNs` semantics:

- **If the only difference** between
  `includeAllNetworks=true, excludeAPNs=true` (default, APNs bypasses
  tunnel) and `includeAllNetworks=true, excludeAPNs=false` (APNs goes
  through tunnel) **is a set of routing-table entries**, then the
  same behavior can be emulated in a split-tunnel profile
  (`includeAllNetworks=false`) by adding the same entries to
  `NEIPv4Settings.includedRoutes` / `excludedRoutes`.

- **If the routing tables are identical** and the difference lives at
  a higher layer (NECP socket policies, per-process interface
  preferences), then emulation via routing settings is not possible —
  APNs-via-tunnel requires a honest `includeAllNetworks=true` profile.

## Building

Requires Xcode 16+, a paid Apple Developer account, and `xcodegen`
(`brew install xcodegen`).

```
xcodegen generate          # generates RoutingDiag.xcodeproj
open RoutingDiag.xcodeproj # then configure signing team and run on a device
```

iOS Simulator does not provide a real routing table — run on a
physical device.

### App Groups

Both the app and the extension share the App Group
`group.com.vkturnproxy.routingdiag`. If your Apple Developer team
doesn't own the `com.vkturnproxy.*` prefix, change the identifier
in all four places — `App/App.entitlements`,
`Extension/Extension.entitlements`, `App/TunnelManager.swift`
(`appGroupID`), `Extension/SharedLogger.swift` (`appGroupID`) —
and regenerate the project with `xcodegen generate`.

Xcode's Automatic Signing usually creates the group identifier for
you the first time you build. If the group identifier stays red
in the Capabilities pane, click the circular refresh arrow next to
the `+` button under "App Groups" to nudge Xcode. If still red,
create it manually at
<https://developer.apple.com/account/resources/identifiers/list/applicationGroup>.

## Usage

1. Launch the app on a device connected to Wi-Fi or cellular.
2. Pick the flag combination you want to test:
   - `includeAllNetworks` — default `false`
   - `excludeAPNs` — iOS 16.4+, only meaningful when `includeAllNetworks=true`
   - `excludeCellularServices` — iOS 16.4+, same
   - `excludeLocalNetworks` — any iOS 14.2+
3. Tap **Install / Update Profile** — saves the VPN configuration.
4. Tap **Connect** — iOS runs the tunnel extension, which applies
   `NEPacketTunnelNetworkSettings` and then dumps the routing table.
5. Open the **Log** tab to read the dumps. They are also written to a
   shared file at
   `<AppGroup>/routing.log`, readable from the app via
   `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)`.

## Test matrix

Run at least these four configurations and diff the resulting routing
tables:

| # | includeAllNetworks | excludeLocalNetworks | excludeAPNs | excludeCellularServices |
|---|---|---|---|---|
| A | `false` | (ignored) | (ignored) | (ignored) |
| B | `true`  | `true`  | `true`  | `true`  |
| C | `true`  | `true`  | `false` | `true`  |
| D | `true`  | `true`  | `true`  | `false` |

- A vs B — full-tunnel vs split-tunnel baseline, shows what
  `includeAllNetworks=true` adds.
- B vs C — what `excludeAPNs=false` changes.
- B vs D — what `excludeCellularServices=false` changes.

## What the dumps look like

Each dump contains:

- Timestamp and phase label (e.g. `PRE-SETTINGS`, `POST-SETTINGS`,
  `POST-COMPLETION`).
- Full routing table via `sysctl(CTL_NET, PF_ROUTE, 0, AF_INET,
  NET_RT_DUMP, 0)` — destination, gateway, interface name, flags.
- List of all network interfaces via `getifaddrs(3)` — name, family,
  address, netmask, flags.

Compare two dumps with a simple `diff` or side-by-side in a text
editor.

## Notes

- This tool does not run a real WireGuard / IKEv2 / IPsec tunnel. It
  only applies `NEPacketTunnelNetworkSettings` and reports
  `completionHandler(nil)`. iOS considers the tunnel "up" in
  `.connected` state, but no actual packet forwarding happens — this
  is fine for inspecting routing-table configuration, since iOS sets
  routes based on the network-settings object, not based on whether
  the tunnel's peer is reachable.
- If you need routing state *after* a real handshake (for cases where
  iOS changes routing on `.connected` transition), extend the
  extension to run an actual WireGuard / OpenVPN client — this
  skeleton doesn't include that.
