import Foundation

public struct SavedConnection: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let config: ConnectionConfig

    public init(id: String, name: String, config: ConnectionConfig) {
        self.id = id
        self.name = name
        self.config = config
    }
}

public struct SavedConnectionsSnapshot: Equatable, Sendable {
    public var connections: [SavedConnection]
    public var selectedConnectionID: SavedConnection.ID?

    public init(connections: [SavedConnection], selectedConnectionID: SavedConnection.ID?) {
        self.connections = connections
        self.selectedConnectionID = selectedConnectionID
    }
}

public final class SavedConnectionStore {
    public static let metadataDefaultsKey = "saved_connection_metadata.v1"

    private let userDefaults: UserDefaults
    private let secretStore: any SecretStoring
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        userDefaults: UserDefaults = .standard,
        secretStore: any SecretStoring = KeychainSecretStore()
    ) {
        self.userDefaults = userDefaults
        self.secretStore = secretStore
    }

    public func loadSnapshot() -> SavedConnectionsSnapshot {
        guard
            let data = userDefaults.data(forKey: Self.metadataDefaultsKey),
            let metadataSnapshot = try? decoder.decode(PersistedSnapshot.self, from: data)
        else {
            return .init(connections: [], selectedConnectionID: nil)
        }

        let connections = metadataSnapshot.connections.compactMap { metadata in
            switch metadata.mode {
            case .lan:
                let token = (try? secretStore.secret(for: secretAccount(connectionID: metadata.id, key: .token))) ?? ""
                let bridgePublicKey = (try? secretStore.secret(for: secretAccount(connectionID: metadata.id, key: .bridgePublicKey))) ?? ""
                let otp = (try? secretStore.secret(for: secretAccount(connectionID: metadata.id, key: .otp))) ?? ""
                return SavedConnection(
                    id: metadata.id,
                    name: metadata.name,
                    config: .lan(
                        host: metadata.host ?? "127.0.0.1",
                        port: metadata.port ?? 19_260,
                        token: token,
                        bridgePublicKey: bridgePublicKey,
                        otp: otp
                    )
                )

            case .relay:
                let bridgePublicKey = (try? secretStore.secret(for: secretAccount(connectionID: metadata.id, key: .bridgePublicKey))) ?? ""
                let otp = (try? secretStore.secret(for: secretAccount(connectionID: metadata.id, key: .otp))) ?? ""
                return SavedConnection(
                    id: metadata.id,
                    name: metadata.name,
                    config: .relay(
                        url: metadata.url ?? "",
                        channel: metadata.channel ?? "",
                        bridgePublicKey: bridgePublicKey,
                        otp: otp
                    )
                )
            }
        }

        let selected = metadataSnapshot.selectedConnectionID.flatMap { selectedID in
            connections.contains(where: { $0.id == selectedID }) ? selectedID : nil
        }

        return .init(connections: connections, selectedConnectionID: selected)
    }

    public func saveSnapshot(_ snapshot: SavedConnectionsSnapshot) throws {
        let existingMetadata = loadPersistedMetadata()
        let existingIDs = Set(existingMetadata.connections.map(\.id))
        let nextIDs = Set(snapshot.connections.map(\.id))
        let removedIDs = existingIDs.subtracting(nextIDs)
        for connectionID in removedIDs {
            try removeAllSecrets(for: connectionID)
        }

        var persistedConnections: [PersistedConnectionMetadata] = []
        persistedConnections.reserveCapacity(snapshot.connections.count)

        for connection in snapshot.connections {
            switch connection.config {
            case let .lan(host, port, token, bridgePublicKey, otp):
                try secretStore.setSecret(token, for: secretAccount(connectionID: connection.id, key: .token))
                try secretStore.setSecret(bridgePublicKey, for: secretAccount(connectionID: connection.id, key: .bridgePublicKey))
                try secretStore.setSecret(otp, for: secretAccount(connectionID: connection.id, key: .otp))
                persistedConnections.append(
                    PersistedConnectionMetadata(
                    id: connection.id,
                    name: connection.name,
                    mode: .lan,
                    host: host,
                    port: port,
                    url: nil,
                    channel: nil
                )
                )

            case let .relay(url, channel, bridgePublicKey, otp):
                try secretStore.removeSecret(for: secretAccount(connectionID: connection.id, key: .token))
                try secretStore.setSecret(bridgePublicKey, for: secretAccount(connectionID: connection.id, key: .bridgePublicKey))
                try secretStore.setSecret(otp, for: secretAccount(connectionID: connection.id, key: .otp))
                persistedConnections.append(
                    PersistedConnectionMetadata(
                    id: connection.id,
                    name: connection.name,
                    mode: .relay,
                    host: nil,
                    port: nil,
                    url: url,
                    channel: channel
                )
                )
            }
        }

        let metadataSnapshot = PersistedSnapshot(
            connections: persistedConnections,
            selectedConnectionID: snapshot.selectedConnectionID
        )
        let metadataData = try encoder.encode(metadataSnapshot)
        userDefaults.set(metadataData, forKey: Self.metadataDefaultsKey)
    }

    private func loadPersistedMetadata() -> PersistedSnapshot {
        guard
            let data = userDefaults.data(forKey: Self.metadataDefaultsKey),
            let metadataSnapshot = try? decoder.decode(PersistedSnapshot.self, from: data)
        else {
            return .init(connections: [], selectedConnectionID: nil)
        }
        return metadataSnapshot
    }

    private func removeAllSecrets(for connectionID: String) throws {
        try secretStore.removeSecret(for: secretAccount(connectionID: connectionID, key: .token))
        try secretStore.removeSecret(for: secretAccount(connectionID: connectionID, key: .bridgePublicKey))
        try secretStore.removeSecret(for: secretAccount(connectionID: connectionID, key: .otp))
    }

    private enum SecretKey: String {
        case token
        case bridgePublicKey = "bridge_pubkey"
        case otp
    }

    private func secretAccount(connectionID: String, key: SecretKey) -> String {
        "saved_connection.\(connectionID).\(key.rawValue)"
    }
}

private struct PersistedSnapshot: Codable {
    var connections: [PersistedConnectionMetadata]
    var selectedConnectionID: String?
}

private struct PersistedConnectionMetadata: Codable {
    enum Mode: String, Codable {
        case lan
        case relay
    }

    var id: String
    var name: String
    var mode: Mode
    var host: String?
    var port: Int?
    var url: String?
    var channel: String?
}
