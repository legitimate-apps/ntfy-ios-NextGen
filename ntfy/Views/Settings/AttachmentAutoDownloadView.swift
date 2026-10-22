//
//  UserEditorView.swift
//  ntfy
//
//  Created by Alek Michelson on 5/18/26.
//

import SwiftUI

private struct AttachmentAutoDownloadOption: Identifiable {
    let value: Int64
    let title: String

    var id: Int64 { value }
}

struct AttachmentAutoDownloadView: View {
    @EnvironmentObject private var store: Store
    @FetchRequest(sortDescriptors: []) private var prefs: FetchedResults<Preference>
    @State private var showingOptions = false

    private var currentValue: Int64 {
        prefs
            .first { $0.key == Store.prefKeyAttachmentAutoDownloadMaxSize }?
            .value
            .flatMap(Int64.init) ?? Store.autoDownloadDefault
    }

    var body: some View {
        Button {
            showingOptions = true
        } label: {
            ValueRow(String(localized: "Download attachments"), value: title(for: currentValue))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .confirmationDialog("Download attachments", isPresented: $showingOptions, titleVisibility: .visible) {
            ForEach(options) { option in
                Button {
                    store.saveAttachmentAutoDownloadMaxSize(option.value)
                } label: {
                    Text(option.title)
                }
            }

            Button(String(localized: "Cancel"), role: .cancel) {}
        }
    }

    private var options: [AttachmentAutoDownloadOption] {
        [
            .init(value: Store.autoDownloadNever, title: String(localized: "Never")),
            .init(value: Store.autoDownloadAlways, title: String(localized: "Always")),
            .init(value: Store.autoDownload100KB, title: String(localized: "Under 100 KB")),
            .init(value: Store.autoDownload500KB, title: String(localized: "Under 500 KB")),
            .init(value: Store.autoDownloadDefault, title: String(localized: "Under 1 MB")),
            .init(value: Store.autoDownload5MB, title: String(localized: "Under 5 MB")),
            .init(value: Store.autoDownload10MB, title: String(localized: "Under 10 MB")),
            .init(value: Store.autoDownload50MB, title: String(localized: "Under 50 MB"))
        ]
    }

    private func title(for value: Int64) -> String {
        options.first(where: { $0.value == value })?.title ?? String(localized: "Under 1 MB")
    }
}
