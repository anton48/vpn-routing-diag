//
//  SharedLogger.swift
//  RoutingDiag / Extension
//
//  Three-tier logging so diagnostics survive any one tier failing:
//
//  1. `os_log` — visible in Console.app while a device is tethered
//     to a Mac (Window → Devices and Simulators → View Device Logs).
//  2. `NSLog` — same stream, broader iOS sysdiagnose coverage.
//  3. Shared App Group file — readable from the main app's UI. If
//     the App Group container isn't available (identifier not
//     registered, entitlement mismatch), this tier silently fails
//     but tiers 1 and 2 still work.
//

import Foundation
import os.log

enum SharedLogger {

    private static let appGroupID = "group.com.vkturnproxy.routingdiag"
    private static let fileName = "routing.log"
    private static let osLog = OSLog(subsystem: "com.vkturnproxy.routingdiag.tunnel",
                                     category: "routing")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let queue = DispatchQueue(label: "com.vkturnproxy.routingdiag.logger")

    static func log(_ message: String) {
        // Tier 1: os_log (Console.app).
        os_log("%{public}s", log: osLog, type: .default, message)
        // Tier 2: NSLog (covered by sysdiagnose).
        NSLog("[RoutingDiag] %@", message)
        // Tier 3: file in shared container.
        queue.async {
            appendToFile(message)
        }
    }

    /// Overwrite the log file (start of a fresh test run).
    static func reset() {
        queue.sync {
            if let url = fileURL() {
                try? FileManager.default.removeItem(at: url)
            }
        }
        // Always log the reset via os_log/NSLog so we can confirm
        // the extension did boot even if the file tier is dead.
        log("=== log reset ===")
        if let url = fileURL() {
            log("log file path: \(url.path)")
        } else {
            log("WARNING: App Group '\(appGroupID)' container unavailable — file tier disabled")
        }
    }

    // MARK: - Private

    private static func fileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(fileName)
    }

    private static func appendToFile(_ message: String) {
        guard let url = fileURL() else { return }
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // File doesn't exist yet — create it.
            try? data.write(to: url, options: .atomic)
        }
    }
}
