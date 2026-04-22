//
//  ContentView.swift
//  RoutingDiag
//
//  One-screen SwiftUI UI: toggle the four iOS flags, install/update the
//  VPN profile, connect/disconnect, view the log file the extension
//  writes to the shared App Group container.
//

import SwiftUI
import NetworkExtension

struct ContentView: View {
    @EnvironmentObject var tunnel: TunnelManager

    var body: some View {
        NavigationView {
            Form {
                Section("Flags") {
                    Toggle("includeAllNetworks", isOn: $tunnel.includeAllNetworks)
                    Toggle("excludeLocalNetworks", isOn: $tunnel.excludeLocalNetworks)
                        .disabled(!tunnel.includeAllNetworks)
                    Toggle("excludeAPNs (iOS 16.4+)", isOn: $tunnel.excludeAPNs)
                        .disabled(!tunnel.includeAllNetworks)
                    Toggle("excludeCellularServices (iOS 16.4+)",
                           isOn: $tunnel.excludeCellularServices)
                        .disabled(!tunnel.includeAllNetworks)
                    Text(flagHint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Profile") {
                    Button("Install / Update Profile") {
                        Task { await tunnel.installOrUpdateProfile() }
                    }
                    if let err = tunnel.lastError {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                Section("Status: \(tunnel.status.description)") {
                    HStack(spacing: 16) {
                        Button("Connect") { tunnel.connect() }
                            .disabled(tunnel.status == .connected
                                      || tunnel.status == .connecting)
                        Button("Disconnect") { tunnel.disconnect() }
                            .disabled(tunnel.status == .disconnected
                                      || tunnel.status == .invalid)
                    }
                }

                Section("Log") {
                    HStack(spacing: 16) {
                        Button("Refresh") { tunnel.refreshLog() }
                        Button("Clear") { tunnel.clearLog() }
                            .foregroundColor(.red)
                    }
                    ScrollView(.horizontal) {
                        Text(tunnel.logContents.isEmpty ? "(empty)" : tunnel.logContents)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(minWidth: 0, alignment: .leading)
                    }
                    .frame(maxHeight: 400)
                }
            }
            .navigationTitle("Routing Diag")
        }
    }

    private var flagHint: String {
        if !tunnel.includeAllNetworks {
            return "Split-tunnel mode. Exclude* flags are ignored by iOS."
        }
        return "Full-tunnel mode. Exclude* flags take effect (iOS 16.4+ for APNs and Cellular)."
    }
}

#Preview {
    ContentView().environmentObject(TunnelManager())
}
