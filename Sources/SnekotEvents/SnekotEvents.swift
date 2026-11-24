import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A tag, property or insight value: text, a number or a flag. Literals work directly: `["plan": "pro", "seats": 3]`.
public enum EventValue: Sendable, Equatable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    case text(String)
    case integer(Int)
    case number(Double)
    case flag(Bool)

    public init(stringLiteral value: String) { self = .text(value) }
    public init(integerLiteral value: Int) { self = .integer(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .flag(value) }

    var json: JSON {
        switch self {
        case .text(let value): return .string(value)
        case .integer(let value): return .integer(value)
        case .number(let value): return .number(value)
        case .flag(let value): return .bool(value)
        }
    }
}

/// A JSON document, so a request body can be built, compared and encoded without `Any`.
public enum JSON: Sendable, Equatable, Codable {
    case string(String)
    case integer(Int)
    case number(Double)
    case bool(Bool)
    case object([String: JSON])
    case array([JSON])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

/// How a description is read.
public enum Parser: String, Sendable {
    /// Bold, italic, inline code and links.
    case markdown
    case text
}

/// An event to post. Only the channel and the name are required.
public struct Track: Sendable {
    public var channel: String
    public var event: String
    public var description: String?
    public var userID: String?
    /// One emoji, or a shortcode such as `:moneybag:`.
    public var icon: String?
    /// Push this event to the phones of everyone on the project.
    public var notify: Bool?
    public var tags: [String: EventValue]
    public var parser: Parser?
    /// A past moment makes this a backfill: stored at that time, never pushed to a phone.
    public var timestamp: Date?

    public init(channel: String, event: String, description: String? = nil, userID: String? = nil, icon: String? = nil, notify: Bool? = nil, tags: [String: EventValue] = [:], parser: Parser? = nil, timestamp: Date? = nil) {
        self.channel = channel
        self.event = event
        self.description = description
        self.userID = userID
        self.icon = icon
        self.notify = notify
        self.tags = tags
        self.parser = parser
        self.timestamp = timestamp
    }
}

public enum SnekotError: Error, Sendable, Equatable, LocalizedError {
    /// The server understood the request and said no. `message` is its own sentence for what to fix. Never retried.
    case refused(status: Int, message: String)
    /// The server errored twice in a row.
    case server(status: Int)
    /// The request could not be sent or timed out, twice in a row.
    case unreachable(String)

    public var errorDescription: String? {
        switch self {
        case .refused(_, let message): return message
        case .server(let status): return "The server answered \(status)."
        case .unreachable(let reason): return "The server could not be reached: \(reason)"
        }
    }
}

/// A request as it goes on the wire, before the key is attached.
public struct WireRequest: Sendable, Equatable {
    public let method: String
    public let path: String
    public let body: JSON
}

/// Posts events, identifies users and sets insights. Safe to share across tasks.
///
/// In an app, give it an `AppAnalytics` and it also names screens, remembers who is signed in, and posts installs,
/// updates and opens by itself. Without one it sends exactly what each call says and nothing more.
public struct SnekotEvents: Sendable {
    public static let defaultEndpoint = URL(string: "https://api.snekot.co")!

    public let project: String
    private let token: String
    private let endpoint: URL
    private let session: URLSession
    private let timeout: TimeInterval
    private let disabled: Bool
    private let queue: OfflineQueue?
    private let app: AppAnalytics?

    /// - Parameters:
    ///   - timeout: How long one attempt may take; 10 seconds by default.
    ///   - disabled: Makes every call succeed without sending anything, for previews and tests.
    ///   - queue: Keeps what could not be sent and sends it later. With one, a call that gets no answer no longer throws.
    ///   - app: The app side: a visitor id and the app's details on every event and screen, and installs, updates
    ///     and opens posted by themselves. Create the client once when the app starts. Leave it out on a server.
    public init(token: String, project: String, endpoint: URL = SnekotEvents.defaultEndpoint, timeout: TimeInterval = 10, disabled: Bool = false, session: URLSession = .shared, queue: OfflineQueue? = nil, app: AppAnalytics? = nil) {
        self.queue = queue
        self.app = app
        self.token = token
        self.project = project
        self.endpoint = endpoint
        self.timeout = timeout
        self.disabled = disabled
        self.session = session
        app?.start(self)
    }

    /// Posts an event to a channel.
    public func track(_ event: Track) async throws {
        // An event that has to wait is kept with the moment it happened, so it lands in the feed at the right time.
        var kept = event
        if kept.timestamp == nil { kept.timestamp = Date() }
        try await send(prepared(Self.request(for: event, project: project)), keeping: prepared(Self.request(for: kept, project: project)))
    }

    /// Sends what the queue is holding. Call it when the app starts or comes back online; every other call does
    /// it too, before sending its own. It answers with how many events are still waiting, and is 0 without a queue.
    @discardableResult
    public func flush() async -> Int {
        guard let queue, !disabled else { return 0 }
        _ = await queue.drain { _ = try await self.deliver($0) }
        return await queue.count
    }

