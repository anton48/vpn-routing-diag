//
//  SharedLogger.swift
//  RoutingDiag / Extension
//
//  Appends log lines to a single file in the shared App Group
//  container so the main app can read them back.
//

import Foundation
import os.log

enum SharedLogger {

    private static let appGroupID = "group.net.vpnroutingdiag.shared"
    private static let fileName = "routing.log"
    private static let osLog = OSLog(subsystem: "net.vpnroutingdiag.tunnel",
                                     category: "routing")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let queue = DispatchQueue(label: "net.vpnroutingdiag.logger")

    static func log(_ message: String) {
        // 1. os_log so it's visible in Console.app while a device is
        //    connected to a Mac — useful for live debugging.
        os_log("%{public}s", log: osLog, type: .default, message)

        // 2. File in shared container so the main app can pull it.
        queue.async {
            appendToFile(message)
        }
    }

    /// Overwrite the log file (start of a fresh test run).
    static func reset() {
        guard let url = fileURL() else { return }
        queue.sync {
            try? FileManager.default.removeItem(at: url)
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
            // File doesn't exist — create it.
            try? data.write(to: url, options: .atomic)
        }
    }
}
