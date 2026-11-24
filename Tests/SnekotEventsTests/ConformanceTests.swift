import Foundation
import XCTest
@testable import SnekotEvents

/// The shared cases in conformance.json: every call must put exactly that method, path and body on the wire.
final class ConformanceTests: XCTestCase {
    struct Suite: Decodable {
        struct Case: Decodable {
            struct Expect: Decodable { let method: String; let path: String; let body: JSON }
            let call: String
            let args: [String: JSON]
            let expect: Expect
        }
        let project: String
        let cases: [Case]
    }

    func value(_ json: JSON) -> EventValue {
        switch json {
        case .string(let text): return .text(text)
        case .integer(let number): return .integer(number)
        case .number(let number): return .number(number)
        case .bool(let flag): return .flag(flag)
        default: fatalError("not a value: \(json)")
        }
    }
    func text(_ json: JSON?) -> String? { if case .string(let value)? = json { return value } else { return nil } }
    func values(_ json: JSON?) -> [String: EventValue] { if case .object(let fields)? = json { return fields.mapValues(value) } else { return [:] } }

    func testEveryCaseMatchesTheWireFormat() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("conformance.json")
        let suite = try JSONDecoder().decode(Suite.self, from: Data(contentsOf: file))
        XCTAssertFalse(suite.cases.isEmpty)
        for entry in suite.cases {
            let args = entry.args
            let request: WireRequest
            switch entry.call {
            case "track":
                var event = Track(channel: text(args["channel"])!, event: text(args["event"])!)
                event.description = text(args["description"])
                event.userID = text(args["user_id"])
                event.icon = text(args["icon"])
                if case .bool(let notify)? = args["notify"] { event.notify = notify }
                event.tags = values(args["tags"])
                event.parser = text(args["parser"]).flatMap(Parser.init(rawValue:))
                if case .integer(let seconds)? = args["timestamp"] { event.timestamp = Date(timeIntervalSince1970: TimeInterval(seconds)) }
                request = SnekotEvents.request(for: event, project: suite.project)
            case "identify":
                request = SnekotEvents.identifyRequest(userID: text(args["user_id"])!, properties: values(args["properties"]), project: suite.project)
            case "group":
                request = SnekotEvents.groupRequest(groupID: text(args["group_id"])!, userID: text(args["user_id"]), properties: values(args["properties"]), project: suite.project)
            case "subscribe":
                var notify: Bool?
                if case .bool(let flag)? = args["notify"] { notify = flag }
                request = SnekotEvents.subscribeRequest(email: text(args["email"])!, name: text(args["name"]), properties: values(args["properties"]), source: text(args["source"]), notify: notify, language: text(args["language"]), timezone: text(args["timezone"]), project: suite.project)
            case "insight.track":
                request = SnekotEvents.insightRequest(title: text(args["title"])!, value: value(args["value"]!), icon: text(args["icon"]), project: suite.project)
            case "insight.increment":
                request = SnekotEvents.incrementRequest(title: text(args["title"])!, by: value(args["value"]!), icon: text(args["icon"]), project: suite.project)
            default:
                return XCTFail("unknown call \(entry.call)")
            }
            XCTAssertEqual(request.method, entry.expect.method, entry.call)
            XCTAssertEqual(request.path, entry.expect.path, entry.call)
            XCTAssertEqual(request.body, entry.expect.body, entry.call)
        }
    }

    func testDisabledSendsNothing() async throws {
        // The endpoint is unroutable, so this only passes if no request is made.
        let events = SnekotEvents(token: "sk_test", project: "p", endpoint: URL(string: "http://127.0.0.1:1")!, disabled: true)
        try await events.track(channel: "x", event: "y")
    }

    func testUnreachableIsReportedAfterOneRetry() async {
        let events = SnekotEvents(token: "sk_test", project: "p", endpoint: URL(string: "http://127.0.0.1:1")!, timeout: 2)
        let started = Date()
        do {
            try await events.track(channel: "x", event: "y")
            XCTFail("expected a failure")
        } catch let error as SnekotError {
            guard case .unreachable = error else { return XCTFail("expected unreachable, got \(error)") }
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.25)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testAnExperimentPutsItsQuestionOnTheWire() {
        let request = SnekotEvents.experimentRequest(name: "pricing", variants: ["control", "new"], userID: "user-1", ip: nil, userAgent: nil, project: "p")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/experiment")
        XCTAssertEqual(request.body, .object(["project": .string("p"), "experiment": .string("pricing"), "variants": .array([.string("control"), .string("new")]), "user_id": .string("user-1")]))
    }

    func testADisabledExperimentIsItsFirstVariant() async throws {
        let events = SnekotEvents(token: "sk_test", project: "p", endpoint: URL(string: "http://127.0.0.1:1")!, disabled: true)
        let variant = try await events.experiment("pricing", variants: ["control", "new"])
        XCTAssertEqual(variant, "control")
    }

    // MARK: The offline queue

    func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("snekot-tests-" + UUID().uuidString) }
    func stubbed() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return URLSession(configuration: configuration)
    }

    func testWhatCannotBeSentIsKeptAndSurvivesARestart() async throws {
        let directory = folder()
        let offline = SnekotEvents(token: "pk_test", project: "p", endpoint: URL(string: "http://127.0.0.1:1")!, timeout: 2, queue: OfflineQueue(directory: directory))
        try await offline.track(channel: "a", event: "first")
        try await offline.identify(userID: "u", properties: ["plan": "pro"])
        let reopened = OfflineQueue(directory: directory)
        let waiting = await reopened.count
        XCTAssertEqual(waiting, 2)
    }

    func testWhatWasKeptGoesOutFirstAndInOrder() async throws {
        let directory = folder()
        let offline = SnekotEvents(token: "sk_test", project: "p", endpoint: URL(string: "http://127.0.0.1:1")!, timeout: 2, queue: OfflineQueue(directory: directory))
        try await offline.track(channel: "a", event: "first")
        try await offline.track(channel: "a", event: "second")

        Stub.reset()
        let queue = OfflineQueue(directory: directory)
        let online = SnekotEvents(token: "sk_test", project: "p", endpoint: URL(string: "http://stub.test")!, session: stubbed(), queue: queue)
        try await online.track(channel: "a", event: "third")
        XCTAssertEqual(Stub.events(), ["first", "second", "third"])
        XCTAssertEqual(Stub.timestamps(), [true, true, false], "a kept event carries the moment it happened; a live one does not")
        let waiting = await queue.count
        XCTAssertEqual(waiting, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("snekot-queue.json").path))
    }

    func testWithAPublicKeyAKeptEventCarriesItsTimeToo() async throws {
        let directory = folder()
        let offline = SnekotEvents(token: "pk_test", project: "p", endpoint: URL(string: "http://127.0.0.1:1")!, timeout: 2, queue: OfflineQueue(directory: directory))
        try await offline.track(channel: "a", event: "first")
        Stub.reset()
        let online = SnekotEvents(token: "pk_test", project: "p", endpoint: URL(string: "http://stub.test")!, session: stubbed(), queue: OfflineQueue(directory: directory))
        await online.flush()
        XCTAssertEqual(Stub.events(), ["first"])
        XCTAssertEqual(Stub.timestamps(), [true], "a public key may set a time within the last 7 days")
    }

    func testARefusalIsThrownAndNeverKept() async throws {
        Stub.reset()
        Stub.answer = 400
        let queue = OfflineQueue(directory: folder())
        let events = SnekotEvents(token: "pk_test", project: "p", endpoint: URL(string: "http://stub.test")!, session: stubbed(), queue: queue)
        do {
            try await events.track(channel: "Not Valid", event: "x")
            XCTFail("expected a refusal")
        } catch SnekotError.refused(let status, _) {
            XCTAssertEqual(status, 400)
        }
        let waiting = await queue.count
        XCTAssertEqual(waiting, 0)
    }

    func testAKeptEventTheServerRefusesIsDroppedAndTheRestGoOut() async throws {
        let directory = folder()
        let queue = OfflineQueue(directory: directory)
        await queue.add(WireRequest(method: "POST", path: "/v1/log", body: .object(["event": .string("bad")])))
        await queue.add(WireRequest(method: "POST", path: "/v1/log", body: .object(["event": .string("good")])))
        Stub.reset()
        Stub.refuse = "bad"
        let events = SnekotEvents(token: "pk_test", project: "p", endpoint: URL(string: "http://stub.test")!, session: stubbed(), queue: queue)
        let left = await events.flush()
        XCTAssertEqual(left, 0)
        XCTAssertEqual(Stub.events(), ["bad", "good"])
    }

    func testTooManyRequestsKeepsEverythingForLater() async {
        let queue = OfflineQueue(directory: folder())
        await queue.add(WireRequest(method: "POST", path: "/v1/log", body: .object(["event": .string("one")])))
        await queue.add(WireRequest(method: "POST", path: "/v1/log", body: .object(["event": .string("two")])))
        Stub.reset()
        Stub.answer = 429
        let events = SnekotEvents(token: "pk_test", project: "p", endpoint: URL(string: "http://stub.test")!, session: stubbed(), queue: queue)
        let left = await events.flush()
        XCTAssertEqual(left, 2)
    }

    func testTheQueueKeepsTheNewestAndDropsTheOld() async {
        let queue = OfflineQueue(directory: folder(), limit: 2, maxAge: 60)
        let wire = { (name: String) in WireRequest(method: "POST", path: "/v1/log", body: .object(["event": .string(name)])) }
        await queue.add(wire("expired"), at: Date().addingTimeInterval(-120))
        await queue.add(wire("one"))
        await queue.add(wire("two"))
        await queue.add(wire("three"))
        Stub.reset()
        let events = SnekotEvents(token: "pk_test", project: "p", endpoint: URL(string: "http://stub.test")!, session: stubbed(), queue: queue)
        await events.flush()
        XCTAssertEqual(Stub.events(), ["two", "three"])
    }
}

/// Answers every request from memory and remembers what it was asked.
final class Stub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var bodies: [[String: JSON]] = []
    static var answer = 200
    static var refuse: String?

    static func reset() { lock.lock(); bodies = []; answer = 200; refuse = nil; lock.unlock() }
    static func events() -> [String] { lock.lock(); defer { lock.unlock() }; return bodies.compactMap { if case .string(let name)? = $0["event"] { return name } else { return nil } } }
    static func timestamps() -> [Bool] { lock.lock(); defer { lock.unlock() }; return bodies.map { $0["timestamp"] != nil } }

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
        var status = Stub.answer
        if case .object(let fields)? = try? JSONDecoder().decode(JSON.self, from: data) {
            Stub.lock.lock(); Stub.bodies.append(fields); Stub.lock.unlock()
            if case .string(let name)? = fields["event"], name == Stub.refuse { status = 400 }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"error\":\"no\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