    /// Posts an event to a channel.
    public func track(channel: String, event: String, description: String? = nil, userID: String? = nil, icon: String? = nil, notify: Bool? = nil, tags: [String: EventValue] = [:]) async throws {
        try await track(Track(channel: channel, event: event, description: description, userID: userID, icon: icon, notify: notify, tags: tags))
    }

    /// Sets properties on a user; keys sent again replace their old values.
    /// In an app, this is also who later events and screens are from, until `reset()`.
    public func identify(userID: String, properties: [String: EventValue]) async throws {
        app?.remember(user: userID)
        try await send(prepared(Self.identifyRequest(userID: userID, properties: properties, project: project)))
    }

    /// Says which screen the person is looking at.
    /// - Parameters:
    ///   - name: The screen's name, such as `Checkout`. The same screen should always have the same name.
    ///   - title: What the screen shows, when that says more than its name, such as a product's name.
    public func screen(_ name: String, title: String? = nil) async throws {
        try await send(prepared(Self.screenRequest(name: name, title: title, userID: nil, project: project)))
    }

    /// Forgets the current user and makes a new visitor id, for when someone signs out. Does nothing without `app`.
    public func reset() {
        app?.reset()
    }

    /// The random id this install of the app is known by; nil without `app`.
    public var visitorID: String? { app?.visitorID }

    /// The user from the last `identify`; nil without `app`, and after `reset()`.
    public var userID: String? { app?.userID }

    /// Describes a group such as a company, and puts `userID` in it when given.
    public func group(_ groupID: String, userID: String? = nil, properties: [String: EventValue] = [:]) async throws {
        try await send(Self.groupRequest(groupID: groupID, userID: userID, properties: properties, project: project))
    }

    /// Puts an address on the project's newsletter list. Signing it up again changes nothing.
    /// - Parameters:
    ///   - source: The page or screen the signup came from, such as `/blog/launch`.
    ///   - notify: Push the signup to the phones of everyone on the project.
    ///   - language: The person's language, as a tag such as `sv` or `sv-SE`.
    ///   - timezone: The person's time zone, as its IANA name, such as `Europe/Stockholm`.
    public func subscribe(_ email: String, name: String? = nil, properties: [String: EventValue] = [:], source: String? = nil, notify: Bool? = nil, language: String? = nil, timezone: String? = nil) async throws {
        try await send(Self.subscribeRequest(email: email, name: name, properties: properties, source: source, notify: notify, language: language, timezone: timezone, project: project))
    }

    /// Sets an insight to a value.
    public func setInsight(_ title: String, to value: EventValue, icon: String? = nil) async throws {
        try await send(Self.insightRequest(title: title, value: value, icon: icon, project: project))
    }

    /// Adds to an insight's number, starting from 0 if it has none. Negative subtracts.
    public func incrementInsight(_ title: String, by amount: EventValue = 1, icon: String? = nil) async throws {
        try await send(Self.incrementRequest(title: title, by: amount, icon: icon, project: project))
    }

    /// Which variant of an A/B test a person gets. The same person always gets the same one.
    /// When `disabled` is set it is the first variant and nothing is sent.
    /// - Parameters:
    ///   - variants: Two to eight names. The first is the one the others are measured against; keep the order the same everywhere.
    ///   - userID: The person, when they are known. An app with a public key may leave it out: the device is then the visitor.
    ///   - ip: From a server, for someone with no id: their address, which is not stored.
    ///   - userAgent: Sent along with `ip`.
    public func experiment(_ name: String, variants: [String], userID: String? = nil, ip: String? = nil, userAgent: String? = nil) async throws -> String {
        let first = variants.first ?? ""
        if disabled { return first }
        let data = try await deliver(Self.experimentRequest(name: name, variants: variants, userID: userID, ip: ip, userAgent: userAgent, project: project))
        if case .object(let fields)? = try? JSONDecoder().decode(JSON.self, from: data), case .string(let variant)? = fields["variant"] { return variant }
        return first
    }

    // The requests are built apart from sending them, so the conformance tests can check the wire format without a server.

    public static func request(for event: Track, project: String) -> WireRequest {
        var body: [String: JSON] = ["project": .string(project), "channel": .string(event.channel), "event": .string(event.event)]
        if let value = event.description { body["description"] = .string(value) }
        if let value = event.userID { body["user_id"] = .string(value) }
        if let value = event.icon { body["icon"] = .string(value) }
        if let value = event.notify { body["notify"] = .bool(value) }
        if !event.tags.isEmpty { body["tags"] = .object(event.tags.mapValues(\.json)) }
        if let value = event.parser { body["parser"] = .string(value.rawValue) }
        if let value = event.timestamp { body["timestamp"] = .integer(Int(value.timeIntervalSince1970)) }
        return WireRequest(method: "POST", path: "/v1/log", body: .object(body))
    }

    public static func identifyRequest(userID: String, properties: [String: EventValue], project: String) -> WireRequest {
        WireRequest(method: "POST", path: "/v1/identify", body: .object(["project": .string(project), "user_id": .string(userID), "properties": .object(properties.mapValues(\.json))]))
    }

