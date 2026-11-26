# SnekotEvents

The [Snekot](https://snekot.co) SDK for Swift. Post product events, get them as push notifications, identify users and set insights.

A Swift package for iOS 15, macOS 12, tvOS 15 and watchOS 8 or later. Foundation only.

## Install

In Xcode, **File › Add Package Dependencies** and paste `https://github.com/snekot-co/snekot-swift`. Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/snekot-co/snekot-swift", from: "0.5.0"),
],
targets: [
    .target(name: "YourApp", dependencies: [.product(name: "SnekotEvents", package: "snekot-swift")]),
]
```

## Use

```swift
import SnekotEvents

let events = SnekotEvents(token: token, project: "acme-store")

try await events.track(channel: "payments", event: "New subscription", icon: "💰", notify: true, tags: ["plan": "pro"])
try await events.identify(userID: "user-123", properties: ["plan": "pro"])
try await events.group("acme", userID: "user-123", properties: ["name": "Acme"])
try await events.subscribe("jane@example.com", name: "Jane Park", language: "sv-SE", timezone: "Europe/Stockholm")
try await events.setInsight("MRR", to: "$1,289")
try await events.incrementInsight("Orders")
```

`experiment` asks which variant of an [A/B test](https://snekot.co/docs/experiments) a person gets:

```swift
let variant = try await events.experiment("pricing-page", variants: ["control", "annual-first"], userID: "user-123")
```

`flag` asks whether a feature flag is on for a person:

```swift
let on = try await events.flag("new-checkout", userID: "user-123")
```

A key that has no flag answers `false`. When the answer cannot be had, the call throws, as every call does; treat that as off.

An app ships to other people's devices, so give it a **public** key (`pk_…`), which can only add events. See [Keys](https://snekot.co/docs/keys).

### Offline

A phone is not always online. Give the client a queue, and a call that gets no answer is kept on the device instead of thrown:

```swift
let events = SnekotEvents(token: token, project: "acme-store", queue: OfflineQueue())
```

- What was kept goes out, oldest first, before the next call that gets through. `await events.flush()` does it on demand, such as when the app starts.
- At most 500 events are kept, for at most 7 days; `OfflineQueue(limit:maxAge:)` changes both. `clear()` forgets them, for when someone signs out.
- A refusal is still thrown and never kept. If the server says there are too many requests for now, what is waiting stays for the next try.
- The bodies wait in a file in the app's Application Support folder. The key is not written to it.
- A kept event keeps the moment it happened. Like any event sent with a time, it is not announced on the live feed and sends no push notification.
- A public key can place an event up to 7 days back, which is the default age limit. With a public key, keep `maxAge` at 7 days or less: an older event is refused and dropped.

### Behaviour

- One attempt may take 10 seconds (`timeout`).
- A network failure or a server error is retried once, after a quarter of a second.
- A refusal (a 4xx, such as a bad channel name) is never retried. It throws `SnekotError.refused(status:message:)` with the server's own sentence for what to fix.
- `disabled: true` makes every call succeed without sending anything, for tests and previews.
- Without `app`, nothing is added to what you send: no visitor id and no details. That is the right way on a server.
- `endpoint` defaults to `https://api.snekot.co`.

## In an app

Give the client an `AppAnalytics` when the app starts, and keep the client for as long as the app runs:

```swift
let snekot = SnekotEvents(token: token, project: "acme-store", queue: OfflineQueue(), app: AppAnalytics())
```

That one line is the setup. From then on:

```swift
try await snekot.screen("Checkout")                                   // which screen someone is on
try await snekot.screen("Product", title: "Blue mug")                 // with what it shows
try await snekot.track(channel: "orders", event: "Order placed")      // an event, as before
try await snekot.identify(userID: "user-123", properties: ["plan": "pro"])  // on sign-in
snekot.reset()                                                        // on sign-out
```

- `screen` names the screen a person is looking at. Give the same screen the same name every time.
- After `identify`, later events and screens are from that user, also after the app is restarted. An event that names its own `userID` keeps it.
- `reset()` forgets the user and makes a new visitor id. Call it when someone signs out, so the next person on the device is not taken for the last one. If you use a queue and want what is waiting gone too, call its `clear()`.

### What is sent by itself

Every event and screen carries a visitor id and these details of the app and the device:

| Field | Example | What it is |
| --- | --- | --- |
| `visitor_id` | `r_3q2-7wAAAAAAAAAAAAAAAA` | A random id made on the first launch and kept in the app's `UserDefaults`. It is not derived from the device. |
| `version` | `2.4.1` | The app's version. |
| `build` | `312` | The app's build number. |
| `os` | `iOS` | `iOS`, `iPadOS`, `macOS`, `tvOS`, `watchOS` or `visionOS`. |
| `os_version` | `18.2` | The system's version. |
| `model` | `iPhone16,1` | The hardware's model identifier. |
| `kind` | `phone` | `phone`, `tablet`, `desktop`, `tv`, `watch` or `headset`. |
| `language` | `sv-SE` | The person's first preferred language. |
| `screen_width`, `screen_height` | `393`, `852` | The screen's size in points, on iPhone, iPad and Apple TV. |

None of this asks the person for permission. What is **not** collected: the advertising identifier, the vendor identifier, the device's name, and location.

### Installs, updates and opens

Three events are posted to the `app` channel with no code of yours:

| Event | When |
| --- | --- |
| 📲 `App installed` | The first launch on a device. |
| 🆙 `App updated` | The first launch of a new version or build, with the tags `from`, `to`, `from_build` and `to_build`. |
| 📱 `App opened` | A cold start, and coming back to the app after 30 minutes or more away. |

Choose which are sent with `lifecycle`; leave one out to switch it off, or pass `[]` for none:

```swift
AppAnalytics(lifecycle: [.installed, .updated])
```

The first launch after you add the SDK to an app that is already out counts as an install for everyone who already had it: there is nothing on their device yet to say they are not new. Expect one burst of `App installed` with that release.

An app deleted and installed again is a new install with a new visitor id, since deleting an app deletes what it stored.

### Privacy

The package ships a privacy manifest (`PrivacyInfo.xcprivacy`), which Xcode merges into your app's privacy report. It says the SDK does not track, contacts no tracking domains, and uses `UserDefaults` to keep its own values (reason `CA92.1`).

For the App Store privacy label, with `AppAnalytics` on, declare under **Analytics**, not used for tracking:

- **Product Interaction**: events and screens.
- **Device ID**: the visitor id. It is random and scoped to your app, but it does identify an install.
- **Other Usage Data** and **Other Diagnostic Data**: the app and device details above.

The manifest marks these as not linked to the person. Once you call `identify`, events are tied to your user id, so declare them as **linked to the user** and add **User ID**. Anything personal you put in tags or properties is yours to declare as well.

## Develop

```bash
swift test
```

`Tests/SnekotEventsTests/conformance.json` is the wire contract every Snekot SDK is tested against. `swift run smoke` runs every method against the real API; it needs `SNEKOT_TOKEN` and `SNEKOT_PROJECT`.

## Licence

MIT
