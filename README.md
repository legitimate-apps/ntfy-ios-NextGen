# NTFY me (ntfy iOS NextGen)

A community-maintained iOS client for [ntfy](https://github.com/binwiederhier/ntfy) ([ntfy.sh](https://ntfy.sh)), the push-notification service. On the App Store as **NTFY me - Next Gen**.

This is a fork of the official [ntfy-ios](https://github.com/binwiederhier/ntfy-ios) app. It works through upstream's backlog of iOS issues: reliability and security fixes, end-to-end encrypted topics, display names, pinned topics, a simpler first-run setup, and general UX work.

## Using the app

Setup guides live at **[ntfy-me.com](https://ntfy-me.com)**:

- [Quick start](https://ntfy-me.com/#qs): subscribe to a topic and send your first notification with one `curl` command.
- [Run your own server](https://ntfy-me.com/docs/self-hosting): self-host ntfy with Docker and still get instant notifications.
- [Move from ntfy.sh or the official app](https://ntfy-me.com/docs/migrate)
- [Support](https://ntfy-me.com/docs/support), including end-to-end encrypted topics.

## Servers

The app's default server is **ntfy-me.com**, a free public ntfy server run by the app's publisher. It is not affiliated with ntfy.sh or the ntfy project. Push notifications carry no message text: Google and Apple see the topic name and a message ID, and the app fetches the message from the server. ntfy-me.com keeps messages for 12 hours and attachments for 3 hours.

Any ntfy server works. If you self-host, add this to your `server.yml` for instant push to this app:

```yaml
upstream-base-url: "https://ntfy-me.com"
```

(The ntfy docs' example uses `https://ntfy.sh`, which pushes to the official ntfy app, not this one.)

## End-to-end encrypted topics

Give a topic a password (topic menu → **End-to-end encryption**) and messages sent to it with that password are encrypted in transit and on the server: the server, Google and Apple see ciphertext. Once they arrive they are stored readable on this device, like any other notification. The app shows copy-paste Node.js and Python senders for the topic. It uses the format from ntfy's own end-to-end encryption draft (JWE, AES-256-GCM, PBKDF2-SHA256), so other clients that adopt that draft can interoperate. Details: [support](https://ntfy-me.com/docs/support#end-to-end-encrypted-topics).

## Reporting a bug

[Open an issue](../../issues/new/choose) with your iOS version, device, and app version, plus steps to reproduce. Questions and general discussion: [Discord](https://discord.gg/WszujZEBbZ).

Bugs in the underlying ntfy server or protocol belong upstream: [binwiederhier/ntfy/issues](https://github.com/binwiederhier/ntfy/issues).

## Building and contributing

The app builds and its full test suite runs on the simulator with no Apple or Firebase account. See [CONTRIBUTING.md](CONTRIBUTING.md) for the steps, how to sign a build with your own team, and how to submit a PR.

## Credits

Originally developed by [@Copephobia](https://github.com/Copephobia), who did the bulk of the initial work. The app was previously maintained by [Philipp C. Heckel](https://heckel.io). This fork is maintained independently from both.

Upstream: [binwiederhier/ntfy-ios](https://github.com/binwiederhier/ntfy-ios). Server, Android app, and docs: [binwiederhier/ntfy](https://github.com/binwiederhier/ntfy), [ntfy.sh/docs](https://ntfy.sh/docs).

## Support the project

If this fork is useful to you: [Ko-fi](https://ko-fi.com/ntfyiosnextgen).

## License

[MIT](LICENSE), same as upstream.
