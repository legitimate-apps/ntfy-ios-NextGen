# Changelog

User-facing release notes for **NTFY me - Next Gen** (ntfy iOS NextGen). These are the notes that go
into the App Store "What's New" field. Engineering detail and upstream tracking live in
`CHANGES-vs-upstream.md`.

## Unreleased

- After an update, a short "What's new" sheet lists what changed since the version you last used.
- A new topic has a "Send a test notification" button, so you can see a notification arrive without a
  computer. It uses normal priority, so the first test shows a banner.
- Priority 4 and 5 messages are now delivered as Time Sensitive, so they break through Focus and the
  Notification Summary (when Time Sensitive notifications are allowed in iOS and your Focus settings).
  They still follow the silent switch.
- Settings → Urgent alerts shows whether iOS currently allows Time Sensitive notifications, with a
  button to iOS Settings when it doesn't. The Critical Alerts switch is gone: iOS critical alerts need
  Apple's approval, which this app doesn't have, so the switch never worked.

## 1.16.0

- Adding a topic on ntfy.sh now says plainly that ntfy.sh topics get no instant banners in this
  app (messages appear when you open it or refresh) and points to moving the topic to ntfy-me.com.
  It used to suggest editing a server config that ntfy.sh users don't control.
- Adding a topic on ntfy-me.com now reminds you that your scripts must send to ntfy-me.com, since the
  same topic name on ntfy.sh is a different topic.
- The self-hosting hint now explains that pointing your server's upstream at ntfy-me.com stops instant
  delivery to the official ntfy iOS app on that server, and the setup and migration guide links in
  these hints can be tapped.
- Reading or dismissing notifications on a self-hosted topic now requests a silent wake for your
  other devices, so they can clear those notifications in the background. Background delivery is
  best effort; opening the app still catches up when a wake is delayed.
- Settings → About → Licenses lists the open-source licenses the app is built on.
- On a Mac, notification buttons such as Approve now work from the banner. macOS sometimes handed the
  tap to the app's notification extension instead of the app, and the tap was lost or waited for the
  next notification. The extension now steps aside a second after showing a banner, so the tap goes
  straight to the app.
- A double tap on an action button sends the request once. A request the server turns away for
  being busy (rate limit) is retried, and a failed repeat no longer replaces the success message.

## 1.15.0

- Topics that were set up on the old built-in server now move to ntfy-me.com automatically, so they
  start receiving notifications again. Topics on a server you have signed in to are left as they are.
  A one-time notice lists the moved topics and the address to send to now.
- **End-to-end encrypted topics.** Give a topic a password and messages sent with it are encrypted
  in transit and on the server; the server, Google and Apple see only ciphertext. Once they arrive
  they are stored readable on this device, like any other notification. The app shows ready-to-copy
  Node.js and Python senders for the topic, and "Send test notification" sends an encrypted test.
  Messages that arrive before you set the password show as "Encrypted message" and open once you do.
- **Easier first topic.** Tap Random for a hard-to-guess topic name, and see the address to send to
  before you subscribe. A new topic opens straight away with ready-to-copy `curl` commands (plain, and
  with a title and high priority) and its full `https://` publish URL; "Copy publish URL" is also in the
  topic menu. On a server you have signed in to, the commands use your user name and curl asks for the
  password, so it is never in the copied text.
- **Notification permission is asked at the right time.** The app no longer asks on first launch.
  After you add your first topic, a short screen explains why, then iOS asks. "Not now" is remembered.
- **Messages show up while a topic is open**, even without notification permission. The open topic
  checks for new messages every 10 seconds and when you return to the app, and pull to refresh now
  works on an empty topic.
- Help links now point to the quick start at ntfy-me.com; the ntfy documentation is still in Settings
  as the full reference.

## 1.14.0

- **New default server: ntfy-me.com.** The app now works out of the box: new topics use ntfy-me.com,
  a free public ntfy server run by the app's publisher. It is not affiliated with
  ntfy.sh or the ntfy project. Any ntfy server still works — change it in Settings or per topic.
- **Push notifications carry no message text.** Google and Apple see only the topic name and a message
  ID; the app fetches the message itself from the server over an encrypted connection.
- **Self-hosting?** Add `upstream-base-url: "https://ntfy-me.com"` to your server config to get
  instant push in this app.
- Existing subscriptions are moved to the right push channels automatically on first launch after the
  update.
- Updated Privacy Policy: ntfy-me.com keeps messages for 12 hours and attachments for 3 hours, and uses
  IP addresses for rate limiting.
