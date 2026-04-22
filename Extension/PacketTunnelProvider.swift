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
//  5. Keep a packet reader loop alive so iOS doesn't tear the tunnel
//     down for "not making progress". Packets are discarded.
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
        SharedLogger.log("--- startTunnel entry ---")

        let proto = protocolConfiguration as? NETunnelProviderProtocol
        let flags = proto?.providerConfiguration ?? [:]
        SharedLogger.log("serverAddress=\(proto?.serverAddress ?? "nil")")
        SharedLogger.log("flags (from providerConfiguration): \(flags)")
        let iosFlagSummary = "includeAllNetworks=\(proto?.includeAllNetworks ?? false)"
            + " excludeLocalNetworks=\(proto?.excludeLocalNetworks ?? false)"
            + iOS164FlagDescription(proto)
        SharedLogger.log("flags (from NEVPNProtocol): \(iosFlagSummary)")

        // 1. PRE-SETTINGS.
        SharedLogger.log(RoutingTable.dump(label: "PRE-SETTINGS"))

        // 2. Build settings that mimic a real full-tunnel VPN.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.200.0.4"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        ipv4.excludedRoutes = []
        settings.ipv4Settings = ipv4
        settings.dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "1.0.0.1"])
        settings.mtu = NSNumber(value: 1280)

        SharedLogger.log("applying NEPacketTunnelNetworkSettings...")
        setTunnelNetworkSettings(settings) { error in
            if let error = error {
                SharedLogger.log("setTunnelNetworkSettings error: \(error.localizedDescription)")
                completionHandler(error)
                return
            }
            SharedLogger.log("setTunnelNetworkSettings OK")

            // 3. POST-SETTINGS.
            SharedLogger.log(RoutingTable.dump(label: "POST-SETTINGS"))

            // 4. Signal iOS the tunnel is up.
            completionHandler(nil)
            SharedLogger.log("completionHandler(nil) called — iOS should go to .connected")

            // 5. Keep the TUN drained so iOS doesn't time us out.
            self.startPacketDrain()

            // Delayed POST-COMPLETION snapshot in case iOS installs
            // additional rules after transitioning to .connected.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                SharedLogger.log(RoutingTable.dump(label: "POST-COMPLETION (2s after)"))
                SharedLogger.log("--- startTunnel flow finished ---")
            }
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        SharedLogger.log("--- stopTunnel reason=\(stopReasonName(reason)) ---")
        SharedLogger.log(RoutingTable.dump(label: "PRE-TEARDOWN"))
        completionHandler()
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)?
    ) {
        // Reserved for dump-on-demand IPC from the main app.
        if let cb = completionHandler { cb(messageData) }
    }

    // MARK: - Private

    /// iOS tears the tunnel down quickly if the provider doesn't
    /// actively read from its packet flow. Since we're not a real
    /// VPN and have nothing to forward, we just discard everything.
    private func startPacketDrain() {
        packetFlow.readPackets { [weak self] _, _ in
            // Intentionally dropped. Chain recursively.
            self?.startPacketDrain()
        }
    }

    private func iOS164FlagDescription(_ proto: NETunnelProviderProtocol?) -> String {
        if #available(iOS 16.4, *) {
            return " excludeAPNs=\(proto?.excludeAPNs ?? false)"
                 + " excludeCellularServices=\(proto?.excludeCellularServices ?? false)"
        }
        return ""
    }

    private func stopReasonName(_ reason: NEProviderStopReason) -> String {
        switch reason {
        case .none: return "none"
        case .userInitiated: return "userInitiated"
        case .providerFailed: return "providerFailed"
        case .noNetworkAvailable: return "noNetworkAvailable"
        case .unrecoverableNetworkChange: return "unrecoverableNetworkChange"
        case .providerDisabled: return "providerDisabled"
        case .authenticationCanceled: return "authenticationCanceled"
        case .configurationFailed: return "configurationFailed"
        case .idleTimeout: return "idleTimeout"
        case .configurationDisabled: return "configurationDisabled"
        case .configurationRemoved: return "configurationRemoved"
        case .superceded: return "superceded"
        case .userLogout: return "userLogout"
        case .userSwitch: return "userSwitch"
        case .connectionFailed: return "connectionFailed"
        case .sleep: return "sleep"
        case .appUpdate: return "appUpdate"
        @unknown default: return "unknown(\(reason.rawValue))"
        }
    }
}
