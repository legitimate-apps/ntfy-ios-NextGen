import SwiftUI

/// Defers building a view until it is actually rendered.
///
/// `NavigationLink(destination:)` evaluates its destination expression while the *row* is being
/// built, not when the user navigates. For the subscription list that meant constructing a
/// `NotificationListView` for every visible row — and its initializer builds a
/// `NotificationsObservable`, which synchronously fetches and materializes that topic's entire
/// notification history. Every row loaded a full history for a screen nobody had opened, which is
/// precisely the per-row N×M work the row aggregates exist to remove.
///
/// Wrapping the destination moves that construction to the point the destination is really needed:
/// `body` is not evaluated until the view is rendered, i.e. on push.
struct LazyView<Content: View>: View {
    private let build: () -> Content

    init(_ build: @autoclosure @escaping () -> Content) {
        self.build = build
    }

    var body: Content {
        build()
    }
}
