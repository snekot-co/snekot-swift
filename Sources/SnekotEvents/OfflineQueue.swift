import Foundation

/// Keeps events that could not be sent, on the device, and sends them later in the order they happened.
///
/// Give one to `SnekotEvents(…, queue:)`. A call that gets no answer, because the device is offline or the server
/// is down, is then kept instead of thrown, and goes out before the next call that does get through, or when you
/// call `flush()`. What the server refuses is never kept: it would be refused again.
///
/// What is kept is the request's body, in a file in the app's own container. The key is not written to it.
/// Events older than `maxAge` are dropped, and when there are more than `limit`, the oldest are.
public actor OfflineQueue {
    struct Stored: Codable, Sendable, Equatable {
        let id: UUID
        let method: String
        let path: String
        let body: JSON
        let at: Date
    }

    private let file: URL
    private let limit: Int
    private let maxAge: TimeInterval
    private var items: [Stored]
    private var draining = false

    /// - Parameters:
    ///   - directory: Where the file goes. The app's Application Support folder if left out.
    ///   - name: The file's name, for an app that keeps more than one queue.
    ///   - limit: How many events are kept at most; 500 by default.
    ///   - maxAge: How long an event is kept, in seconds; 7 days by default.
    public init(directory: URL? = nil, name: String = "snekot-queue", limit: Int = 500, maxAge: TimeInterval = 7 * 24 * 60 * 60) {
        let folder = directory ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.file = folder.appendingPathComponent(name + ".json")
        self.limit = max(1, limit)
        self.maxAge = maxAge
        // A file that cannot be read is a queue that starts empty, never a crash.
        self.items = (try? JSONDecoder().decode([Stored].self, from: Data(contentsOf: self.file))) ?? []
    }

    /// How many events are waiting.
    public var count: Int {
        prune()
        return items.count
    }

    /// Forgets everything that is waiting, for when a person signs out or withdraws consent.
    public func clear() {
        items = []
        save()
    }

    func add(_ wire: WireRequest, at moment: Date = Date()) {
        items.append(Stored(id: UUID(), method: wire.method, path: wire.path, body: wire.body, at: moment))
        prune()
        save()
    }

    /// Sends what is waiting, oldest first. True when nothing is left; false when it stopped because a request got
    /// no answer, or because another send is already under way.
    func drain(_ send: @Sendable (WireRequest) async throws -> Void) async -> Bool {
        prune()
        if items.isEmpty { return true }
        if draining { return false }
        draining = true
        defer { draining = false }
        while let next = items.first {
            do {
                try await send(WireRequest(method: next.method, path: next.path, body: next.body))
            } catch SnekotError.refused(let status, _) where status == 429 {
                // Too many requests for now. That passes, so everything stays for the next try.
                return false
            } catch SnekotError.refused {
                // Refused once is refused always; keeping it would hold up everything behind it.
            } catch {
                return false
            }
            items.removeAll { $0.id == next.id }
            save()
        }
        return true
    }

    private func prune() {
        let oldest = Date().addingTimeInterval(-maxAge)
        items.removeAll { $0.at < oldest }
        if items.count > limit { items.removeFirst(items.count - limit) }
    }

    private func save() {
        if items.isEmpty {
            try? FileManager.default.removeItem(at: file)
        } else if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: file, options: .atomic)
        }
    }
}
