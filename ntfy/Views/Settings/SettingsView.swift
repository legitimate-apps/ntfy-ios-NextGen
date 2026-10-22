import Foundation
import SwiftUI
import StoreKit

struct SettingsView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var delegate: AppDelegate
    @State private var userDialog: UserDialog?
    
    var body: some View {
        NavigationView {
            Form {
                Section(
                    header: Text(String(localized: "General")),
                    footer: Text(String(localized: "When subscribing to new topics, this server will be used as a default."))
                ) {
                    DefaultServerView()
                    TopicSortOrderView()
                }
                Section(
                    header: Text(String(localized: "Notifications")),
                    footer: Text(String(localized: "Automatically download attachments up to the selected size. Attachments larger than this limit must be downloaded manually."))
                ) {
                    AttachmentAutoDownloadView()
                }
                NotificationStatusView()
                RetentionSettingsView(store: store)
                UrgentAlertsSettingView()
                Section(
                    header: Text(String(localized: "Users")),
                    footer: Text(String(localized: "Add or edit a password or access token for read-protected topics. All topics for a server use the same login."))
                ) {
                    UserTableView(dialog: $userDialog)
                }
                Section(
                    header: Text(String(localized: "Server headers")),
                    footer: Text(String(localized: "Add credentials required by Cloudflare Access or another reverse proxy. Values are stored in the Keychain."))
                ) {
                    NavigationLink(String(localized: "Custom HTTP headers")) {
                        ServerHeadersView(defaultBaseUrl: store.getDefaultBaseUrl())
                    }
                }
                Section(header: Text(String(localized: "About"))) {
                    AboutView()
                }
            }
            .navigationTitle(String(localized: "Settings"))
        }
        .sheet(item: $userDialog) { dialog in
            UserEditorView(
                selectedUser: dialog.user,
                onSave: { baseUrl, username, credential in
                    guard let credential else { return false }
                    let saved = store.saveUser(baseUrl: baseUrl, credential: credential)
                    if saved { userDialog = nil }
                    return saved
                },
                onDelete: { user in
                    let deleted = store.delete(user: user)
                    if deleted { userDialog = nil }
                    return deleted
                },
                onCancel: {
                    userDialog = nil
                }
            )
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        let store = Store.preview // Store.previewEmpty
        SettingsView()
            .environment(\.managedObjectContext, store.context)
            .environmentObject(store)
            .environmentObject(AppDelegate())
    }
}
