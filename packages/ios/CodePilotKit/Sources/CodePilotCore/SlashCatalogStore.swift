import Foundation
import CodePilotProtocol

public final class SlashCatalogStore {
    private let lock = NSLock()
    private var catalogByConnectionID: [String: SlashCatalogMessage] = [:]
    private var latestActionResultByConnectionID: [String: SlashActionResultMessage] = [:]

    public init() {}

    public var catalogsByConnectionID: [String: SlashCatalogMessage] {
        lock.lock()
        defer { lock.unlock() }
        return catalogByConnectionID
    }

    public var latestActionResultsByConnectionID: [String: SlashActionResultMessage] {
        lock.lock()
        defer { lock.unlock() }
        return latestActionResultByConnectionID
    }

    public func catalog(for connectionID: String) -> SlashCatalogMessage? {
        lock.lock()
        defer { lock.unlock() }
        return catalogByConnectionID[connectionID]
    }

    public func replaceCatalog(_ catalog: SlashCatalogMessage, for connectionID: String) {
        lock.lock()
        defer { lock.unlock() }
        catalogByConnectionID[connectionID] = catalog
    }

    public func latestActionResult(for connectionID: String) -> SlashActionResultMessage? {
        lock.lock()
        defer { lock.unlock() }
        return latestActionResultByConnectionID[connectionID]
    }

    public func recordActionResult(_ result: SlashActionResultMessage, for connectionID: String) {
        lock.lock()
        defer { lock.unlock() }
        latestActionResultByConnectionID[connectionID] = result
    }

    public func removeConnection(id connectionID: String) {
        lock.lock()
        defer { lock.unlock() }
        catalogByConnectionID[connectionID] = nil
        latestActionResultByConnectionID[connectionID] = nil
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        catalogByConnectionID.removeAll()
        latestActionResultByConnectionID.removeAll()
    }
}
