import UIKit
import SafariServices
import UserNotifications
import Firebase
import FirebaseCore
import FirebaseMessaging
import CoreData

/// When the app asks iOS for notification permission.
///
/// Apple's HIG: ask in context, and when the reason isn't obvious, explain it first on your own
/// screen. A fresh install used to get the system prompt at launch; now it waits for the first
/// subscribe, which is the moment a notification permission makes sense to the user.
enum NotificationPermissionPolicy {
    /// At launch, ask directly only if iOS would not show a prompt anyway (already decided), or if
    /// the user has topics from before this flow existed and was never offered the explanation
    /// screen. Someone who saw it and chose "Not now" (or swiped it away) keeps the in-context path:
    /// a cold prompt on their next launch would undo exactly the choice they just made.
    static func shouldRequestAtLaunch(status: UNAuthorizationStatus, hasSubscriptions: Bool,
                                      primerOffered: Bool) -> Bool {
        status != .notDetermined || (hasSubscriptions && !primerOffered)
    }

    private static let primerOfferedKey = "notificationPermissionPrimerOffered"

    /// Whether this install has shown the explanation screen. Set when it appears, not on a button,
    /// so dismissing the sheet counts the same as "Not now".
    static func primerOffered(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: primerOfferedKey)
    }

    static func recordPrimerOffered(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: primerOfferedKey)
    }

    /// Show the explanation screen only when the system prompt would actually follow it.
    static func shouldPrime(status: UNAuthorizationStatus) -> Bool {
        status == .notDetermined
    }
}

class AppDelegate: UIResponder, UIApplicationDelegate, ObservableObject {
    private let tag = "AppDelegate"
    // Single source of truth lives with the reconciler, which is what subscribes to it.
    private let pollTopic = FcmSubscriptionReconciler.pollTopic
    
    // Implements navigation from notifications, see https://stackoverflow.com/a/70731861/1440785
    @Published var selectedBaseUrl: String? = nil
    @Published private(set) var criticalAlertSetting: UNNotificationSetting = .notSupported

    /// Taps the extension received in the app's place (on a Mac), and the guard that runs each tap once.
    private let responseRelay = NotificationResponseRelay(defaults: UserDefaults(suiteName: Store.appGroup) ?? .standard)
    private var responseDeduper = NotificationResponseDeduper()
    private var relayActivationObserver: NSObjectProtocol?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Log.d(tag, "Launching AppDelegate")

        // When the app is launched only as the unit-test host, skip Firebase +
        // remote-notification registration: they crash the test runner during
        // bootstrap and aren't needed for logic tests. XCTestCase is only present
        // when XCTest.framework is loaded (test runs), never in a shipped build.
        if NSClassFromString("XCTestCase") != nil {
            return true
        }

        // Lift any password still sitting in the Core Data store into the Keychain and blank the
        // column. Idempotent and cheap — stores written by this build already have none.
        Store.shared.migrateCredentialsToKeychain()

        FirebaseApp.configure()
        FirebaseConfiguration.shared.setLoggerLevel(.max)

        // Move topics off the private server 1.12/1.13 shipped as the built-in default (they get 403
        // there). Once only; after Firebase is configured because a move tears down old FCM names.
        RetiredDefaultServerMigration.runIfNeeded(
            store: Store.shared,
            defaults: UserDefaults(suiteName: Store.appGroup) ?? .standard,
            reconciler: FcmSubscriptionReconciler.shared
        )

        // Register app permissions for push notifications
        UNUserNotificationCenter.current().delegate = self
        Messaging.messaging().delegate = self
        requestStandardNotificationAuthorizationIfAppropriate()
        refreshNotificationSettings()
        
        // Register too receive remote notifications
        application.registerForRemoteNotifications()

        startBadgeSync()
        observeRelayedNotificationResponses()

