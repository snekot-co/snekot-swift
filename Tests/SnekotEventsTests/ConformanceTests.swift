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
                request = SnekotEvents.subscribeRequest(email: text(args["email"])!, name: text(args["name"]), properties: values(args["properties"]), source: text(args["source"]), notify: notify, project: suite.project)
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
}
