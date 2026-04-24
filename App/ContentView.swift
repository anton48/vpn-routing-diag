//
//  ContentView.swift
//  RoutingDiag
//
//  Toggle the four iOS flags, install/update the VPN profile,
//  connect/disconnect, view the log file the extension writes to
//  the shared App Group container.
//

import SwiftUI
import NetworkExtension

// URL already conforms to Hashable/Equatable; extend it with the
// Identifiable conformance so it can drive a SwiftUI `sheet(item:)`.
extension URL: Identifiable {
    public var id: URL { self }
}

struct ContentView: View {
    @EnvironmentObject var tunnel: TunnelManager
    @State private var shareURL: URL?

    var body: some View {
        NavigationView {
            Form {
                flagsSection
                profileSection
                statusSection
                experimentsSection
                logSection
            }
            .navigationTitle("Routing Diag")
            .sheet(item: $shareURL) { url in
                ShareSheet(items: [url])
            }
        }
    }

    private var experimentsSection: some View {
        Section(header: Text("Experiments (PF_ROUTE writes)")) {
            Button("Probe: open PF_ROUTE socket") {
                tunnel.sendExperimentCommand("probe")
            }
            Button("Delete scoped default on en0") {
                tunnel.sendExperimentCommand("delete_scoped_default:en0")
            }
            Button("Delete scoped default on pdp_ip0") {
                tunnel.sendExperimentCommand("delete_scoped_default:pdp_ip0")
            }
            Button("Add scoped 17/8 → 10.200.0.4 on en0") {
                tunnel.sendExperimentCommand("add_scoped_route:17.0.0.0:255.0.0.0:10.200.0.4:en0")
            }
            Button("Dump routing table now") {
                tunnel.sendExperimentCommand("dump_now:manual")
            }
            if !tunnel.lastExperimentResult.isEmpty {
                Text(tunnel.lastExperimentResult)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
            Text("Runs against the currently connected tunnel. Open the log below after each press to see the kernel's reaction.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Sections

    private var flagsSection: some View {
        Section(header: Text("Flags")) {
            Toggle("includeAllNetworks", isOn: $tunnel.includeAllNetworks)

            if tunnel.includeAllNetworks {
                Toggle("excludeLocalNetworks", isOn: $tunnel.excludeLocalNetworks)
                Toggle("excludeAPNs (iOS 16.4+)", isOn: $tunnel.excludeAPNs)
                Toggle("excludeCellularServices (iOS 16.4+)",
                       isOn: $tunnel.excludeCellularServices)
                Text("Full-tunnel mode. Exclude* flags take effect (iOS 16.4+ for APNs / Cellular).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Split-tunnel mode. iOS ignores exclude* flags; they are hidden here so the effective configuration is unambiguous.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Toggle("Hijack Apple ranges (17.0.0.0/8 + 64:ff9b::/96)",
                   isOn: $tunnel.hijackAppleRanges)
            Text("Experiment: add Apple's /8 + NAT64 prefix explicitly to includedRoutes. Tests whether a more-specific route beats NECP's interface binding for APNs sockets.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var profileSection: some View {
        Section(header: Text("Profile")) {
            Button("Install / Update Profile") {
                Task { await tunnel.installOrUpdateProfile() }
            }
            if let err = tunnel.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    private var statusSection: some View {
        Section(header: Text("Status: \(tunnel.status.description)")) {
            HStack(spacing: 16) {
                Button("Connect") { tunnel.connect() }
                    .disabled(tunnel.status == .connected
                              || tunnel.status == .connecting)
                Button("Disconnect") { tunnel.disconnect() }
                    .disabled(tunnel.status == .disconnected
                              || tunnel.status == .invalid)
            }
        }
    }

    private var logSection: some View {
        Section(header: Text("Log")) {
            HStack(spacing: 16) {
                Button("Refresh") { tunnel.refreshLog() }
                Button("Share") {
                    if let url = tunnel.prepareLogForSharing() {
                        shareURL = url
                    }
                }
                .disabled(tunnel.logContents.isEmpty)
                Spacer()
                Button("Clear") { tunnel.clearLog() }
                    .foregroundColor(.red)
            }
            Text(tunnel.logContents.isEmpty
                 ? "(empty — hit Connect then Refresh. If still empty after a connected tunnel, the App Group container is likely unavailable; check Console.app on a tethered Mac for os_log messages from subsystem 'com.vkturnproxy.routingdiag.tunnel'.)"
                 : tunnel.logContents)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    ContentView().environmentObject(TunnelManager())
}
