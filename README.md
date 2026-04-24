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

## Findings

Ran on iPhone SE3, iOS 26.2, April 2026. Full logs in
`findings/` (shared out via the app's Share button).

**Main result: `excludeAPNs` and `excludeCellularServices` are NOT
implemented via routing-table entries.** Toggling them adds or
removes no structural routes.

Diffed POST-SETTINGS IPv4 route tables across all four scenarios:

| pair | structural diff |
|---|---|
| A (`includeAllNetworks=false`) ↔ B (true, exclude\*=true) | none — only one cloned Apple host IP differs (`17.57.146.141` vs `.140`), a transient artifact |
| B (exclude\*=true) ↔ C (excludeAPNs=false) | one host-specific cloned route removed (`17.57.146.140 → en0`) — and that's it |
| C ↔ D (excludeCellularServices=false) | empty |

IPv6 diffs show the same pattern: a handful of NAT64-mapped Apple
host addresses (`64:ff9b::1139:xxxx`) appear/disappear as connections
come and go, but no new scoped defaults or explicit excludes.

### What's actually happening

In every scenario the routing table already contains
**interface-scoped default routes** for every physical / tunnel
interface:

```
0.0.0.0    192.168.4.10  en0      UGSI   ← Wi-Fi router, scoped
0.0.0.0    10.116.42.48  pdp_ip0  UGSI   ← cellular, scoped
0.0.0.0    13.4.173.240  pdp_ip1  UGSI   ← secondary cellular, scoped
0.0.0.0    link#131      utun56   USC    ← our fake VPN, unscoped default
```

The `UGSI` flag = Up / Gateway / Static / **Interface-scoped**.
These routes are used only when a socket is explicitly bound to
that interface. `apsd` (Apple Push Service daemon), `CommCenter`
(cellular services), and similar system daemons bind their sockets
to `en0` or `pdp_ip0` based on policies set at a layer above
routing — **NECP (Network Extension Control Policy)** — which
isn't inspectable from a Network Extension using documented APIs.

When `excludeAPNs=true` (or the equivalent split-tunnel default):
iOS's NECP policy pins `apsd`'s sockets to `en0` / `pdp_ip0`,
traffic uses the scoped default, bypasses the VPN tunnel. When
`excludeAPNs=false`: iOS releases that binding, `apsd` uses the
unscoped default (`utun56`), traffic goes through the tunnel.

The host-specific cloned routes we saw (`17.57.146.140 via
192.168.4.10 en0 UGHWI`) are *consequences* of that binding, not
its cause: once `apsd` made a TCP connection on `en0`, the kernel
cached a per-host route to speed up subsequent packets.

### Consequence for the original question

> Can we emulate `excludeAPNs=false` via
> `NEIPv4Settings.excludedRoutes` in a split-tunnel
> (`includeAllNetworks=false`) profile?

**No.** NECP socket-binding decisions happen before routing lookup,
so adding/removing routes has no effect on which interface
`apsd` uses. The only way to force APNs into a VPN tunnel is
`includeAllNetworks=true` + `excludeAPNs=false` — a honest
full-tunnel.

### Follow-up experiment: can a more-specific `includedRoute` beat NECP?

Added a second toggle, "Hijack Apple ranges", that places
`17.0.0.0/8` into `NEIPv4Settings.includedRoutes` and
`64:ff9b::/96` (the iOS NAT64 synthesis prefix) into
`NEIPv6Settings.includedRoutes`. Ran two additional scenarios:

- E: `includeAllNetworks=false` + hijack
- F: `includeAllNetworks=true`, `excludeAPNs=false`,
  `excludeCellularServices=false`, + hijack

In both the routing table shows our new entries cleanly:

```
17.0.0.0/af=255      link#131   utun56    USC
64:ff9b::/af=255     link#131   utun56    USC
```

But cloned host routes for active APNs / Apple-service
connections still come out pointing at **physical** interfaces:

```
17.57.146.138        192.168.4.10     en0      UGHWI   ← Wi-Fi, not utun56
64:ff9b::1139:9287   fe80:7::…        pdp_ip0  UGHWI   ← cellular, not utun56
64:ff9b::1139:9289   fe80:7::…        pdp_ip0  UGHWI
... (×6)
```

Even with `includeAllNetworks=true` + APNs and cellular-services
both unexcluded + explicit `/8` and `/96` include-entries, kernel
still sends Apple traffic to the physical interfaces.

**Why:** iOS/BSD uses **scoped route lookup**. When NECP binds a
socket to a specific interface, kernel's per-packet route lookup
is restricted to routes that are either unscoped OR scoped to
the same interface. The scoped default
`0.0.0.0 via <gw> <iface> UGSI` for `en0` / `pdp_ip0` wins
against any unscoped entry, because the socket lookup is itself
scoped to the interface that NECP chose.

`NEIPv4Settings.includedRoutes` / `excludedRoutes` only produce
**unscoped** routes. There is no documented API to install a
route scoped to the VPN's own interface and thereby beat NECP.

This is a stronger version of the same conclusion: the NECP
interface binding can't be overridden from a Network Extension
settings object at all. You have to let iOS decide whether APNs
goes through the tunnel via the `excludeAPNs` flag (which itself
only takes effect when `includeAllNetworks=true`).

### Track 2 follow-up: can we write directly to the kernel routing table?

The settings-object angle was dead-ended by NECP. The remaining
theoretical escape hatch was **direct PF_ROUTE socket writes** —
same BSD mechanism `route add` / `route delete` uses on macOS.
If an extension could `write(2)` an RTM_DELETE for the scoped
default, or an RTM_ADD for a scoped route pointing at the tunnel,
it might bypass NECP's interface binding at the routing-lookup
layer.

Result: **iOS sandboxes WRITES on PF_ROUTE sockets even though
READS (sysctl NET_RT_DUMP) are permitted.**

Evidence collected on iPhone SE3 / iOS 26.2 while a diagnostic
tunnel is running:

```
probe:                         rc=1   errno=0   socket(PF_ROUTE, SOCK_RAW, 0) OK
delete_scoped_default(en0):    rc=-1  errno=1   EPERM
delete_scoped_default(pdp_ip0):rc=-1  errno=1   EPERM
add_scoped_route(17/8):        rc=-1  errno=1   EPERM
```

Captures in `findings/track2/01-delete-en0-EPERM.log`,
`02-delete-pdp_ip0-EPERM.log`, `03-add-scoped-EPERM.log`.

All three `write(2)` attempts on a fresh PF_ROUTE socket from
within the NE fail immediately with `EPERM`. The kernel is
denying route-table modification to sandboxed extension
processes — it's not an "unreachable route" or "malformed
message" error, it's a flat permission rejection from the
socket-filter layer.

Side observation from the same dumps: in a split-tunnel
scenario (A), not ALL Apple-service IPs are routed via the
physical interface. Some 17.x IPs appear as cloned host routes
via `utun56`:

```
17.253.145.10   link#133    utun56   UHWI    ← via our tunnel
17.253.150.10   link#133    utun56   UHWI    ← via our tunnel
17.248.214.70   192.168.4.1 en0      UGHWI   ← via Wi-Fi
17.253.39.132   192.168.4.1 en0      UGHWI   ← via Wi-Fi
17.253.39.136   192.168.4.1 en0      UGHWI   ← via Wi-Fi
```

This confirms that NECP's interface binding is **per-process**,
not per-destination. `apsd`, `CommCenter`, and a handful of
other system daemons get pinned to a physical interface by
policy; "normal" processes that happen to contact Apple hosts
(Safari loading an iCloud resource, for instance) fall through
to the default route and use the tunnel. So the Apple
`17.0.0.0/8` space isn't uniformly carved out — specific
daemons are.

### Track 2 conclusion

Track 2 adds a third layer of confirmation:

- Settings-object flags (Track 1): don't change routing table;
  act at NECP layer.
- More-specific unscoped includedRoutes (hijack follow-up):
  don't win against NECP's scoped socket binding.
- **Direct routing-table writes (Track 2): sandboxed, EPERM.**

There is no documented, public API from a Network Extension that
can move APNs / CommCenter traffic between interfaces. The
`includeAllNetworks=true` + `excludeAPNs=false` combination is
the only lever.
