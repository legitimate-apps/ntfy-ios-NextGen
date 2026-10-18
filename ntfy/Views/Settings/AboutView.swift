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
            ValueRow("Version", value: "ntfy \(Config.version) (\(Config.build))")
        }
        .foregroundColor(.primary)
    }

    // One builder rather than four near-identical blocks. The bug this replaces
    // was a wrong literal in one of those blocks — "Rate the app" opened
    // upstream's App Store listing — which is exactly the mistake that hides in
    // copy-pasted rows. Every URL now comes from Config.
    private func linkRow(_ title: String, detail: String, icon: String, url: String) -> some View {
        Button(action: { open(url: url) }) {
            ValueRow(title, value: detail) {
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

/// A settings row with a title and a grey value. Side by side, both broke mid-word at the
/// accessibility text sizes ("Ver-sion", "ntfy-/me.-/com"), so there the value goes under the
/// title, the way iOS Settings lays it out.
struct ValueRow<Accessory: View>: View {
    @Environment(\.sizeCategory) private var sizeCategory
    let title: String
    let value: String
    let accessory: Accessory

    init(_ title: String, value: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.value = value
        self.accessory = accessory()
    }

    var body: some View {
        HStack {
            if sizeCategory.isAccessibilityCategory {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .foregroundColor(.primary)
                    Text(value)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                Text(title)
                    .foregroundColor(.primary)
                Spacer()
                Text(value)
                    .foregroundColor(.secondary)
            }
            accessory
        }
    }
}

extension ValueRow where Accessory == EmptyView {
    init(_ title: String, value: String) {
        self.init(title, value: value) { EmptyView() }
    }
}