    public static func screenRequest(name: String, title: String?, userID: String?, project: String) -> WireRequest {
        var body: [String: JSON] = ["project": .string(project)]
        if let userID { body["user_id"] = .string(userID) }
        var payload: [String: JSON] = ["path": .string(name)]
        if let title { payload["title"] = .string(title) }
        body["payload"] = .object(payload)
        return WireRequest(method: "POST", path: "/v1/page", body: .object(body))
    }

    public static func groupRequest(groupID: String, userID: String?, properties: [String: EventValue], project: String) -> WireRequest {
        var body: [String: JSON] = ["project": .string(project), "group_id": .string(groupID)]
        if let userID { body["user_id"] = .string(userID) }
        if !properties.isEmpty { body["properties"] = .object(properties.mapValues(\.json)) }
        return WireRequest(method: "POST", path: "/v1/group", body: .object(body))
    }

    public static func subscribeRequest(email: String, name: String?, properties: [String: EventValue], source: String?, notify: Bool?, language: String? = nil, timezone: String? = nil, project: String) -> WireRequest {
        var body: [String: JSON] = ["project": .string(project), "email": .string(email)]
        if let name { body["name"] = .string(name) }
        if !properties.isEmpty { body["properties"] = .object(properties.mapValues(\.json)) }
        if let source { body["source"] = .string(source) }
        if let notify { body["notify"] = .bool(notify) }
        if let language { body["language"] = .string(language) }
        if let timezone { body["timezone"] = .string(timezone) }
        return WireRequest(method: "POST", path: "/v1/subscribe", body: .object(body))
    }

    public static func experimentRequest(name: String, variants: [String], userID: String?, ip: String?, userAgent: String?, project: String) -> WireRequest {
        var body: [String: JSON] = ["project": .string(project), "experiment": .string(name), "variants": .array(variants.map(JSON.string))]
        if let userID { body["user_id"] = .string(userID) }
        if let ip { body["ip"] = .string(ip) }
        if let userAgent { body["user_agent"] = .string(userAgent) }
        return WireRequest(method: "POST", path: "/v1/experiment", body: .object(body))
    }

    public static func insightRequest(title: String, value: EventValue, icon: String?, project: String) -> WireRequest {
        var body: [String: JSON] = ["project": .string(project), "title": .string(title), "value": value.json]
        if let icon { body["icon"] = .string(icon) }
        return WireRequest(method: "POST", path: "/v1/insight", body: .object(body))
    }

    public static func incrementRequest(title: String, by amount: EventValue, icon: String?, project: String) -> WireRequest {
        var body: [String: JSON] = ["project": .string(project), "title": .string(title), "value": .object(["$inc": amount.json])]
        if let icon { body["icon"] = .string(icon) }
        return WireRequest(method: "PATCH", path: "/v1/insight", body: .object(body))
    }

    /// A request with what the app side adds to it; the request itself when there is no app side.
    func prepared(_ wire: WireRequest) -> WireRequest {
        app?.adding(to: wire) ?? wire
    }

    // The automatic events. One that cannot be sent has nobody to tell, so it is dropped, or kept if there is a queue.

    /// A cold start: an install or an update when it is one, and an open.
    func launch() async {
        for event in app?.launched() ?? [] { try? await track(event) }
    }

    func resignedActive() {
        app?.resignedActive()
    }

    /// The app is in front again, which is an open if it was away long enough.
    func becameActive() async {
        for event in app?.becameActive() ?? [] { try? await track(event) }
    }

    private func send(_ wire: WireRequest, keeping kept: WireRequest? = nil) async throws {
        if disabled { return }
        guard let queue else {
            _ = try await deliver(wire)
            return
        }
        // What is already waiting goes first. If it cannot, this one waits behind it, so nothing arrives out of order.
        guard await queue.drain({ _ = try await self.deliver($0) }) else {
            await queue.add(kept ?? wire)
            return
        }
        do {
            _ = try await deliver(wire)
        } catch let error as SnekotError {
            if case .refused = error { throw error }
            await queue.add(kept ?? wire)
        }
    }

    /// Sends one request, with one retry, and gives back the body the server answered with.
    private func deliver(_ wire: WireRequest) async throws -> Data {
        var request = URLRequest(url: endpoint.appendingPathComponent(wire.path), timeoutInterval: timeout)
        request.httpMethod = wire.method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(wire.body)

        // One retry, and only where trying again can help: the network failed or the server did. A refusal is final.
        var retried = false
        while true {
            let failure: SnekotError
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status) { return data }
                if status < 500 {
                    let message: String
                    if case .object(let fields)? = try? JSONDecoder().decode(JSON.self, from: data), case .string(let text)? = fields["error"] { message = text } else { message = "The server answered \(status)." }
                    throw SnekotError.refused(status: status, message: message)
                }
                failure = .server(status: status)
            } catch let error as SnekotError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = .unreachable(error.localizedDescription)
            }
            if retried { throw failure }
            retried = true
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }
}
