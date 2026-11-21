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
public struct SnekotEvents: Sendable {
    public static let defaultEndpoint = URL(string: "https://api.snekot.co")!

    public let project: String
    private let token: String
    private let endpoint: URL
    private let session: URLSession
    private let timeout: TimeInterval
    private let disabled: Bool

    /// - Parameters:
    ///   - timeout: How long one attempt may take; 10 seconds by default.
    ///   - disabled: Makes every call succeed without sending anything, for previews and tests.
    public init(token: String, project: String, endpoint: URL = SnekotEvents.defaultEndpoint, timeout: TimeInterval = 10, disabled: Bool = false, session: URLSession = .shared) {
        self.token = token
        self.project = project
        self.endpoint = endpoint
        self.timeout = timeout
        self.disabled = disabled
        self.session = session
    }

    /// Posts an event to a channel.
    public func track(_ event: Track) async throws { try await send(Self.request(for: event, project: project)) }

    /// Posts an event to a channel.
    public func track(channel: String, event: String, description: String? = nil, userID: String? = nil, icon: String? = nil, notify: Bool? = nil, tags: [String: EventValue] = [:]) async throws {
        try await track(Track(channel: channel, event: event, description: description, userID: userID, icon: icon, notify: notify, tags: tags))
    }

    /// Sets properties on a user; keys sent again replace their old values.
    public func identify(userID: String, properties: [String: EventValue]) async throws {
        try await send(Self.identifyRequest(userID: userID, properties: properties, project: project))
    }

    /// Describes a group such as a company, and puts `userID` in it when given.
    public func group(_ groupID: String, userID: String? = nil, properties: [String: EventValue] = [:]) async throws {
        try await send(Self.groupRequest(groupID: groupID, userID: userID, properties: properties, project: project))
    }

    /// Puts an address on the project's newsletter list. Signing it up again changes nothing.
    /// - Parameters:
    ///   - source: The page or screen the signup came from, such as `/blog/launch`.
    ///   - notify: Push the signup to the phones of everyone on the project.
    public func subscribe(_ email: String, name: String? = nil, properties: [String: EventValue] = [:], source: String? = nil, notify: Bool? = nil) async throws {
        try await send(Self.subscribeRequest(email: email, name: name, properties: properties, source: source, notify: notify, project: project))
    }

    /// Sets an insight to a value.
    public func setInsight(_ title: String, to value: EventValue, icon: String? = nil) async throws {
        try await send(Self.insightRequest(title: title, value: value, icon: icon, project: project))
    }

    /// Adds to an insight's number, starting from 0 if it has none. Negative subtracts.
    public func incrementInsight(_ title: String, by amount: EventValue = 1, icon: String? = nil) async throws {
        try await send(Self.incrementRequest(title: title, by: amount, icon: icon, project: project))
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

    public static func groupRequest(groupID: String, userID: String?, properties: [String: EventValue], project: String) -> WireRequest {
        var body: [String: JSON] = ["project": .string(project), "group_id": .string(groupID)]
        if let userID { body["user_id"] = .string(userID) }
        if !properties.isEmpty { body["properties"] = .object(properties.mapValues(\.json)) }
        return WireRequest(method: "POST", path: "/v1/group", body: .object(body))
    }

    public static func subscribeRequest(email: String, name: String?, properties: [String: EventValue], source: String?, notify: Bool?, project: String) -> WireRequest {
        var body: [String: JSON] = ["project": .string(project), "email": .string(email)]
        if let name { body["name"] = .string(name) }
        if !properties.isEmpty { body["properties"] = .object(properties.mapValues(\.json)) }
        if let source { body["source"] = .string(source) }
        if let notify { body["notify"] = .bool(notify) }
        return WireRequest(method: "POST", path: "/v1/subscribe", body: .object(body))
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

    private func send(_ wire: WireRequest) async throws {
        if disabled { return }
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
                if (200..<300).contains(status) { return }
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
