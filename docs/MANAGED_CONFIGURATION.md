# Managed app configuration

An MDM administrator can provision a default server and topic subscriptions using
Apple's legacy managed app configuration dictionary. This works on iOS 15 and later
and requires the app to be installed as a managed app. Send the dictionary below as
the app configuration in your MDM console. Do not wrap it in an arbitrary device
configuration profile. The MDM service supplies it under
`com.apple.configuration.managed` in the app's standard preferences.

## Keys

| Key | Type | Meaning |
| --- | --- | --- |
| `defaultServer` | String, optional | Default server used when adding topics manually. |
| `topics` | Array of dictionaries, optional | Subscriptions to create. |
| `topics[].server` | String, required | Server for this topic, independent of `defaultServer`. |
| `topics[].topic` | String, required | Topic name: 1 to 64 ASCII letters, digits, underscores or hyphens. |
| `topics[].displayName` | String, optional | Name shown in the topic list, at most 256 characters. Blank clears the managed name. |

Servers must be full HTTP or HTTPS URLs with a host. A port and reverse proxy path
are supported. Embedded usernames, passwords, queries, fragments and whitespace
are rejected. HTTPS is recommended. Hosts and schemes are normalized to lowercase,
default ports and trailing slashes are removed. Topic names are case sensitive.
Unknown keys are reported. An invalid topic entry is skipped while other valid
entries are applied. Duplicate server/topic pairs use the first valid entry.
A malformed root dictionary is ignored. A malformed `topics` value leaves topic
ownership unchanged, while a valid `defaultServer` can still apply.

## Example plist

The app configuration payload, using reserved example host names:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>defaultServer</key>
    <string>https://notify.example.org</string>
    <key>topics</key>
    <array>
        <dict>
            <key>server</key>
            <string>https://notify.example.org</string>
            <key>topic</key>
            <string>operations</string>
            <key>displayName</key>
            <string>Operations alerts</string>
        </dict>
        <dict>
            <key>server</key>
            <string>https://status.example.org/ntfy</string>
            <key>topic</key>
            <string>service_status</string>
        </dict>
    </array>
</dict>
</plist>
```

MDM products differ in how they enter arrays of dictionaries. Use their raw plist
or structured app configuration editor. This plist is the payload schema; a vendor
AppConfig specfile or configuration profile wrapper is not needed by the app.
Declarative management deployments can use Apple's `LegacyAppConfigAssetReference`
to deliver the same payload. The newer ManagedApp framework's `AppConfig` data
and secret providers are not consumed.

## Changes and removal

The app reads configuration at launch, when it becomes active, and when the managed
preference changes while it runs. It does not launch itself to process configuration
while terminated. Reapplying a configuration does not create duplicate subscriptions
or repeat their initial polls or FCM registrations. Existing FCM retry handling still
repairs registrations that have failed or are waiting for notification permission.

New subscriptions use the same persistence, initial poll and push registration path
as subscriptions added by a person. An existing personal subscription on the same
server and topic is left unchanged, including its display name. It is not adopted
by the administrator. For topics the configuration created, subsequent configuration
changes update the display name, including clearing it when omitted.

Removing a topic, sending an empty dictionary or removing the configuration keeps
the subscription and its messages, but releases it to user control. It will continue
to receive messages until the user unsubscribes. Adding the same topic to the profile
later does not take control of that retained personal subscription. To stop access,
revoke permission on the server; profile removal is not a data wipe or access control.
Invalid entries also release their previous management without deleting data.

Users can rename, mute, pin or unsubscribe from any topic. There is no managed badge
or locked control. A managed display name is reapplied on the next configuration
read. Unsubscribing from a topic still listed in configuration is temporary: the app
recreates it at the next read. A topic manually recreated by the user before that
read is personal and remains under their control. Administrators can use a display
name such as `Operations alerts` to identify the purpose of a topic.

The managed default server is reapplied on each read. When its key is removed, the
previous default is restored only if the current value still matches the last
managed value. A later user choice is preserved. An invalid default is ignored.

## Authentication and secrets

This schema does not accept usernames, passwords, access tokens, custom headers or
end-to-end encryption passwords. Plain managed configuration is visible in the MDM
console and on the device. It is unsuitable for confidential secrets. Unsupported
credential keys are rejected or ignored with feedback, and never imported or echoed.

For a server that requires authentication, users add a server account in Settings
using a username and password or access token. The existing credential store uses
the shared Keychain for the app and notification extension. Until an account is
available, provisioned topics remain visible but protected fetches can fail. After
adding the account, refresh the topic or return to the app to retry. A deployment
requiring unattended secret provisioning is not supported by this version.

Configuration does not grant notification permission. The usual iOS permission and
server push support requirements still apply. HTTP transport also remains subject
to the app's existing transport security policy.

## MDM feedback

The app writes a dictionary to `com.apple.feedback.managed` for the MDM's managed
application feedback command:

```xml
<dict>
    <key>applied</key><integer>3</integer>
    <key>errors</key><array/>
</dict>
```

`applied` counts a valid default and valid unique topic entries present in the local
store, including existing personal subscriptions. It does not attest to successful
server authentication, notification permission, FCM registration or message delivery.
`errors` contains fixed descriptions and zero-based entry indexes, for example
`topics[2]: invalid server, topic, displayName or unsupported keys`. Values, URLs,
topic names and unknown key names are never copied into feedback. Feedback describes
the most recent read and is replaced, not appended. It is not a remote delivery log.

Apple references:
[Configuring managed apps and extensions](https://developer.apple.com/documentation/devicemanagement/configuring-managed-apps-and-extensions),
[ManagedAppConfigurationProvider](https://developer.apple.com/documentation/managedapp/managedappconfigurationprovider),
[UserDefaults change observation](https://developer.apple.com/documentation/foundation/userdefaults/didchangenotification).
