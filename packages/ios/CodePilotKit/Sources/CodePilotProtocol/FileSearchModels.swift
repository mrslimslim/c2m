import Foundation

public struct FileSearchMatch: Codable, Equatable, Sendable {
    public let path: String
    public let displayName: String?
    public let directoryHint: String?

    public init(path: String, displayName: String? = nil, directoryHint: String? = nil) {
        self.path = path
        self.displayName = displayName
        self.directoryHint = directoryHint
    }
}
