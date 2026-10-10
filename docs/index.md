---
title: NTFY me (ntfy iOS NextGen)
description: "NTFY me is a free, actively maintained iOS app for ntfy. Get a push notification on your iPhone from any computer, script or server with one curl command."
---

# NTFY me (ntfy iOS NextGen)

Get a push notification on your iPhone or iPad from any computer, script, server or cron job with one
HTTP request. NTFY me is an actively maintained iOS app for [ntfy](https://ntfy.sh), the open-source
push-notification service, forked from
[binwiederhier/ntfy-ios](https://github.com/binwiederhier/ntfy-ios) (MIT). It's free on the App Store as
[NTFY me - Next Gen](https://apps.apple.com/us/app/id6787782178). It is not affiliated with or endorsed
by the ntfy project.

```sh
# Subscribe to a topic in the app, then from any terminal:
curl -d "Backup finished" https://ntfy-me.com/your-secret-topic
```

No account or API key: the topic name is the password, so pick a long random one.

## Common questions

**How do I get a notification on my phone when a script or long command finishes?**
Install the app, subscribe to a long random topic on ntfy-me.com, and add
`curl -d "done" https://ntfy-me.com/<topic>` to the end of the script (or `long-command; curl -d "exit $?" https://ntfy-me.com/<topic>`).
Recipes for Windows PowerShell, Python, cron, GitHub Actions and Home Assistant are on [ntfy-me.com](https://ntfy-me.com).

**How is NTFY me different from the official ntfy iOS app?**
Both speak the ntfy protocol. NTFY me is a fork that ships frequent updates. It adds end-to-end
encrypted topics, pinned topics, display names, a guided first-run setup with a "Send a test
notification" button, and many reliability fixes from ntfy's iOS issue backlog. See the
[changelog](https://github.com/legitimate-apps/ntfy-ios-NextGen/blob/main/CHANGELOG.md).

**Does it work with ntfy.sh or my own server?**
Any ntfy server works. Self-hosted servers get instant push by setting
`upstream-base-url: "https://ntfy-me.com"`. Topics on ntfy.sh arrive without instant banners (ntfy.sh
relays iOS push only to the official app), so for instant banners use ntfy-me.com or your own server.

**Is it free? Do I need an account?**
Yes, it's free, and no account is needed. ntfy-me.com keeps messages for 12 hours. Push notifications
carry no message text; the app fetches each message from the server over TLS.

## Using the app

Setup guides, support and the privacy policy live at **[ntfy-me.com](https://ntfy-me.com)**:

- [Quick start](https://ntfy-me.com/#qs)
- [Run your own server](https://ntfy-me.com/docs/self-hosting)
- [Move from ntfy.sh or the official app](https://ntfy-me.com/docs/migrate)
- [Support](https://ntfy-me.com/docs/support)
- [Privacy Policy](https://ntfy-me.com/docs/privacy) · [License agreement](https://ntfy-me.com/docs/eula)

## Development notes

- [Getting started with development](GETTING_STARTED.md)
- [Feature parity with upstream](FEATURE_PARITY.md)
- [Technical limitations](TECHNICAL_LIMITATIONS.md)

Licensed under the MIT License. Original credit to
[@Copephobia](https://github.com/Copephobia) and [Philipp C. Heckel](https://heckel.io).
