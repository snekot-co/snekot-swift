import Foundation
import XCTest
@testable import SnekotEvents

/// The app side: what it adds to the wire, and when it posts installs, updates and opens.
final class AppAnalyticsTests: XCTestCase {
    let visitor = "r_AAAAAAAAAAAAAAAAAAAAAA"
    let details = AppDetails(version: "2.4.1", build: "312", os: "iOS", osVersion: "18.2", model: "iPhone16,1", kind: "phone", language: "sv-SE", screenWidth: 393, screenHeight: 852)
    let appJSON: JSON = .object([
        "version": .string("2.4.1"), "build": .string("312"), "os": .string("iOS"), "os_version": .string("18.2"), "model": .string("iPhone16,1"),
        "kind": .string("phone"), "language": .string("sv-SE"), "screen_width": .integer(393), "screen_height": .integer(852),
    ])

    override func setUp() { Recorder.reset() }

    /// A store as a launch of 2.4.1 (312) leaves it.
    func settled() -> MemoryStore {
        MemoryStore([AppAnalytics.visitorKey: visitor, AppAnalytics.versionKey: "2.4.1", AppAnalytics.buildKey: "312"])
    }

    func client(_ store: MemoryStore, lifecycle: AppAnalytics.Lifecycle = .all, now: @escaping @Sendable () -> Date = { Date() }) -> SnekotEvents {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Recorder.self]
        let app = AppAnalytics(details: details, store: store, lifecycle: lifecycle, now: now, automatic: false)
        return SnekotEvents(token: "pk_test", project: "acme-store", endpoint: URL(string: "http://recorder.test")!, session: URLSession(configuration: configuration), app: app)
    }

    // MARK: The wire

    func testAnEventCarriesTheVisitorAndTheAppsDetails() async throws {
        let snekot = client(settled())
        try await snekot.track(channel: "payments", event: "New subscription", icon: "💰", tags: ["plan": "pro"])
        XCTAssertEqual(Recorder.requests(), [Recorded(method: "POST", path: "/v1/log", body: .object([
            "project": .string("acme-store"), "channel": .string("payments"), "event": .string("New subscription"), "icon": .string("💰"),
            "tags": .object(["plan": .string("pro")]), "visitor_id": .string(visitor), "app": appJSON,
        ]))])
    }

    func testAScreenIsAPage() async throws {
        let snekot = client(settled())
        try await snekot.identify(userID: "user-123", properties: [:])
        try await snekot.screen("Checkout", title: "Your basket")
        try await snekot.screen("Home")
        XCTAssertEqual(Array(Recorder.requests().dropFirst()), [
            Recorded(method: "POST", path: "/v1/page", body: .object([
                "project": .string("acme-store"), "user_id": .string("user-123"), "visitor_id": .string(visitor),
                "payload": .object(["path": .string("Checkout"), "title": .string("Your basket")]), "app": appJSON,
            ])),
            Recorded(method: "POST", path: "/v1/page", body: .object([
                "project": .string("acme-store"), "user_id": .string("user-123"), "visitor_id": .string(visitor),
                "payload": .object(["path": .string("Home")]), "app": appJSON,
            ])),
        ])
    }

    func testIdentifyCarriesTheVisitorAndIsRemembered() async throws {
        let store = settled()
        let snekot = client(store)
        try await snekot.identify(userID: "user-123", properties: ["plan": "pro"])
        try await snekot.track(channel: "orders", event: "Order placed")
        try await snekot.track(channel: "orders", event: "Gift sent", userID: "user-456")
        let requests = Recorder.requests()
        XCTAssertEqual(requests[0], Recorded(method: "POST", path: "/v1/identify", body: .object([
            "project": .string("acme-store"), "user_id": .string("user-123"), "visitor_id": .string(visitor), "properties": .object(["plan": .string("pro")]),
        ])))
        XCTAssertEqual(requests[1].body["user_id"], .string("user-123"), "an event that names nobody is from the current user")
        XCTAssertEqual(requests[2].body["user_id"], .string("user-456"), "an event that names someone keeps them")
        XCTAssertEqual(store.text(for: "co.snekot.user"), "user-123")

        // The next launch still knows who is signed in.
        XCTAssertEqual(client(store).userID, "user-123")
    }

    func testOtherCallsAreLeftAlone() async throws {
        let snekot = client(settled())
        try await snekot.group("acme", userID: "user-123")
        try await snekot.setInsight("MRR", to: "$1,289")
        XCTAssertEqual(Recorder.requests().map(\.body), [
            .object(["project": .string("acme-store"), "group_id": .string("acme"), "user_id": .string("user-123")]),
            .object(["project": .string("acme-store"), "title": .string("MRR"), "value": .string("$1,289")]),
        ])
    }

    func testThePlainClientSendsWhatItAlwaysDid() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Recorder.self]
        let plain = SnekotEvents(token: "sk_test", project: "acme-store", endpoint: URL(string: "http://recorder.test")!, session: URLSession(configuration: configuration))
        try await plain.identify(userID: "user-123", properties: ["plan": "pro"])
        try await plain.track(channel: "payments", event: "New subscription")
        try await plain.screen("Checkout")
        plain.reset()
        XCTAssertNil(plain.visitorID)
        XCTAssertNil(plain.userID)
        XCTAssertEqual(Recorder.requests(), [
            Recorded(method: "POST", path: "/v1/identify", body: .object(["project": .string("acme-store"), "user_id": .string("user-123"), "properties": .object(["plan": .string("pro")])])),
            Recorded(method: "POST", path: "/v1/log", body: .object(["project": .string("acme-store"), "channel": .string("payments"), "event": .string("New subscription")])),
            Recorded(method: "POST", path: "/v1/page", body: .object(["project": .string("acme-store"), "payload": .object(["path": .string("Checkout")])])),
        ])
    }

    func testAKeptEventKeepsTheVisitorItHappenedUnder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("snekot-tests-" + UUID().uuidString)
        let app = AppAnalytics(details: details, store: settled(), automatic: false)
        let offline = SnekotEvents(token: "pk_test", project: "acme-store", endpoint: URL(string: "http://127.0.0.1:1")!, timeout: 2, queue: OfflineQueue(directory: directory), app: app)
        try await offline.screen("Checkout")
        offline.reset()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Recorder.self]
        let online = SnekotEvents(token: "pk_test", project: "acme-store", endpoint: URL(string: "http://recorder.test")!, session: URLSession(configuration: configuration), queue: OfflineQueue(directory: directory), app: app)
        await online.flush()
        XCTAssertEqual(Recorder.requests().map(\.path), ["/v1/page"])
        XCTAssertEqual(Recorder.requests()[0].body["visitor_id"], .string(visitor))
    }

    // MARK: The visitor and the user

    func testAVisitorIDIsMadeOnceAndKept() {
        let store = MemoryStore()
        let first = client(store).visitorID!
        XCTAssertNotNil(first.range(of: "^r_[A-Za-z0-9_-]{22}$", options: .regularExpression), first)
        XCTAssertEqual(store.text(for: "co.snekot.visitor"), first)
        XCTAssertEqual(client(store).visitorID, first)
        XCTAssertNotEqual(client(MemoryStore()).visitorID, first)
    }

    func testResetMakesANewVisitorAndForgetsTheUser() async throws {
        let store = settled()
        let snekot = client(store)
        try await snekot.identify(userID: "user-123", properties: [:])
        snekot.reset()
        let fresh = snekot.visitorID!
        XCTAssertNotEqual(fresh, visitor)
        XCTAssertNotNil(fresh.range(of: "^r_[A-Za-z0-9_-]{16,40}$", options: .regularExpression), fresh)
        XCTAssertNil(snekot.userID)
        XCTAssertEqual(store.text(for: "co.snekot.visitor"), fresh)
        XCTAssertNil(store.text(for: "co.snekot.user"))

        try await snekot.track(channel: "auth", event: "Signed out")
        let body = Recorder.requests().last!.body
        XCTAssertEqual(body["visitor_id"], .string(fresh))
        XCTAssertNil(body["user_id"])
    }

    // MARK: Installs, updates and opens

    func testTheFirstLaunchIsAnInstallAndAnOpen() async {
        let store = MemoryStore()
        let snekot = client(store)
        await snekot.launch()
        let requests = Recorder.requests()
        XCTAssertEqual(requests.map(\.body["event"]), [.string("App installed"), .string("App opened")])
        XCTAssertEqual(requests[0], Recorded(method: "POST", path: "/v1/log", body: .object([
            "project": .string("acme-store"), "channel": .string("app"), "event": .string("App installed"), "icon": .string("📲"),
            "visitor_id": .string(snekot.visitorID!), "app": appJSON,
        ])))
        XCTAssertEqual(requests[1].body["icon"], .string("📱"))
        XCTAssertEqual(requests[1].body["channel"], .string("app"))
        XCTAssertEqual(store.text(for: "co.snekot.version"), "2.4.1")
        XCTAssertEqual(store.text(for: "co.snekot.build"), "312")
    }

    func testANewVersionIsAnUpdateAndAnOpen() async {
        let store = MemoryStore([AppAnalytics.visitorKey: visitor, AppAnalytics.versionKey: "2.4.0", AppAnalytics.buildKey: "311"])
        await client(store).launch()
        let requests = Recorder.requests()
        XCTAssertEqual(requests.map(\.body["event"]), [.string("App updated"), .string("App opened")])
        XCTAssertEqual(requests[0], Recorded(method: "POST", path: "/v1/log", body: .object([
            "project": .string("acme-store"), "channel": .string("app"), "event": .string("App updated"), "icon": .string("🆙"),
            "tags": .object(["from": .string("2.4.0"), "to": .string("2.4.1"), "from_build": .string("311"), "to_build": .string("312")]),
            "visitor_id": .string(visitor), "app": appJSON,
        ])))
        XCTAssertEqual(store.text(for: "co.snekot.version"), "2.4.1")
        XCTAssertEqual(store.text(for: "co.snekot.build"), "312")
    }

    func testANewBuildOfTheSameVersionIsAnUpdate() async {
        let store = MemoryStore([AppAnalytics.visitorKey: visitor, AppAnalytics.versionKey: "2.4.1", AppAnalytics.buildKey: "311"])
        await client(store).launch()
        XCTAssertEqual(Recorder.requests().map(\.body["event"]), [.string("App updated"), .string("App opened")])
    }

    func testTheSameVersionIsOnlyAnOpen() async {
        let store = settled()
        await client(store).launch()
        XCTAssertEqual(Recorder.requests().map(\.body["event"]), [.string("App opened")])
    }

    func testEachAutomaticEventCanBeSwitchedOff() async {
        await client(MemoryStore(), lifecycle: [.opened]).launch()
        XCTAssertEqual(Recorder.requests().map(\.body["event"]), [.string("App opened")])

        Recorder.reset()
        let store = MemoryStore()
        await client(store, lifecycle: []).launch()
        XCTAssertEqual(Recorder.requests(), [])
        XCTAssertEqual(store.text(for: "co.snekot.version"), "2.4.1", "the version is remembered even when nothing is sent")
    }

    func testComingBackAfterLongEnoughIsAnOpen() async {
        let clock = Clock()
        let snekot = client(settled(), now: { clock.now })
        await snekot.launch()
        Recorder.reset()

        // Right after a cold start the app becomes active for the first time. That open is already counted.
        await snekot.becameActive()
        XCTAssertEqual(Recorder.requests(), [])

        snekot.resignedActive()
        clock.advance(minutes: 5)
        await snekot.becameActive()
        XCTAssertEqual(Recorder.requests(), [], "5 minutes away is the same visit")

        snekot.resignedActive()
        clock.advance(minutes: 31)
        await snekot.becameActive()
        XCTAssertEqual(Recorder.requests().map(\.body["event"]), [.string("App opened")])

        // Becoming active twice without leaving in between counts once.
        await snekot.becameActive()
        XCTAssertEqual(Recorder.requests().count, 1)
    }

    func testTheRulesNeedNoAppAndNoNetwork() {
        let clock = Clock()
        let store = MemoryStore()
        var first = AppLifecycle(store: store, now: { clock.now })
        XCTAssertEqual(first.launched(version: "1.0", build: "1"), [.installed, .opened])

        var second = AppLifecycle(store: store, now: { clock.now })
        XCTAssertEqual(second.launched(version: "1.0", build: "1"), [.opened])

        var third = AppLifecycle(store: store, now: { clock.now })
        XCTAssertEqual(third.launched(version: "1.1", build: "2"), [.updated(from: "1.0", to: "1.1", fromBuild: "1", toBuild: "2"), .opened])
        third.resignedActive()
        clock.advance(minutes: 29)
        XCTAssertEqual(third.becameActive(), [])
        third.resignedActive()
        clock.advance(minutes: 30)
        XCTAssertEqual(third.becameActive(), [.opened])

        // An app with no version is installed once, not on every launch: the visitor id shows it has run before.
        let bare = MemoryStore()
        var once = AppLifecycle(store: bare)
        XCTAssertEqual(once.launched(version: nil, build: nil), [.installed, .opened])
        bare.keep(visitor, for: AppAnalytics.visitorKey)
        var again = AppLifecycle(store: bare)
        XCTAssertEqual(again.launched(version: nil, build: nil), [.opened])

        XCTAssertFalse(AppLifecycle.changed(from: nil, nil, to: "1.0", "1"))
        XCTAssertFalse(AppLifecycle.changed(from: "1.0", "1", to: nil, nil))
        XCTAssertTrue(AppLifecycle.changed(from: "1.0", nil, to: "1.0", "1"))
    }

    // MARK: The details

    func testTheDetailsOfThisMachine() {
        let details = AppDetails.current
        XCTAssertEqual(details, AppDetails.current, "collected once")
        #if os(macOS)
        XCTAssertEqual(details.os, "macOS")
        XCTAssertEqual(details.kind, "desktop")
        XCTAssertNil(details.screenWidth)
        XCTAssertFalse((details.model ?? "").isEmpty)
        #endif
        XCTAssertNotNil(details.osVersion?.range(of: #"^\d+\.\d+(\.\d+)?$"#, options: .regularExpression))
    }

    func testTheSystemsVersionLeavesOutAZeroPatch() {
        XCTAssertEqual(AppDetails.versionText(OperatingSystemVersion(majorVersion: 18, minorVersion: 2, patchVersion: 0)), "18.2")
        XCTAssertEqual(AppDetails.versionText(OperatingSystemVersion(majorVersion: 18, minorVersion: 2, patchVersion: 1)), "18.2.1")
        XCTAssertEqual(AppDetails.versionText(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)), "26.0")
    }

    func testWhatIsNotKnownIsLeftOut() {
        XCTAssertEqual(AppDetails(version: "1.0", os: "macOS").json, .object(["version": .string("1.0"), "os": .string("macOS")]))
    }
}

/// A clock a test moves by hand.
final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var moment = Date(timeIntervalSince1970: 1_700_000_000)

    var now: Date { lock.lock(); defer { lock.unlock() }; return moment }
    func advance(minutes: Double) { lock.lock(); moment.addTimeInterval(minutes * 60); lock.unlock() }
}

struct Recorded: Equatable {
    let method: String
    let path: String
    let body: JSON
}

extension JSON {
    subscript(key: String) -> JSON? { if case .object(let fields) = self { return fields[key] } else { return nil } }
}

/// Answers every request with 200 and remembers the whole of what it was asked.
final class Recorder: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var seen: [Recorded] = []

    static func reset() { lock.lock(); seen = []; lock.unlock() }
    static func requests() -> [Recorded] { lock.lock(); defer { lock.unlock() }; return seen }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let read = stream.read(&buffer, maxLength: buffer.count); if read <= 0 { break }; data.append(buffer, count: read) }
            stream.close()
        }
        if let body = try? JSONDecoder().decode(JSON.self, from: data) {
            Recorder.lock.lock(); Recorder.seen.append(Recorded(method: request.httpMethod ?? "", path: request.url?.path ?? "", body: body)); Recorder.lock.unlock()
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
