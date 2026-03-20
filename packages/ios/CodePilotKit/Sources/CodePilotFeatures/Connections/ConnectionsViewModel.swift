import Foundation
import CodePilotCore

public final class ConnectionsViewModel {
    public private(set) var savedConnections: [SavedConnection]
    public private(set) var selectedSavedConnectionID: SavedConnection.ID?

    public init(savedConnections: [SavedConnection] = []) {
        self.savedConnections = savedConnections
    }

    public func replaceSavedConnections(_ savedConnections: [SavedConnection], selectedConnectionID: SavedConnection.ID?) {
        self.savedConnections = savedConnections
        _ = selectSavedConnection(id: selectedConnectionID)
    }

    @discardableResult
    public func selectSavedConnection(id: SavedConnection.ID?) -> ConnectionConfig? {
        guard let id else {
            selectedSavedConnectionID = nil
            return nil
        }

        guard let selected = savedConnections.first(where: { $0.id == id }) else {
            selectedSavedConnectionID = nil
            return nil
        }

        selectedSavedConnectionID = selected.id
        return selected.config
    }

    @discardableResult
    public func parsePayload(
        _ payload: String,
        defaultHost: String = "127.0.0.1",
        defaultPort: Int = 19260
    ) throws -> ConnectionConfig {
        try ConnectionPayloadParser.parse(payload, defaultHost: defaultHost, defaultPort: defaultPort)
    }
}
