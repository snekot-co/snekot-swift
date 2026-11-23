import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// What an app says about itself and the device it runs on. It goes along with every event and screen.
///
/// None of it needs a permission prompt, and none of it names the device or the person: there is no advertising
/// identifier, no vendor identifier, no device name and no location.
public struct AppDetails: Sendable, Equatable {
    /// The version people see, such as `2.4.1`.
    public var version: String?
    /// The build number, such as `312`.
    public var build: String?
    /// `iOS`, `iPadOS`, `macOS`, `tvOS`, `watchOS` or `visionOS`.
    public var os: String?
    /// Such as `18.2`; the patch number is there only when it is not zero.
    public var osVersion: String?
    /// The hardware's own name for itself, such as `iPhone16,1`.
    public var model: String?
    /// `phone`, `tablet`, `desktop`, `tv`, `watch` or `headset`.
    public var kind: String?
    /// The person's first preferred language, such as `sv-SE`.
    public var language: String?
    /// The screen's size in points, where it can be known.
    public var screenWidth: Int?
    public var screenHeight: Int?

    public init(version: String? = nil, build: String? = nil, os: String? = nil, osVersion: String? = nil, model: String? = nil, kind: String? = nil, language: String? = nil, screenWidth: Int? = nil, screenHeight: Int? = nil) {
        self.version = version
        self.build = build
        self.os = os
        self.osVersion = osVersion
        self.model = model
        self.kind = kind
        self.language = language
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
    }

    /// The details of this app on this device. They are collected once and kept.
    public static var current: AppDetails {
        var details = collected
        if let size = screen.value ?? measured() {
            details.screenWidth = size.width
            details.screenHeight = size.height
        }
        return details
    }

    /// The `app` object as it goes on the wire. What is not known is left out.
    var json: JSON {
        var fields: [String: JSON] = [:]
        if let version { fields["version"] = .string(version) }
        if let build { fields["build"] = .string(build) }
        if let os { fields["os"] = .string(os) }
        if let osVersion { fields["os_version"] = .string(osVersion) }
        if let model { fields["model"] = .string(model) }
        if let kind { fields["kind"] = .string(kind) }
        if let language { fields["language"] = .string(language) }
        if let screenWidth { fields["screen_width"] = .integer(screenWidth) }
        if let screenHeight { fields["screen_height"] = .integer(screenHeight) }
        return .object(fields)
    }

    /// `18.2` for 18.2.0, `18.2.1` for 18.2.1.
    static func versionText(_ version: OperatingSystemVersion) -> String {
        var text = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion != 0 { text += ".\(version.patchVersion)" }
        return text
    }

    // Everything but the screen can be read from any thread, so it is read once, the first time it is asked for.
    private static let collected: AppDetails = {
        var details = AppDetails()
        let info = Bundle.main.infoDictionary
        details.version = info?["CFBundleShortVersionString"] as? String
        details.build = info?["CFBundleVersion"] as? String
        details.osVersion = versionText(ProcessInfo.processInfo.operatingSystemVersion)
        details.language = Locale.preferredLanguages.first
        #if os(macOS) || targetEnvironment(macCatalyst)
        details.model = sysctl("hw.model")
        details.os = "macOS"
        details.kind = "desktop"
        #elseif os(tvOS)
        details.model = machine()
        details.os = "tvOS"
        details.kind = "tv"
        #elseif os(watchOS)
        details.model = machine()
        details.os = "watchOS"
        details.kind = "watch"
        #elseif os(visionOS)
        details.model = machine()
        details.os = "visionOS"
        details.kind = "headset"
        #elseif os(iOS)
        if ProcessInfo.processInfo.isiOSAppOnMac {
            // An iPhone or iPad app that someone runs on a Mac.
            details.model = sysctl("hw.model")
            details.os = "macOS"
            details.kind = "desktop"
        } else {
            details.model = machine()
            let tablet = details.model?.hasPrefix("iPad") ?? false
            details.os = tablet ? "iPadOS" : "iOS"
            details.kind = tablet ? "tablet" : "phone"
        }
        #endif
        return details
    }()

    #if canImport(Darwin)
    /// The device's hardware identifier. A simulator answers with the Mac's, so there it is the simulated device's instead.
    private static func machine() -> String? {
        ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? sysctl("hw.machine")
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let text = String(cString: buffer)
        return text.isEmpty ? nil : text
    }
    #endif

    // The screen can only be asked about on the main thread, so it is read there the first time there is a chance.
    private static let screen = Locked<ScreenSize?>(nil)

    struct ScreenSize: Sendable { let width: Int; let height: Int }

    /// The screen's size, read now if this is the main thread; nil when it cannot be read from here or at all.
    private static func measured() -> ScreenSize? {
        #if canImport(UIKit) && !os(watchOS) && !os(visionOS)
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated { measureScreen() }
        #else
        return nil
        #endif
    }

    #if canImport(UIKit) && !os(watchOS) && !os(visionOS)
    @MainActor @discardableResult
    static func measureScreen() -> ScreenSize? {
        if let known = screen.value { return known }
        let bounds = UIScreen.main.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let size = ScreenSize(width: Int(bounds.width), height: Int(bounds.height))
        screen.set(size)
        return size
    }
    #endif
}

