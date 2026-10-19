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
                    Text("Notifications")
                }
            SettingsView()
                .tabItem {
                    Image(systemName: "gearshape.fill")
                    Text("Settings")
                }
        }
        // A new link returns to Notifications and discards navigation and sheet state belonging
        // to the previous destination, including sheets presented from Settings or a message.
        .id(linkRequest?.id)
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            guard let url = activity.webpageURL else { return }
            openTopicLink(url)
        }
    }

    private func openTopicLink(_ url: URL) {
        guard let route = TopicLinkRoute.resolve(url, subscriptionURLs: (store.getSubscriptions() ?? []).map { $0.urlString() }) else { return }
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
