# Navigation integration regressions

These tests drive the installed SwiftUI app from a standalone XCTest UI runner. They require Xcode and Python 3, and do not add an app dependency or alter the app's build settings. Use a dedicated leased simulator with fixture data only. The runner deployment target is iOS 16.4 because `XCUIApplication.open(URL)` was introduced then; the app still supports iOS 15.

Build the app normally, with simulator signing enabled. Supply your usual ignored `Configuration/Local.xcconfig` if testing a deployed association. Then run:

```sh
python3 ntfyNavigationUITests/run.py "$UDID" "$APP_PATH" "$UI_DERIVED_DATA" "$EVIDENCE_DIRECTORY" --seed
```

All paths may contain spaces. The script reads identity from the built app, compiles a private simulator notification fixture, installs that app, and seeds its app-group SQLite store with 61 subscriptions. The first 60 use an unreachable loopback endpoint and have synthetic read messages with ascending times. The first is pinned; the other 59 reverse order under Recent activity. The last uses `https://ntfy-me.com/zz-nav-118-regression`. The default server differs from the link server. This creates no server-side subscriptions or publishes. The app may make its ordinary polling requests. `--seed` replaces the dedicated simulator's subscriptions and notifications. Omit it to preserve the existing fixture. Re-seed with `--sort recentActivity` to repeat the suite under the other sort order. `--only testMethodName` selects a test and can be repeated.

URL tests use XCTest's `XCUIApplication.open(URL)`. This is system URL delivery into the real SwiftUI scene and `onOpenURL`, without calling the router or continuation method. Because XCTest explicitly names the app, this alone does **not** prove domain association. Separately check the simulator's swcd registration and open the URL with `xcrun simctl openurl "$UDID" https://ntfy-me.com/zz-nav-118-new`. An association failure that opens Safari is distinct from a routing failure after iOS delivers the URL.

`NotificationHarness.m` is a simulator-only dynamically injected library, never linked into or shipped with the app. It creates notification content and calls the installed app's real `UNUserNotificationCenterDelegate` response callback, which calls `handleNotificationResponse`. It does not set the selected URL or invoke a view/router. Cold delivery waits for the first activation; warm delivery uses a Darwin notification from the UI runner. The response wrapper supplies exactly the two properties the real delegate reads. This verifies the app's response-to-navigation path, not APNs, banner rendering, or an OS-generated `UNNotificationResponse`.

Assertions cover cold/warm URLs and responses, an off-screen destination, repeated taps, Subscribe confirmation and subsequent navigation, competing sheets and tabs, What's new, rejected URLs, Back and scrolling without stale navigation, manual row navigation, and returning to the list after Unsubscribe from either a manual or external destination. No new URL schemes, app test hooks, or continuation-method calls are used.

The mute regression can be selected with `--only testTopicMuteMenusPersistenceSwipeAndResume` after `--seed`. It uses the first pinned fixture topic and drives long press, all duration choices, restart persistence, swipe, the topic menu and Unmute. It attaches screenshots of the duration picker and the muted list/history. Repeat after `simctl ui <udid> appearance dark` and `simctl ui <udid> content_size accessibility-extra-extra-extra-large` for visual review; export and compress the attachments before inspecting them. Restore appearance/text size and re-seed between independent cases.

This response harness does not run the Notification Service Extension. `simctl push` on some simulator runtimes delivers the original APNs alert without starting the NSE; do not count that as NSE verification. Real local-message delivery can be exercised through a loopback ntfy server and the app's `~poll` background callback. Actual APNs/NSE launch and locked-device/Focus behavior still need device evidence when the runtime cannot execute the extension.

The fixture also includes a high-priority message, emoji tags, a local one-pixel image and a synthetic legacy login. The app migrates its fixture password into the dedicated simulator's Keychain; it is not a real server credential. Accessibility regressions require semantic labels for Add subscription, Topic actions, Message actions, High priority and Attachment actions. The capture tests attach text accessibility trees and screenshots for the list, menus, image viewer, add sheet, settings, saved user and editors, server headers and What's new. The existing navigation and mute assertions use the explicit Add subscription and Topic actions labels.

The capture traversal checks both sign-in choices, their selected state, and Username, Password and Access token field names. `testTopicQRControlsHaveSpokenNames` checks the topic QR image, Share, Done, Scan QR code and the no-camera scanner screen. The mute regression also attaches text trees for its menus, duration picker and muted status.

The empty-list capture runs separately because it needs a different fixture:

```sh
python3 ntfyNavigationUITests/run.py "$UDID" "$APP_PATH" "$UI_DERIVED_DATA" "$EVIDENCE_DIRECTORY" --seed --empty-fixture --only testAccessibilityEmptyList
```

For matched large-text captures, set `xcrun simctl ui "$UDID" content_size accessibility-extra-extra-extra-large` and repeat the capture tests. Use `appearance light` and `appearance dark` for the two appearances. Export attachments with `xcrun xcresulttool export attachments --path <result.xcresult> --output-path <directory>`. Shrink exported screenshots before viewing or sharing them.
