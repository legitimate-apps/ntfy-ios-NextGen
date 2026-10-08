# Clear everywhere: verification and delivery limits

2026-10-08. Branch `feat/clear-everywhere`. Review required; no release or merge.

## Client behavior

- JSON and Firebase payloads retain `sequence_id`. A missing/empty sequence uses the message ID, matching upstream semantics.
- App polling, NSE direct ingestion, NSE `poll_request` event fetches, and the app's direct Firebase background callback share the store transaction. Clear marks the existing row read; delete removes it and its cached attachment. Control events never become visible message rows.
- Delivered notification removal selects server + topic + sequence from payload metadata, including legacy implicit sequences. APNs request identifiers need not equal ntfy message IDs. A time cutoff protects later versions; update removal keeps the incoming version.
- Updates preserve the managed object and read state, replace payload/attachment metadata, and use silent passive content. The app uses distinct message IDs for local requests so asynchronous removal of an older request cannot delete its replacement.
- Model 6 adds sequence identity, scoped row/state uniqueness, presentation tracking, control tombstones and a durable cursor time. Shipped model versions remain available for lightweight migration. Seen IDs are retained only for the latest second of a sequence; older events are rejected by timestamp. Sequence tombstones remain until unsubscribe, preventing deleted cache history from returning.
- Same-second unknown events request an ordered cache poll instead of trusting APNs arrival order. An incomplete/stale window leaves a reconciliation flag so the next poll asks for cached history. An unrelated first push still presents normally while reconciliation is pending.
- Existing local unread-to-read actions (topic opening, subscription swipe, and the per-message store API) issue a best-effort `PUT /topic/sequence/clear` with the server's stored credentials and custom headers. Banner taps/dismissals resolve the current row by sequence. Every notification category requests `.customDismissAction`; a dismiss callback waits for the bounded send to finish.
- Received controls never invoke local read publication. Mark-unread does not publish. Failed requests, including 403, 404 and offline failures, remain logged and preserve local read state. No retry queue or new toggle: synchronization follows the app's existing definition of reading a topic, and lacking write access does not impede local reading.

## Authoritative server findings

Source pinned to upstream `v2.28.0`, commit `10cb6506f836dbb00bb77e3b52669f6ace37f555`, the version selected by the public server's existing Dockerfile. No server files were changed.

