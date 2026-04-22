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

struct ContentView: View {
    @EnvironmentObject var tunnel: TunnelManager

    var body: some View {
        NavigationView {
            Form {
                flagsSection
                profileSection
                statusSection
                logSection
            }
            .navigationTitle("Routing Diag")
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
