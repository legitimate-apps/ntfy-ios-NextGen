import SwiftUI
import Firebase

// TODO: Errors are not shown to the user, but instead just logged

@main
struct AppMain: App {
    private let tag = "AppMain"
    
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate: AppDelegate
    @StateObject private var store = Store.shared

    init() {
        Log.d(tag, "Launching ntfy 🥳. Welcome!")
        Log.d(tag, "Base URL is \(Config.appBaseUrl), user agent is \(ApiService.userAgent)")
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(delegate)
                .environment(\.managedObjectContext, store.context)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    // Use this hook instead of applicationDidBecomeActive, see https://stackoverflow.com/a/68888509/1440785
                    // That post also explains how to start SwiftUI from AppDelegate if that's ever needed.
                    
                    Log.d(tag, "App became active, refreshing objects")
                    store.hardRefresh()
                    // Open encrypted messages that arrived while the key couldn't be read (before
                    // first unlock, a Keychain hiccup, or a key the extension couldn't derive).
                    store.retryLockedMessages()
                    delegate.refreshNotificationSettings()
                    // Self-heal a desynced device (ntfy#1305). Before this, a
                    // topic whose FCM binding failed stayed dead until the user
                    // reinstalled the app — which is exactly what the upstream
                    // thread reports as the only known workaround.
                    FcmSubscriptionReconciler.shared.reconcile(reason: "app became active")
                }
        }
    }
}