/// Where the app side keeps its few small values between launches. `UserDefaults` is one; `MemoryStore` is another.
public protocol AppStore: Sendable {
    func text(for key: String) -> String?
    /// Keeps a value, or forgets the key when the value is nil.
    func keep(_ value: String?, for key: String)
}

extension UserDefaults: AppStore {
    public func text(for key: String) -> String? { string(forKey: key) }
    public func keep(_ value: String?, for key: String) {
        if let value { set(value, forKey: key) } else { removeObject(forKey: key) }
    }
}

/// A store that forgets everything when the app quits, for tests and previews.
public final class MemoryStore: AppStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]

    public init(_ values: [String: String] = [:]) { self.values = values }

    public func text(for key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    public func keep(_ value: String?, for key: String) { lock.lock(); values[key] = value; lock.unlock() }
}

/// The app side of the client: who is using the app, what the app and device are, and the events an app sends by
/// itself. Give one to `SnekotEvents(…, app:)` and every event and screen carries a visitor id and the app's
/// details, and installs, updates and opens are posted to the `app` channel with no further code.
///
/// ```swift
/// let snekot = SnekotEvents(token: token, project: "acme-store", queue: OfflineQueue(), app: AppAnalytics())
/// ```
///
/// Create it once, when the app starts, and keep the client for as long as the app runs.
public final class AppAnalytics: @unchecked Sendable {
    /// The events an app sends by itself. All of them by default; leave one out to switch it off, or pass `[]` for none.
    public struct Lifecycle: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// `App installed`: the first launch on this device.
        public static let installed = Lifecycle(rawValue: 1)
        /// `App updated`: the first launch of a new version or build.
        public static let updated = Lifecycle(rawValue: 2)
        /// `App opened`: a cold start, or coming back after 30 minutes or more away.
        public static let opened = Lifecycle(rawValue: 4)
        public static let all: Lifecycle = [.installed, .updated, .opened]
    }

    static let visitorKey = "co.snekot.visitor"
    static let userKey = "co.snekot.user"
    static let versionKey = "co.snekot.version"
    static let buildKey = "co.snekot.build"

    private let lock = NSLock()
    private let fixed: AppDetails?
    private let store: AppStore
    private let lifecycle: Lifecycle
    private let automatic: Bool
    private var visitor: String
    private var user: String?
    private var launches: AppLifecycle
    private var started = false

    /// - Parameters:
    ///   - details: What to say about the app and the device. This device's own details if left out.
    ///   - store: Where the visitor id, the current user and the last seen version are kept. `UserDefaults.standard` by default.
    ///   - lifecycle: Which of the automatic events are sent.
    ///   - now: The clock, for tests.
    public convenience init(details: AppDetails? = nil, store: AppStore = UserDefaults.standard, lifecycle: Lifecycle = .all, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(details: details, store: store, lifecycle: lifecycle, now: now, automatic: true)
    }

    /// With `automatic` off nothing is sent or listened for until a test says the app launched or came back.
    init(details: AppDetails?, store: AppStore, lifecycle: Lifecycle = .all, now: @escaping @Sendable () -> Date = { Date() }, automatic: Bool) {
        self.fixed = details
        self.store = store
        self.lifecycle = lifecycle
        self.automatic = automatic
        // Whether this is the first launch is settled here, before the visitor id below is stored.
        self.launches = AppLifecycle(store: store, now: now)
        if let kept = store.text(for: Self.visitorKey), Self.isVisitorID(kept) {
            self.visitor = kept
        } else {
            self.visitor = Self.newVisitorID()
            store.keep(self.visitor, for: Self.visitorKey)
        }
        self.user = store.text(for: Self.userKey)
    }

    /// The random id this install of the app is known by. It is made on the first launch and changes on `reset()`.
    public var visitorID: String { lock.lock(); defer { lock.unlock() }; return visitor }

    /// The user from the last `identify`, if there has been one since the last `reset()`.
    public var userID: String? { lock.lock(); defer { lock.unlock() }; return user }

    /// The details that go along with every event and screen.
    public var details: AppDetails { fixed ?? AppDetails.current }

    /// `r_` and 22 random characters. It is not derived from the device, so it says nothing about it.
    static func newVisitorID() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let text = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "r_" + text
    }

    static func isVisitorID(_ text: String) -> Bool {
        guard text.hasPrefix("r_") else { return false }
        let rest = text.dropFirst(2)
        return (16...40).contains(rest.count) && rest.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    func remember(user id: String) {
        lock.lock(); user = id; lock.unlock()
        store.keep(id, for: Self.userKey)
    }

    func reset() {
        let fresh = Self.newVisitorID()
        lock.lock(); user = nil; visitor = fresh; lock.unlock()
        store.keep(nil, for: Self.userKey)
        store.keep(fresh, for: Self.visitorKey)
    }

    /// Adds what the app knows to a request on its way out: the visitor, the current user where none is named, and the app's details.
    func adding(to wire: WireRequest) -> WireRequest {
        guard case .object(var body) = wire.body else { return wire }
        lock.lock()
        let visitor = self.visitor, user = self.user
        lock.unlock()
        switch wire.path {
        case "/v1/log", "/v1/page":
            if body["user_id"] == nil, let user { body["user_id"] = .string(user) }
            body["visitor_id"] = .string(visitor)
            body["app"] = details.json
        case "/v1/identify":
            body["visitor_id"] = .string(visitor)
        default:
            return wire
        }
        return WireRequest(method: wire.method, path: wire.path, body: .object(body))
    }

    // MARK: Lifecycle

    /// The events for this launch that are switched on, as they are posted.
    func launched() -> [Track] {
        let details = self.details
        lock.lock()
        let events = launches.launched(version: details.version, build: details.build)
        lock.unlock()
        return events.compactMap(track)
    }

    func resignedActive() {
        lock.lock(); launches.resignedActive(); lock.unlock()
    }

    func becameActive() -> [Track] {
        lock.lock()
        let events = launches.becameActive()
        lock.unlock()
        return events.compactMap(track)
    }

    private func track(_ event: AppLifecycle.Event) -> Track? {
        switch event {
        case .installed:
            return lifecycle.contains(.installed) ? Track(channel: "app", event: "App installed", icon: "📲") : nil
        case .updated(let from, let to, let fromBuild, let toBuild):
            guard lifecycle.contains(.updated) else { return nil }
            var tags: [String: EventValue] = [:]
            if let from { tags["from"] = .text(from) }
            if let to { tags["to"] = .text(to) }
            if let fromBuild { tags["from_build"] = .text(fromBuild) }
            if let toBuild { tags["to_build"] = .text(toBuild) }
            return Track(channel: "app", event: "App updated", icon: "🆙", tags: tags)
        case .opened:
            return lifecycle.contains(.opened) ? Track(channel: "app", event: "App opened", icon: "📱") : nil
        }
    }

    /// Sends this launch's events and starts listening for the app coming back. Only the first client given this
    /// object does it, so a copy of the client never counts a launch twice.
    func start(_ client: SnekotEvents) {
        guard automatic else { return }
        lock.lock()
        let first = !started
        started = true
        lock.unlock()
        guard first else { return }
        Task {
            await Self.listen(client)
            await client.launch()
        }
    }

    @MainActor
    private static func listen(_ client: SnekotEvents) {
        #if canImport(UIKit) && !os(watchOS)
        #if !os(visionOS)
        AppDetails.measureScreen()
        #endif
        // The observers are never removed: the client lives as long as the app does.
        let center = NotificationCenter.default
        _ = center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { _ in
            client.resignedActive()
        }
        _ = center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            Task { await client.becameActive() }
        }
        #endif
    }
}

