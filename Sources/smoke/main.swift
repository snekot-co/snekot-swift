// Every method against a running API: `SNEKOT_TOKEN=sk_… SNEKOT_PROJECT=slug swift run smoke`.
import Foundation
import SnekotEvents

let environment = ProcessInfo.processInfo.environment
guard let token = environment["SNEKOT_TOKEN"], let project = environment["SNEKOT_PROJECT"] else { fatalError("Set SNEKOT_TOKEN and SNEKOT_PROJECT.") }
let events = SnekotEvents(token: token, project: project, endpoint: environment["SNEKOT_ENDPOINT"].flatMap(URL.init(string:)) ?? SnekotEvents.defaultEndpoint)

try await events.track(channel: "sdk", event: "Swift smoke test", userID: "sdk-user", icon: ":bird:", tags: ["runtime": "swift"])
try await events.identify(userID: "sdk-user", properties: ["language": "swift"])
try await events.group("sdk-team", userID: "sdk-user", properties: ["name": "SDK Team"])
try await events.subscribe("sdk-user@example.com", name: "SDK User", properties: ["runtime": "swift"], source: "/sdk")
try await events.setInsight("Swift runs", to: 0)
try await events.incrementInsight("Swift runs")
do {
    try await events.track(channel: "Not Valid", event: "x")
    fatalError("expected a refusal")
} catch SnekotError.refused(let status, let message) {
    print("refused as expected (\(status)): \(message)")
}
print("swift ok")
