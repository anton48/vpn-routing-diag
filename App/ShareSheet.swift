//
//  ShareSheet.swift
//  RoutingDiag
//
//  SwiftUI wrapper around UIActivityViewController so the routing
//  log file can be exported out of the app (e.g. "Save to Files",
//  "Mail", "AirDrop"). SwiftUI's native share menus don't surface
//  file-type activities cleanly across iOS 15+.
//

import SwiftUI
import UIKit

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items,
                                          applicationActivities: nil)
        // Exclude activities that make no sense for a text log dump.
        vc.excludedActivityTypes = [
            .assignToContact,
            .addToReadingList,
            .postToFlickr,
            .postToVimeo,
            .postToFacebook,
            .postToTwitter,
            .postToWeibo,
            .postToTencentWeibo,
            .openInIBooks,
        ]
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController,
                                context: Context) {}
}