- [Clear routing and write authorization, server.go lines 678–679](https://github.com/binwiederhier/ntfy/blob/v2.28.0/server/server.go#L678).
- [Default sequence is message ID, server.go lines 1128–1147](https://github.com/binwiederhier/ntfy/blob/v2.28.0/server/server.go#L1128). [JSON omits identical sequence ID, model/model.go lines 93–101](https://github.com/binwiederhier/ntfy/blob/v2.28.0/model/model.go#L93).
- [Action events dispatch only Firebase and web push, server.go lines 1023–1047](https://github.com/binwiederhier/ntfy/blob/v2.28.0/server/server.go#L1023). This omits `upstream: true`.
- [Dispatch forwards only when opts.upstream is true, server.go lines 826–851](https://github.com/binwiederhier/ntfy/blob/v2.28.0/server/server.go#L826). [Ordinary messages enable upstream forwarding, lines 935–942](https://github.com/binwiederhier/ntfy/blob/v2.28.0/server/server.go#L935).
- [Direct clear/delete Firebase messages use background APNs, server_firebase.go lines 147–155](https://github.com/binwiederhier/ntfy/blob/v2.28.0/server/server_firebase.go#L147). [Background config uses content-available and priority 5, lines 258–283](https://github.com/binwiederhier/ntfy/blob/v2.28.0/server/server_firebase.go#L258).
- [Clear/delete API documentation](https://docs.ntfy.sh/publish/#clearing-notifications).

**OBSERVED from source:** self-hosted `upstream-base-url` does not forward clear/delete events. A later ordinary-message relay invokes an NSE fetch for only that event ID; it does not backfill intervening controls. Those controls are applied on foreground/topic/list polling or a later `~poll` full-topic wake-up, while the events remain cached. The public server's existing poll-only Firebase patch changes authorization for ordinary messages only; direct clear/delete still use the background Firebase branch above.

**ASSUMED / not device-verified:** direct Firebase background delivery depends on iOS granting execution. It is not guaranteed or immediate, especially after force quit. FCM/APNs receipt and simultaneous iPhone/M1 Mac behavior were not exercised on physical hardware.

**Server recommendation:** add a control-event relay to the public server/self-hosted upstream path, using a silent targeted wake-up with hashed topic identity and the original event ID. A companion main-app silent `poll_request` handler should resolve the subscription and fetch with its own credentials. Merely setting `upstream: true` produces today's alert-style poll request, which cannot be fully hidden by this NSE. Do this as a separate reviewed server/client follow-up; this leg makes no server changes.

**NSE limit:** stock controls use silent APNs and bypass the NSE. A custom relay wrapping a control or obsolete version in an alert can have existing notifications removed, but this NSE returns a passive neutral synchronization receipt. Completely suppressing that new alert requires the notification-filtering entitlement, outside this brief. Update replacement content itself is soundless/passive; the extension cannot change an APNs request identifier. No entitlement, URL-scheme, signing configuration or dependency changes were made.

## Automated verification

**OBSERVED, primary run:** 334 tests, 0 failures, `TEST SUCCEEDED` on leased iPhone 17 Pro, iOS 26.5, Xcode 26.6.0. Includes 26 new sequence regression tests. App and NSE compiled together. Reproduction command (the actual run supplied the owned UDID and leased DerivedData path):

```sh
xcodebuild -project ntfy.xcodeproj -scheme ntfy \
  -destination "platform=iOS Simulator,id=$SIM_UDID" \
  -derivedDataPath "$CLEAR_DERIVED_DATA" \
  -parallel-testing-enabled NO test
```

- Baseline red: six new parsing/store tests executed, all six failed with 18 failed assertions.
- Green: those six passed; the final complete suite passed 334/334.
- Mutation: changed incoming `message_clear` from `row.read = true` to `row.read = false`. Focused run of `testSequenceClearMarksReadWithoutAddingRow` and `testSequenceReceivedClearNeverRepublishesEvenWhenTopicIsReadAgain` failed 2/2. The mutation was restored before the final full run.
- Tests cover parsing, clear/delete/update, poll-batch alert filtering, scope, implicit IDs, no republish, credentials, dismiss completion, notification selection, HTTP/offline failure, stale/same-second ordering, first presentation during pending reconciliation, concurrent uniqueness, attachment cleanup and Model 5 migration.
- Independent source review found concurrency, ordering, removal/add and first-presentation issues; each was corrected and regression checked. Final bounded independent review: no remaining blockers in the reviewed findings. The reviewer did not run builds or pilot the simulator.
- Final simulator build also succeeded for live driving. The tracked Firebase example's invalid placeholder API key prevents normal launch; the ignored local test configuration used a syntactically valid fake key for the live run. No real Firebase key, signing configuration or tracked Firebase file was changed.

## Live verification

**OBSERVED, primary pilot:** anonymous throwaway topic on ntfy-me.com; HTTP calls succeeded. The app stayed on the topic and used its normal live poll loop. SQLite queries read the app-group store.

| Trigger | Observed effect |
| --- | --- |
| Subscribe/open cached topic | Local opening marked the message read and issued a real clear. Server history contained exactly one `message_clear` for `job`, before the explicit remote-clear curl. |
| Publish another message with sequence `job` | Row `Z_PK=1` remained `Z_PK=1`; message ID changed from `PPA0xWcLMC8I` to `YkpQ3ypvw9Ws`; body changed from `Version one` to `Version two`; read state remained 1. |
| Publish sequence `probe` while topic remained open | A separate row (`Z_PK=2`) arrived with `ZREAD=0`. |
| Inject an APNs-shaped probe with simctl while app was backgrounded | `Remote clear probe / Unread probe` appeared in Notification Center. This was simulator injection, not FCM or NSE execution. |
| Return to app, then curl `PUT /topic/probe/clear` | Before: probe `ZREAD=0`. After foreground polling: same row, `ZREAD=1`; Notification Center no longer contained the probe. |
| Curl `DELETE /topic/probe`, then `/topic/job` | Store contained zero message rows; topic showed `No messages yet`; cursor advanced to the delete event `iiL8sPpjmeqZ`. |

Screenshots:

- [Original message](01-before.jpg)
- [Updated message and unread probe](02-update-and-unread.jpg)
- [Delivered probe before remote clear](03-center-before.jpg)
- [Notification Center after remote clear](04-center-after-clear.jpg)
- [Empty topic after remote deletes](05-after-delete.jpg)

**Only automated/source verification:** real NSE execution, no-second-buzz on hardware, real notification dismiss callback, read-only token against a live private topic, legacy server behavior, cross-process ordering under actual simultaneous app/NSE execution, and multi-device propagation. The tests use real Core Data contexts and HTTP stubs, but those do not prove physical-device delivery.

Retained tombstones add metadata per distinct sequence until unsubscribe; extremely large retained topic histories may warrant a later retention/performance policy. No periodic job was added.
