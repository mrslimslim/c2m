import Foundation

public struct ConversationSnapshot: Codable, Equatable, Sendable {
    public let sessionStore: SessionStoreSnapshot
    public let timelineStore: TimelineStoreSnapshot
    public let fileStore: FileStoreSnapshot
    public let sessionToConnectionID: [String: String]

    public init(
        sessionStore: SessionStoreSnapshot,
        timelineStore: TimelineStoreSnapshot,
        fileStore: FileStoreSnapshot,
        sessionToConnectionID: [String: String]
    ) {
        self.sessionStore = sessionStore
        self.timelineStore = timelineStore
        self.fileStore = fileStore
        self.sessionToConnectionID = sessionToConnectionID
    }
}

public final class ConversationSnapshotStore {
    public static let defaultsKey = "conversation_snapshot.v1"

    private let userDefaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func loadSnapshot() -> ConversationSnapshot? {
        guard
            let data = userDefaults.data(forKey: Self.defaultsKey),
            let snapshot = try? decoder.decode(ConversationSnapshot.self, from: data)
        else {
            return nil
        }
        return snapshot
    }

    public func saveSnapshot(_ snapshot: ConversationSnapshot) throws {
        let data = try encoder.encode(snapshot)
        userDefaults.set(data, forKey: Self.defaultsKey)
    }

    public func clear() {
        userDefaults.removeObject(forKey: Self.defaultsKey)
    }
}
