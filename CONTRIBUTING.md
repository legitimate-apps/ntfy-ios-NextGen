# Contributing

Bug reports, fixes, and small features welcome.

## Reporting a bug

[Open an issue](../../issues/new/choose) using the bug report template. Include your iOS version, device model, and app version — bug reports without those are still fine, we'll just ask follow-ups before we can act on them.

## Building the app

Requirements: a Mac with Xcode installed, matching the deployment target in `ntfy.xcodeproj` (iOS 14 for the app, iOS 15 for the Notification Service Extension).

1. **Bootstrap first.** A fresh clone does not build without this:
   ```
   ./scripts/bootstrap.sh
   ```
   Xcode lists `ntfy/Assets/GoogleService-Info.plist` as a required build input, and that file is
   gitignored because the real one carries a Firebase API key. Without it the build fails with
   `Build input file cannot be found` before any Swift is compiled. The script installs a tracked
   placeholder; it never overwrites a real config.

2. Resolve SPM dependencies (Xcode usually does this for you):
   ```
   xcodebuild -project ntfy.xcodeproj -scheme ntfy -resolvePackageDependencies
   ```

3. Open `ntfy.xcodeproj` in Xcode, or build from the command line. Pick a simulator that exists on
   your machine rather than copying a device name out of a doc — a stale name fails with an
   unhelpful "destination not found":
   ```
   udid=$(xcrun simctl list devices available | grep -E '^\s+iPhone' | head -1 | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/')
   xcodebuild -project ntfy.xcodeproj -scheme ntfy \
     -destination "platform=iOS Simulator,id=$udid" \
     -configuration Debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
   ```

4. Run the tests the same way, with `test` instead of `build`. Add `-parallel-testing-enabled NO`:
   xcodebuild clones the destination simulator to parallelize, which is slower here and fails
   outright against a leased simulator — *after* a successful build, so it reads as a test failure
   when nothing ran.

5. Run on the simulator via Xcode (Cmd+R), or install the built `.app` onto a booted simulator.
   Note `CODE_SIGNING_ALLOWED=NO` is correct for build and test but **not** for install-and-run:
   an unsigned binary is denied its App Group container and traps at launch.

### Signing with your own team

Bundle ids, the signing team, the App Group and the keychain group are build settings in
`Configuration/Base.xcconfig`. Its defaults (`org.example.ntfy-nextgen`, no team) are enough for
the simulator. To run on a device, copy the template and fill in your own values:

```
cp Configuration/Local.xcconfig.example Configuration/Local.xcconfig
```

`Local.xcconfig` is gitignored, so your team id and bundle ids never end up in a commit. Both
entitlements files and the Swift code read these settings (`Config.bundleIdBase`,
`Config.appGroupId`, `Config.keychainGroup`); don't hard-code an identifier anywhere else.

A device build, or any build where you need push notifications to actually arrive, also needs a
real `GoogleService-Info.plist` from your own Firebase project (see `docs/GETTING_STARTED.md`). With the placeholder from step 1 the app builds and the full unit
suite passes — the tests use an in-memory Core Data store and never reach Firebase — but FCM
registration fails against a project that does not exist, so no push is delivered.

## Releasing (maintainers)

The app's built-in server is the `APP_BASE_URL` build setting (`https://ntfy-me.com` for Debug and
Release), written into `AppBaseURL` in both the app's and the Notification Service Extension's
`Info.plist`. Subscriptions on that server bind their raw topic name in FCM and every other server
binds a hash, so an archive with the wrong value builds fine and silently receives no push for its
default server. Before uploading, gate the archive (or exported `.ipa`):

```
./scripts/verify-app-base-url.sh path/to/ntfy.xcarchive          # expects https://ntfy-me.com
./scripts/verify-app-base-url.sh path/to/ntfy.ipa https://other   # or pass the expected value
```

It exits non-zero unless both plists match, and unless the app and the extension carry the same
build identity (`AppBundleIdBase`, `AppGroupId`, `AppKeychainGroup`), which a release build gets
from the maintainer's `Configuration/Local.xcconfig`. Do not override `APP_BASE_URL` at archive time. User-facing
release notes live in `CHANGELOG.md`.

## Code style

Match the surrounding upstream SwiftUI style. This is a fork we intend to stay upstreamable, so keep diffs focused and don't reformat files you aren't otherwise changing.

## Submitting a PR

1. Fork → branch off `main` → commit → push → open a PR against `main`.
2. Keep PRs focused on one logical change.
3. CI must pass. `iOS tests` builds the app and runs the full unit suite on a GitHub-hosted macOS
   runner, for pull requests from forks too.
4. Describe what you tested (simulator + device, if applicable) in the PR description.

## Commit identity

Commit as yourself; your authorship is kept and credited. (`validate-author` checks only the
maintainer's own branches.)

## Auto-merge

PRs labeled `safe-tier-1` (docs/markdown-only changes) auto-merge once CI is green. Everything else waits for review. See `.github/workflows/auto-merge-tier1.yml` for the exact gate.

## Credit

Contributions are credited by handle in commit history and release notes. We don't squash credit out.
