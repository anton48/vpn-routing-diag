//
//  TunnelManager.swift
//  RoutingDiag
//
//  Wraps NETunnelProviderManager and exposes the four iOS flags we care
//  about (`includeAllNetworks`, `excludeLocalNetworks`, `excludeAPNs`,
//  `excludeCellularServices`) as `@Published` bindings the UI can drive
//  directly.
//

import Foundation
@preconcurrency import NetworkExtension
import Combine

@MainActor
final class TunnelManager: ObservableObject {

    /// Bundle ID of the packet tunnel extension. Must match the value
    /// in `project.yml` (target `PacketTunnel`).
    private let providerBundleID = "com.vkturnproxy.routingdiag.app.tunnel"

    /// App Group ID shared with the extension. Must match both
    /// entitlements files.
    static let appGroupID = "group.com.vkturnproxy.routingdiag"

    @Published var includeAllNetworks: Bool = false
    @Published var excludeLocalNetworks: Bool = true   // matches iOS default on iOS
    @Published var excludeAPNs: Bool = true            // matches iOS default
    @Published var excludeCellularServices: Bool = true // matches iOS default

    @Published var status: NEVPNStatus = .invalid
    @Published var lastError: String?
    @Published var logContents: String = ""

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    init() {
        Task { await self.load() }
    }

    /// Load (or create) the VPN profile from iOS preferences.
    func load() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            // We keep a single profile — reuse an existing one if present.
            self.manager = managers.first
            if let m = self.manager {
                observeStatus(m)
                status = m.connection.status
            }
        } catch {
            lastError = "load: \(error.localizedDescription)"
        }
    }

    /// Build a `NETunnelProviderProtocol` with the current UI flags and
    /// save it to preferences. iOS will prompt the user to add/update
    /// the profile on first install (or after bundle-ID changes).
    func installOrUpdateProfile() async {
        let m = manager ?? NETunnelProviderManager()

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleID
        // `serverAddress` is metadata only — iOS shows it in Settings.
        proto.serverAddress = "diag-peer.invalid"

        proto.includeAllNetworks = includeAllNetworks
        proto.excludeLocalNetworks = excludeLocalNetworks
        if #available(iOS 16.4, *) {
            proto.excludeAPNs = excludeAPNs
            proto.excludeCellularServices = excludeCellularServices
        }

        // Stash the chosen flags in providerConfiguration so the
        // extension can log them alongside the routing dump.
        proto.providerConfiguration = [
            "includeAllNetworks": includeAllNetworks,
            "excludeLocalNetworks": excludeLocalNetworks,
            "excludeAPNs": excludeAPNs,
            "excludeCellularServices": excludeCellularServices,
        ]

        m.protocolConfiguration = proto
        m.localizedDescription = "Routing Diag"
        m.isEnabled = true

        do {
            try await m.saveToPreferences()
            try await m.loadFromPreferences()
            self.manager = m
            observeStatus(m)
            lastError = nil
        } catch {
            lastError = "saveToPreferences: \(error.localizedDescription)"
        }
    }

    func connect() {
        guard let m = manager else {
            lastError = "no profile installed; tap Install / Update first"
            return
        }
        do {
            try m.connection.startVPNTunnel()
            lastError = nil
        } catch {
            lastError = "startVPNTunnel: \(error.localizedDescription)"
        }
    }

    func disconnect() {
        manager?.connection.stopVPNTunnel()
    }

    /// Pull the routing-log file from the shared App Group container.
    /// Called from the UI on demand; we don't auto-tail the file
    /// because it's fine to refresh after each connect cycle.
    func refreshLog() {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) else {
            let msg = "(App Group container unavailable — check entitlements)"
            NSLog("[RoutingDiag-App] refreshLog: \(msg)")
            logContents = msg
            return
        }
        let url = container.appendingPathComponent("routing.log")
        NSLog("[RoutingDiag-App] refreshLog: resolved url=\(url.path)")

        let fm = FileManager.default
        let exists = fm.fileExists(atPath: url.path)
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        NSLog("[RoutingDiag-App] refreshLog: exists=\(exists) size=\(size ?? -1)")

        if !exists {
            logContents = "(no log file yet — connect the tunnel at least once)"
            return
        }
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                logContents = "(log file has \(data.count) bytes but isn't valid UTF-8)"
                return
            }
            logContents = text
        } catch {
            let msg = "(failed to read log file: \(error.localizedDescription))"
            NSLog("[RoutingDiag-App] refreshLog: \(msg)")
            logContents = msg
        }
    }

    /// Clear the log file in the shared container so a fresh run is
    /// easy to read.
    func clearLog() {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) else {
            return
        }
        let url = container.appendingPathComponent("routing.log")
        try? FileManager.default.removeItem(at: url)
        logContents = ""
    }

    // MARK: - Private

    private func observeStatus(_ m: NETunnelProviderManager) {
        if let ob = statusObserver {
            NotificationCenter.default.removeObserver(ob)
        }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: m.connection,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.status = m.connection.status
            }
        }
        status = m.connection.status
    }
}

extension NEVPNStatus {
    var description: String {
        switch self {
        case .invalid: return "invalid"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reasserting: return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown(\(rawValue))"
        }
    }
}