/// The rules for installs, updates and opens, apart from the app and the network so they can be tested with a
/// clock and a store of their own.
struct AppLifecycle {
    enum Event: Equatable {
        case installed
        case updated(from: String?, to: String?, fromBuild: String?, toBuild: String?)
        case opened
    }

    /// Coming back after this long away counts as opening the app again.
    static let away: TimeInterval = 30 * 60

    private let store: AppStore
    private let now: @Sendable () -> Date
    private var first: Bool
    private var left: Date?

    /// Make it before anything else is written to the store: a first launch is one that finds nothing there.
    init(store: AppStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
        self.first = store.text(for: AppAnalytics.visitorKey) == nil && store.text(for: AppAnalytics.versionKey) == nil && store.text(for: AppAnalytics.buildKey) == nil
    }

    /// What a cold start with this version and build means, and remembers them for the next one.
    mutating func launched(version: String?, build: String?) -> [Event] {
        let oldVersion = store.text(for: AppAnalytics.versionKey), oldBuild = store.text(for: AppAnalytics.buildKey)
        var events: [Event] = []
        if first {
            events.append(.installed)
        } else if Self.changed(from: oldVersion, oldBuild, to: version, build) {
            events.append(.updated(from: oldVersion, to: version, fromBuild: oldBuild, toBuild: build))
        }
        first = false
        if let version { store.keep(version, for: AppAnalytics.versionKey) }
        if let build { store.keep(build, for: AppAnalytics.buildKey) }
        events.append(.opened)
        return events
    }

    /// An update is a version or build that is known now and is not the one that was kept. With nothing kept there
    /// is nothing to have been updated from.
    static func changed(from oldVersion: String?, _ oldBuild: String?, to version: String?, _ build: String?) -> Bool {
        guard oldVersion != nil || oldBuild != nil else { return false }
        return (version != nil && version != oldVersion) || (build != nil && build != oldBuild)
    }

    mutating func resignedActive() {
        left = now()
    }

    /// Nothing after a short while away, and nothing right after a cold start, which has already been counted.
    mutating func becameActive() -> [Event] {
        guard let left else { return [] }
        self.left = nil
        return Self.isOpen(left: left, back: now()) ? [.opened] : []
    }

    static func isOpen(left: Date, back: Date) -> Bool {
        back.timeIntervalSince(left) >= away
    }
}

/// A value behind a lock.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ value: Value) { lock.lock(); stored = value; lock.unlock() }
}
