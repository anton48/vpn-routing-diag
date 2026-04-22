//
//  PacketTunnelProvider.swift
//  RoutingDiag / Extension
//
//  Minimal packet-tunnel provider whose only purpose is to:
//
//  1. Dump the kernel routing table BEFORE we touch
//     NEPacketTunnelNetworkSettings (`PRE-SETTINGS`).
//  2. Apply a minimal settings object (tunnel IP, DNS, default route)
//     whose shape matches what a real full-tunnel VPN would use.
//  3. Dump the routing table AFTER the settings are applied
//     (`POST-SETTINGS`).
//  4. Call `completionHandler(nil)` so iOS transitions the tunnel to
//     `.connected`, then dump once more after a short settle delay
//     (`POST-COMPLETION`) in case iOS finalizes routes asynchronously.
//
//  The tunnel doesn't forward any packets — the TUN fd is accepted
//  but never read from. That's fine for routing-table inspection;
//  iOS populates the routing table based on NEPacketTunnelNetworkSettings,
//  not based on whether the tunnel is actually moving data.
//

import Foundation
import NetworkExtension
import os.log

final class PacketTunnelProvider: NEPacketTunnelProvider {

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        SharedLogger.reset()

        // Echo the chosen flags from providerConfiguration so the log
        // is self-contained.
        let proto = protocolConfiguration as? NETunnelProviderProtocol
        let flags = proto?.providerConfiguration ?? [:]
        SharedLogger.log("startTunnel called")
        SharedLogger.log("serverAddress=\(proto?.serverAddress ?? "nil")")
        SharedLogger.log("flags (from providerConfiguration): \(flags)")
        SharedLogger.log("flags (from NEVPNProtocol):"
                         + " includeAllNetworks=\(proto?.includeAllNetworks ?? false)"
                         + " excludeLocalNetworks=\(proto?.excludeLocalNetworks ?? false)"
                         + iOS164FlagDescription(proto))

        // 1. Pre-settings snapshot.
        SharedLogger.log(RoutingTable.dump(label: "PRE-SETTINGS"))

        // 2. Build settings. Shape mimics a full-tunnel VPN:
        //    - Tunnel IP 10.200.0.4/24
        //    - IPv4 default route via the tunnel
        //    - DNS 1.1.1.1 (so iOS installs DNS routes)
        //    - No custom excludedRoutes — we want to see what iOS
        //      adds on its own when includeAllNetworks / excludeAPNs
        //      flags are toggled.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.0.0.1")

        let ipv4 = NEIPv4Settings(addresses: ["10.200.0.4"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        ipv4.excludedRoutes = [] // leave empty to see what iOS does by itself
        settings.ipv4Settings = ipv4

        let dns = NEDNSSettings(servers: ["1.1.1.1", "1.0.0.1"])
        settings.dnsSettings = dns

        settings.mtu = NSNumber(value: 1280)

        SharedLogger.log("applying NEPacketTunnelNetworkSettings...")
        setTunnelNetworkSettings(settings) { error in
            if let error = error {
                SharedLogger.log("setTunnelNetworkSettings error: \(error.localizedDescription)")
                completionHandler(error)
                return
            }

            SharedLogger.log("setTunnelNetworkSettings OK")

            // 3. Post-settings snapshot.
            SharedLogger.log(RoutingTable.dump(label: "POST-SETTINGS"))

            // 4. Signal success and dump again after a short settle.
            completionHandler(nil)
            SharedLogger.log("completionHandler(nil) called — iOS should transition to .connected")

            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                SharedLogger.log(RoutingTable.dump(label: "POST-COMPLETION (1.5s after)"))
                SharedLogger.log("startTunnel flow finished")
            }
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        SharedLogger.log("stopTunnel reason=\(reason.rawValue)")
        SharedLogger.log(RoutingTable.dump(label: "PRE-TEARDOWN"))
        completionHandler()
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)?
    ) {
        // Currently unused. Reserved for future "dump on demand" IPC
        // from the main app if we want to capture routing state after
        // some user-triggered event (Wi-Fi reconnect, etc.).
        if let cb = completionHandler { cb(messageData) }
    }

    // MARK: - Private

    private func iOS164FlagDescription(_ proto: NETunnelProviderProtocol?) -> String {
        if #available(iOS 16.4, *) {
            return " excludeAPNs=\(proto?.excludeAPNs ?? false)"
                 + " excludeCellularServices=\(proto?.excludeCellularServices ?? false)"
        }
        return ""
    }
}
