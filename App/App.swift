//
//  App.swift
//  RoutingDiag
//
//  SwiftUI entry point.
//

import SwiftUI

@main
struct RoutingDiagApp: App {
    @StateObject private var tunnel = TunnelManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(tunnel)
        }
    }
}
