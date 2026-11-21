# SnekotEvents

The [Snekot](https://snekot.co) SDK for Swift. Post product events, get them as push notifications, identify users and set insights.

A Swift package for iOS 15, macOS 12, tvOS 15 and watchOS 8 or later. Foundation only.

## Install

In Xcode, **File › Add Package Dependencies** and paste `https://github.com/snekot-co/snekot-swift`. Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/snekot-co/snekot-swift", from: "0.3.0"),
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
try await events.subscribe("jane@example.com", name: "Jane Park")
try await events.setInsight("MRR", to: "$1,289")
try await events.incrementInsight("Orders")
```

`experiment` asks which variant of an [A/B test](https://snekot.co/docs/experiments) a person gets:

```swift
let variant = try await events.experiment("pricing-page", variants: ["control", "annual-first"], userID: "user-123")
```

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
- With a public key, a kept event shows in the feed at the time it was finally sent, because a public key may not set a time. With a private key it keeps the moment it happened, and, like any event from the past, does not send a push notification.

### Behaviour

- One attempt may take 10 seconds (`timeout`).
- A network failure or a server error is retried once, after a quarter of a second.
- A refusal (a 4xx, such as a bad channel name) is never retried. It throws `SnekotError.refused(status:message:)` with the server's own sentence for what to fix.
- `disabled: true` makes every call succeed without sending anything, for tests and previews.
- `endpoint` defaults to `https://api.snekot.co`.

## Develop

```bash
swift test
```

`Tests/SnekotEventsTests/conformance.json` is the wire contract every Snekot SDK is tested against. `swift run smoke` runs every method against the real API; it needs `SNEKOT_TOKEN` and `SNEKOT_PROJECT`.

## Licence

MIT
