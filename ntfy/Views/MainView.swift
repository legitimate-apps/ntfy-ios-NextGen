import Foundation
import SwiftUI
import UIKit

struct MainView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var delegate: AppDelegate
    @State private var linkRequest: LinkRequest?

    private struct LinkRequest: Identifiable {
        let id = UUID()
        let route: TopicLinkRoute
    }

    var body: some View {
        TabView {
            SubscriptionListView(linkRoute: linkRequest?.route)
                .tabItem {
                    Image(systemName: "message.fill")
                    Text(String(localized: "Notifications"))
                }
            SettingsView()
                .tabItem {
                    Image(systemName: "gearshape.fill")
                    Text(String(localized: "Settings"))
                }
        }
        // A new link returns to Notifications and discards navigation and sheet state belonging
        // to the previous destination, including sheets presented from Settings or a message.
        .id(linkRequest?.id)
        // SwiftUI delivers Universal Links as URLs, including on a cold launch.
        .onOpenURL(perform: openTopicLink)
        .onChange(of: delegate.selectedBaseUrl) { _ in openSelectedTopic() }
        .onAppear(perform: openSelectedTopic)
    }

    private func openTopicLink(_ url: URL) {
        guard let route = TopicLinkRoute.resolve(url, subscriptionURLs: (store.getSubscriptions() ?? []).map { $0.urlString() }) else { return }
        present(route)
    }

    private func openSelectedTopic() {
        guard let url = delegate.selectedBaseUrl else { return }
        // Consume the request even if its subscription was removed. Nothing should fire later
        // when a row appears, and another tap on the same topic must be a new request.
        delegate.selectedBaseUrl = nil
        guard (store.getSubscriptions() ?? []).contains(where: { $0.urlString() == url }) else { return }
        present(.open(url))
    }

    private func present(_ route: TopicLinkRoute) {
        let request = LinkRequest(route: route)
        let present = {
            delegate.selectedBaseUrl = nil
            LaunchExperience.shared.showingWhatsNew = false
            linkRequest = request
        }
        // SwiftUI cannot present Add while a previous sheet is still dismissing. Wait for the
        // actual dismissal completion instead of guessing an animation delay, on cold or warm launch.
        let root = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }.first { $0.isKeyWindow }?.rootViewController
        if let root, root.presentedViewController != nil {
            root.dismiss(animated: true, completion: present)
        } else {
            present()
        }
    }
}

struct MainView_Previews: PreviewProvider {
    static var previews: some View {
        let store = Store.preview // Store.previewEmpty
        MainView()
            .environment(\.managedObjectContext, store.context)
            .environmentObject(store)
            .environmentObject(AppDelegate())
    }
}
