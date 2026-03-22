import Foundation

public enum DiffLineKind: String, Codable, Equatable, Sendable {
    case context
    case add
    case delete
}

public struct DiffLine: Codable, Equatable, Sendable {
    public let kind: DiffLineKind
    public let text: String

    public init(kind: DiffLineKind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public struct DiffHunk: Codable, Equatable, Sendable {
    public let oldStart: Int
    public let oldLineCount: Int
    public let newStart: Int
    public let newLineCount: Int
    public let lines: [DiffLine]

    public init(
        oldStart: Int,
        oldLineCount: Int,
        newStart: Int,
        newLineCount: Int,
        lines: [DiffLine]
    ) {
        self.oldStart = oldStart
        self.oldLineCount = oldLineCount
        self.newStart = newStart
        self.newLineCount = newLineCount
        self.lines = lines
    }
}

public struct DiffFile: Codable, Equatable, Sendable {
    public let path: String
    public let kind: FileChangeKind
    public let addedLines: Int?
    public let deletedLines: Int?
    public let isTruncated: Bool
    public let truncationReason: String?
    public let totalHunkCount: Int
    public let loadedHunks: [DiffHunk]
    public let nextHunkIndex: Int?

    public init(
        path: String,
        kind: FileChangeKind,
        addedLines: Int? = nil,
        deletedLines: Int? = nil,
        isTruncated: Bool,
        truncationReason: String? = nil,
        totalHunkCount: Int,
        loadedHunks: [DiffHunk],
        nextHunkIndex: Int? = nil
    ) {
        self.path = path
        self.kind = kind
        self.addedLines = addedLines
        self.deletedLines = deletedLines
        self.isTruncated = isTruncated
        self.truncationReason = truncationReason
        self.totalHunkCount = totalHunkCount
        self.loadedHunks = loadedHunks
        self.nextHunkIndex = nextHunkIndex
    }
}
