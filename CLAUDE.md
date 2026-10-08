# ntfy iOS NextGen

A community-maintained, **iOS-only** client for [ntfy](https://ntfy.sh), forked from
[binwiederhier/ntfy-ios](https://github.com/binwiederhier/ntfy-ios) (MIT). We actively
fix iOS bugs and extend the app. Originally by [@Copephobia](https://github.com/Copephobia);
upstream maintained by [Philipp C. Heckel](https://heckel.io).

## Architecture
- **SwiftUI app**, iOS 14 target (NSE 15). Entry: `ntfy/App/AppMain.swift` (`@main`) + `AppDelegate.swift`.
- **Views:** `ntfy/Views/` — `Subscriptions/`, `Notifications/`, `Settings/`.
- **Persistence:** `ntfy/Persistence/` — Core Data (`ntfy.xcdatamodeld`) via `Store.swift`; `Subscription.swift`, `SubscriptionManager.swift`, `SubscriptionsObservable.swift`.
- **NSE:** `ntfyNSE/` — Notification Service Extension for rich push; shares an App Group with the app.
- **Push:** Firebase iOS SDK (SPM) → FCM/APNs.

## Build (simulator, no signing needed)
```
xcodebuild -project ntfy.xcodeproj -scheme ntfy \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```
Resolve SPM deps: `xcodebuild -project ntfy.xcodeproj -scheme ntfy -resolvePackageDependencies`.
NSE target scheme: `ntfyNSE`. Run `./scripts/bootstrap.sh` once in a fresh clone.

## Build identity
Bundle ids, team, App Group and keychain group come from `Configuration/Base.xcconfig`, which
includes an optional gitignored `Configuration/Local.xcconfig` (template:
`Local.xcconfig.example`). Swift reads them through `Config.bundleIdBase`, `Config.appGroupId` and
`Config.keychainGroup` (Info.plist keys in both the app and the NSE). Never hard-code an identifier
in source, entitlements or the project file. A device build needs your own signing (Local.xcconfig)
and your own Firebase `GoogleService-Info.plist`.

## Code style
SwiftUI + Swift concurrency; match the surrounding upstream style — this is a fork, keep
diffs clean and upstreamable. Don't reformat files you aren't changing.

## Contributing
See `CONTRIBUTING.md`. Report bugs via GitHub issues or Discord (see README).

## License
MIT — see `LICENSE`. Original credit to @Copephobia and Philipp C. Heckel.
