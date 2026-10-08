import SwiftUI

/// Lets the user order the subscription list by name or by most recent activity (ntfy#1740).
///
/// Defaults to name so an existing install's list does not silently rearrange itself on upgrade —
/// the order people already have is the one they navigate by.
struct TopicSortOrderView: View {
    @EnvironmentObject private var store: Store
    @State private var order: Store.TopicSortOrder = .default

    var body: some View {
        Picker("Sort topics by", selection: $order) {
            Text("Name").tag(Store.TopicSortOrder.name)
            Text("Recent activity").tag(Store.TopicSortOrder.recentActivity)
        }
        .onAppear {
            // Read on appear rather than in an initializer: the store is an @EnvironmentObject and
            // is not available until the view is in the hierarchy.
            order = store.getTopicSortOrder()
        }
        .onChange(of: order) { newValue in
            guard newValue != store.getTopicSortOrder() else { return }
            store.saveTopicSortOrder(newValue)
            // The list is driven by SubscriptionsObservable, which reads this preference when it
            // orders `subscriptions`. Saving alone changes no Core Data object it observes, so
            // nothing would tell it to re-publish. Its own signal, not the cross-process one — no
            // row moved, and every open topic would otherwise re-run its notification fetch.
            NotificationCenter.default.post(name: Store.topicSortOrderDidChange, object: nil)
        }
    }
}

struct TopicSortOrderView_Previews: PreviewProvider {
    static var previews: some View {
        let store = Store.preview
        return TopicSortOrderView()
            .environmentObject(store)
    }
}