        return true
    }

    // MARK: Banner taps relayed by the extension

    /// On a Mac the system can hand a banner tap to the extension instead of the app (see
    /// `NotificationResponseRelay`). Pick those up at launch, whenever the app becomes active (the
    /// system brings it forward for the tap) and when the extension says it queued one.
    private func observeRelayedNotificationResponses() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { delegate.handleRelayedNotificationResponses() }
            },
            NotificationResponseRelay.darwinNotificationName as CFString,
            nil,
            .deliverImmediately
        )
        relayActivationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleRelayedNotificationResponses()
        }
        handleRelayedNotificationResponses()
    }

    private func handleRelayedNotificationResponses() {
        for relayed in responseRelay.drain() {
            Log.d(tag, "Handling a notification response relayed by the extension", relayed.actionIdentifier)
            handleNotificationResponse(
                userInfo: relayed.userInfo,
                actionIdentifier: relayed.actionIdentifier,
                notificationId: relayed.notificationId
            )
        }
    }

    // MARK: App icon badge

    private var badgeObservers: [NSObjectProtocol] = []

    /// Keeps the app icon badge in step with the number of unread notifications (ntfy#1462).
    ///
    /// Delivery pushes the badge *up* from the notification payload itself
    /// (`UNMutableNotificationContent.modify`) — that is the only thing that can move it while the
    /// app isn't running. This covers everything else: the moment the user reads, swipes, deletes
    /// or unsubscribes, the icon has to come back down, and on returning to the foreground the app
    /// has to absorb whatever the notification service extension wrote in its own process while we
    /// were away.
    private func startBadgeSync() {
        let center = NotificationCenter.default
        let refresh: (Foundation.Notification) -> Void = { [weak self] _ in self?.refreshAppIconBadge() }
        badgeObservers = [
            // Every in-app mutation: read/unread toggles, opening a topic, deletes, unsubscribes.
            center.addObserver(forName: .NSManagedObjectContextDidSave, object: Store.shared.context,
                               queue: .main, using: refresh),
            // A write from the notification service extension's process.
            center.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil,
                               queue: .main, using: refresh),
            // Returning to the foreground, where neither of the above is guaranteed to have reached us.
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                               queue: .main, using: refresh),
        ]
        refreshAppIconBadge()
    }

    private func refreshAppIconBadge() {
        let count = Store.shared.totalUnreadCount()
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(count) { error in
                if let error = error {
                    Log.w(self.tag, "Cannot set app icon badge", error)
                }
            }
        } else {
            UIApplication.shared.applicationIconBadgeNumber = count
        }
    }

    func refreshNotificationSettings(completion: (() -> Void)? = nil) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let isAuthorized = settings.criticalAlertSetting == .enabled
            DispatchQueue.main.async {
                self.criticalAlertSetting = settings.criticalAlertSetting
                Store.saveCriticalAlertsAuthorized(isAuthorized)
                completion?()
            }
        }
    }

    func requestCriticalAlertsAuthorization(completion: @escaping (Bool) -> Void) {
        if criticalAlertSetting == .enabled {
            completion(true)
            return
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound, .criticalAlert]) { success, error in
            if let error {
                Log.e(self.tag, "Failed to register for critical alerts", error)
            } else if success {
                Log.d(self.tag, "Successfully requested critical alerts")
            }

            self.refreshNotificationSettings {
                completion(self.criticalAlertSetting == .enabled)
            }
        }
    }

    // TODO: Needs to be tested on multiple devices/iOS versions
    func openNotificationSettings() {
        let settingsURLString: String
        #if targetEnvironment(simulator)
        settingsURLString = UIApplication.openSettingsURLString
        #else
        if #available(iOS 16.0, *) {
            settingsURLString = UIApplication.openNotificationSettingsURLString
        } else if #available(iOS 15.4, *) {
            settingsURLString = UIApplicationOpenNotificationSettingsURLString
        } else {
            settingsURLString = UIApplication.openSettingsURLString
        }
        #endif
        guard let url = URL(string: settingsURLString) else {
            return
        }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    /// Launch-time permission request, skipped on a fresh install. A cold system prompt before the
    /// user has done anything gives them no reason to say yes; the add-topic screen asks instead,
    /// after the first subscribe, with a short explanation first (see `NotificationPermissionPolicy`).
    private func requestStandardNotificationAuthorizationIfAppropriate() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                let hasSubscriptions = !(Store.shared.getSubscriptions() ?? []).isEmpty
                if NotificationPermissionPolicy.shouldRequestAtLaunch(
                    status: settings.authorizationStatus,
                    hasSubscriptions: hasSubscriptions,
                    primerOffered: NotificationPermissionPolicy.primerOffered()
                ) {
                    self.requestStandardNotificationAuthorization()
                }
            }
        }
    }

    func notificationAuthorizationStatus(completion: @escaping (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { completion(settings.authorizationStatus) }
        }
    }

    func requestStandardNotificationAuthorization(completion: (() -> Void)? = nil) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { success, error in
            if success {
                Log.d(self.tag, "Successfully registered for local push notifications")
            } else {
                Log.e(self.tag, "Failed to register for local push notifications", error)
            }
            DispatchQueue.main.async { completion?() }
        }
    }
    
    /// Executed when a background notification arrives on the "~poll" topic. This is used to trigger polling of local topics.
    /// See https://developer.apple.com/documentation/usernotifications/setting_up_a_remote_notification_server/pushing_background_updates_to_your_app
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Log.d(tag, "Background notification received", userInfo)
        
        var wakeManager = SubscriptionManager(store: Store.shared)
        wakeManager.fetch = { ApiService.shared.poll($0, timeout: 8, completionHandler: $1) }
        if wakeManager.handleSilentWake(userInfo: userInfo, completion: { succeeded in
            completionHandler(succeeded ? .newData : .failed)
        }) { return }

        if let message = Message.from(userInfo: userInfo), message.isControl {
            let baseUrl = userInfo["base_url"] as? String ?? Config.appBaseUrl
            let result = Store.shared.ingest(pushedMessage: message, baseUrl: baseUrl, topic: message.topic)
            if case .reconcile(let request) = result {
                ApiService.shared.poll(request, timeout: 8) { messages, _ in
                    guard let messages else { completionHandler(.failed); return }
                    let presentations = Store.shared.save(notificationsFromMessages: messages, polledWith: request) ?? []
                    self.showNotificationsSequentially(baseUrl: baseUrl, messages: presentations) {
                        completionHandler(.newData)
                    }
                }
            } else {
                completionHandler(result == nil ? .noData : .newData)
            }
            return
        }

        // Exit out early if this message is not expected
        let topic = userInfo["topic"] as? String ?? ""
        if topic != pollTopic {
            completionHandler(.noData)
            return
        }

        // Poll and show new messages as notifications
        let store = Store.shared
        let subscriptionManager = SubscriptionManager(store: store)
        let subscriptions = store.getSubscriptions() ?? []
        guard !subscriptions.isEmpty else {
            completionHandler(.noData)
            return
        }

        let group = DispatchGroup()
        let resultQueue = DispatchQueue(label: Config.bundleIdBase + ".background-poll-result")
        var didReceiveNewData = false
        subscriptions.forEach { subscription in
            group.enter()
            guard let baseUrl = subscription.baseUrl else {
                Log.w(tag, "Skipping background poll notification for subscription with missing baseUrl")
                group.leave()
                return
            }
            subscriptionManager.poll(subscription) { messages in
                if !messages.isEmpty {
                    resultQueue.sync {
                        didReceiveNewData = true
                    }
                }
                self.showNotificationsSequentially(baseUrl: baseUrl, messages: messages) {
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            completionHandler(didReceiveNewData ? .newData : .noData)
        }
    }
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { data in String(format: "%02.2hhx", data) }.joined()
        Messaging.messaging().apnsToken = deviceToken
        Log.d(tag, "Registered for remote notifications. Passing APNs token \(token.prefix(12))... to Firebase")
        // FCM topic binding only works once this token is associated, and this
        // callback frequently lands *after* the FCM token did. Reconciling here
        // means whichever of the two arrives second completes the round —
        // previously the earlier one just failed silently for every topic.
        FcmSubscriptionReconciler.shared.reconcile(reason: "APNs token registered")
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Log.e(tag, "Failed to register for remote notifications", error)
    }
    
    /// Create a local notification manually (as opposed to a remote notification being generated by Firebase). We need to make the
    /// local notification look exactly like the remote one (same userInfo), so that when we tap it, the userNotificationCenter(didReceive) function
    /// has the same information available.
    private func showNotification(_ subscription: Subscription, _ message: Message, completionHandler: (() -> Void)? = nil) {
        guard let baseUrl = subscription.baseUrl else {
            Log.w(tag, "Skipping notification for subscription with missing baseUrl")
            completionHandler?()
            return
        }
        showNotification(baseUrl: baseUrl, message, completionHandler: completionHandler)
    }

    private func showNotification(baseUrl: String, _ message: Message, completionHandler: (() -> Void)? = nil) {
        let user = Store.shared.getBasicUser(baseUrl: baseUrl)
        let displayName = Store.shared.subscriptionDisplayName(baseUrl: baseUrl, topic: message.topic)
        Store.shared.recordPresentation(message: message, baseUrl: baseUrl)
        let content = UNMutableNotificationContent()
        content.modify(message: message, baseUrl: baseUrl, displayName: displayName)
        content.attachImageIfNeeded(message: message, baseUrl: baseUrl, user: user) {
            let request = UNNotificationRequest(identifier: message.id, content: content, trigger: nil /* now */)
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    Log.e(self.tag, "Unable to create notification", error)
                }
                completionHandler?()
            }
        }
    }

    private func showNotificationsSequentially(baseUrl: String, messages: [Message], completionHandler: @escaping () -> Void) {
        guard let firstMessage = messages.first else {
            completionHandler()
            return
        }

        showNotification(baseUrl: baseUrl, firstMessage) {
            self.showNotificationsSequentially(
                baseUrl: baseUrl,
                messages: Array(messages.dropFirst()),
                completionHandler: completionHandler
            )
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Executed when the app is in the foreground. Nothing has to be done here, except call the completionHandler.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        Log.d(tag, "Notification received via userNotificationCenter(willPresent)", userInfo)
        var wakeManager = SubscriptionManager(store: Store.shared)
        wakeManager.fetch = { ApiService.shared.poll($0, timeout: 8, completionHandler: $1) }
        if wakeManager.handleSilentWake(userInfo: userInfo, completion: { _ in }) {
            completionHandler([])
            return
        }
        if let message = Message.from(userInfo: userInfo) {
            let baseUrl = userInfo["base_url"] as? String ?? Config.appBaseUrl
            if message.isControl {
                let result = Store.shared.ingest(pushedMessage: message, baseUrl: baseUrl, topic: message.topic)
                if case .reconcile(let request) = result {
                    ApiService.shared.poll(request, timeout: 8) { messages, _ in
                        if let messages { _ = Store.shared.save(notificationsFromMessages: messages, polledWith: request) }
                    }
                }
                completionHandler([])
                return
            }
        }
        completionHandler(notification.request.content.sound == nil ? [.list] : [.banner, .sound])
    }
    
    /// Executed when the user clicks on the notification.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        Log.d(tag, "Notification received via userNotificationCenter(didReceive)", userInfo)
        handleNotificationResponse(
            userInfo: userInfo,
            actionIdentifier: response.actionIdentifier,
            notificationId: response.notification.request.identifier,
            completionHandler: completionHandler
        )
    }

    /// Acts on a tap (the body, a button, or a dismiss), whether the app's own delegate received it
    /// or the extension relayed it. Each tap runs once.
    func handleNotificationResponse(
        userInfo: [AnyHashable: Any],
        actionIdentifier: String,
        notificationId: String,
        completionHandler: @escaping () -> Void = {}
    ) {
        guard responseDeduper.shouldHandle(notificationId: notificationId, actionIdentifier: actionIdentifier) else {
            Log.d(tag, "Ignoring a notification response that was already handled", actionIdentifier)
            completionHandler()
            return
        }
        guard let message = Message.from(userInfo: userInfo) else {
            Log.w(tag, "Cannot convert userInfo to message", userInfo)
            completionHandler()
            return
        }
        
        let baseUrl = userInfo["base_url"] as? String ?? Config.appBaseUrl
        if actionIdentifier == UNNotificationDismissActionIdentifier {
            Store.shared.read(message: message, baseUrl: baseUrl, completion: completionHandler)
            return
        }
        Store.shared.read(message: message, baseUrl: baseUrl)
        let action = message.actions?.first { $0.id == actionIdentifier }
        
        // Show current topic
        if message.topic != "" {
            selectedBaseUrl = topicUrl(baseUrl: baseUrl, topic: message.topic)
        }
        
        // Execute user action or click action (if any)
        if let action = action {
            ActionExecutor.execute(
                action,
                notificationId: notificationId,
                baseUrl: baseUrl
            )
        } else if let click = message.click, click != "", let url = URL(string: click) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    
        completionHandler()
    }
}

extension AppDelegate: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        if let fcmToken = fcmToken, !fcmToken.isEmpty {
            Log.d(tag, "Firebase token received: \(fcmToken.prefix(12))...")
        } else {
            Log.w(tag, "Firebase token missing")
        }

        // A rotated token voids every existing topic binding, so record it first
        // (that marks all subscriptions stale) and then rebuild them. This used
        // to be a single best-effort re-subscribe loop that swallowed every
        // error, which is why a rotation could silently kill push forever —
        // ntfy#1305. Reconciling is retryable and idempotent; if the APNs token
        // has not landed yet this no-ops and the APNs callback re-drives it.
        // A changed token drives its own rebuild inside noteRegistrationToken — the invalidation and
        // the round that acts on it belong together, so it does not depend on callers remembering.
        // An *unchanged* token invalidates nothing, but this callback is still a repair trigger, so
        // reconcile explicitly in that case.
        if !FcmSubscriptionReconciler.shared.noteRegistrationToken(fcmToken) {
            FcmSubscriptionReconciler.shared.reconcile(reason: "FCM registration token")
        }
    }
}
