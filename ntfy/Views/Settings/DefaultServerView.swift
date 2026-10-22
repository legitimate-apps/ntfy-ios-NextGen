//
//  DefaultServerView.swift
//  ntfy
//
//  Created by Alek Michelson on 4/10/26.
//

import SwiftUI

struct DefaultServerView: View {
    @EnvironmentObject private var store: Store
    @FetchRequest(sortDescriptors: []) var prefs: FetchedResults<Preference>
    @State private var showDialog = false
    @State private var newDefaultBaseUrl: String = ""
    
    private var defaultBaseUrl: String {
        prefs
            .filter { $0.key == Store.prefKeyDefaultBaseUrl }
            .first?
            .value ?? Config.appBaseUrl
    }
    
    var body: some View {
        Button(action: {
            if defaultBaseUrl == Config.appBaseUrl {
                newDefaultBaseUrl = ""
            } else {
                newDefaultBaseUrl = defaultBaseUrl
            }
            showDialog = true
        }) {
            let _ = newDefaultBaseUrl
            ValueRow(String(localized: "Default server"), value: shortUrl(url: defaultBaseUrl))
                .contentShape(Rectangle())
        }
        .sheet(isPresented: $showDialog) {
            NavigationView {
                Form {
                    Section(
                        footer: ServerFooterText(text: Config.defaultServerFooter(baseUrl: newDefaultBaseUrl))
                            .fixedSize(horizontal: false, vertical: true)
                    ) {
                        HStack {
                            TextField(Config.appBaseUrl, text: $newDefaultBaseUrl)
                                .disableAutocapitalization()
                                .disableAutocorrection(true)
                                .accessibilityLabel(String(localized: "Default server"))
                            if !newDefaultBaseUrl.isEmpty {
                                Button {
                                    newDefaultBaseUrl = ""
                                } label: {
                                    Image(systemName: "clear.fill")
                                }
                                .accessibilityLabel(String(localized: "Clear default server"))
                            }
                        }
                    }
                }
                .navigationTitle(String(localized: "Default server"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(action: cancelAction) {
                            Text(String(localized: "Cancel"))
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: saveAction) {
                            Text(String(localized: "Save"))
                        }
                        .disabled(!isValid())
                    }
                }
            }
        }
    }
    
    private func saveAction() {
        if newDefaultBaseUrl == "" {
            store.saveDefaultBaseUrl(baseUrl: nil)
        } else {
            store.saveDefaultBaseUrl(baseUrl: normalizeBaseUrl(newDefaultBaseUrl))
        }
        resetAndHide()
    }
    
    private func cancelAction() {
        resetAndHide()
    }
    
    private func isValid() -> Bool {
        if !newDefaultBaseUrl.isEmpty && newDefaultBaseUrl.range(of: "^https?://.+", options: .regularExpression, range: nil, locale: nil) == nil {
            return false
        }
        return true
    }
    
    private func resetAndHide() {
        showDialog = false
    }
}
