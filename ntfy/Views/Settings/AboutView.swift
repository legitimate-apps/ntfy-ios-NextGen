//
//  AboutView.swift
//  ntfy
//
//  Created by Alek Michelson on 4/10/26.
//

import SwiftUI

struct AboutView: View {
    var body: some View {
        Group {
            // Primary help is the default server's quick start: its examples publish to ntfy-me.com.
            // ntfy's own docs stay as the full protocol reference, labelled as such.
            linkRow("Getting started", detail: shortUrl(url: normalizeBaseUrl(Config.helpUrl)), icon: "questionmark.circle",
                    url: Config.helpUrl)
            linkRow("ntfy reference docs", detail: "ntfy.sh/docs", icon: "book", url: Config.docsUrl)
            // The support page explains how to reach us.
            linkRow("Get help or report a bug", detail: "ntfy NextGen support", icon: "lifepreserver",
                    url: Config.supportUrl)
            // Only a build with an App Store id (APP_STORE_ID) has a listing to rate.
            if let reviewUrl = Config.reviewUrl {
                linkRow("Rate the app", detail: "App Store", icon: "star.fill", url: reviewUrl)
            }
            NavigationLink("Licenses") { LicensesView() }
            HStack {
                Text("Version")
                Spacer()
                Text("ntfy \(Config.version) (\(Config.build))")
                    .foregroundColor(.gray)
            }
        }
        .foregroundColor(.primary)
    }

    // One builder rather than four near-identical blocks. The bug this replaces
    // was a wrong literal in one of those blocks — "Rate the app" opened
    // upstream's App Store listing — which is exactly the mistake that hides in
    // copy-pasted rows. Every URL now comes from Config.
    private func linkRow(_ title: String, detail: String, icon: String, url: String) -> some View {
        Button(action: { open(url: url) }) {
            HStack {
                Text(title)
                Spacer()
                Text(detail)
                    .foregroundColor(.gray)
                Image(systemName: icon)
                    .accessibilityHidden(true)   // decorative; the title already names the action
            }
        }
    }

    private func open(url: String) {
        guard let url = URL(string: url) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}
