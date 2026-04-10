import Foundation
import CodePilotProtocol

public struct SessionComposerContext: Equatable, Sendable {
    public var draft: String
    public var selectedFiles: [FileSearchMatch]

    public init(draft: String = "", selectedFiles: [FileSearchMatch] = []) {
        self.draft = draft
        self.selectedFiles = selectedFiles
    }

    public var activeFileSearchQuery: String? {
        guard let range = activeFileSearchRange else {
            return nil
        }

        let query = String(draft[range]).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        return query.isEmpty ? nil : query
    }

    public var serializedCommandText: String {
        let prefix = selectedFiles
            .map { "@\($0.path)" }
            .joined(separator: " ")

        guard !prefix.isEmpty else {
            return draft
        }

        guard !draft.isEmpty else {
            return prefix
        }

        if draft.first?.isWhitespace == true {
            return prefix + draft
        }

        return prefix + " " + draft
    }

    public mutating func insertFile(_ file: FileSearchMatch) {
        if !selectedFiles.contains(where: { $0.path == file.path }) {
            selectedFiles.append(file)
        }

        guard let range = activeFileSearchRange else {
            return
        }
        draft.removeSubrange(range)
    }

    public mutating func removeFile(path: String) {
        selectedFiles.removeAll { $0.path == path }
    }

    private var activeFileSearchRange: Range<String.Index>? {
        if let leadingRange = leadingFileSearchRange {
            return leadingRange
        }

        return trailingFileSearchRange
    }

    private var leadingFileSearchRange: Range<String.Index>? {
        guard draft.first == "@" else {
            return nil
        }

        let searchStart = draft.startIndex
        let tokenEnd = draft[searchStart...]
            .firstIndex(where: { $0.isWhitespace }) ?? draft.endIndex
        guard tokenEnd > draft.index(after: searchStart) else {
            return nil
        }

        return searchStart..<tokenEnd
    }

    private var trailingFileSearchRange: Range<String.Index>? {
        guard
            !draft.isEmpty,
            draft.last?.isWhitespace == false,
            let tokenStart = draft.lastIndex(of: "@")
        else {
            return nil
        }

        if tokenStart > draft.startIndex {
            let previousIndex = draft.index(before: tokenStart)
            guard draft[previousIndex].isWhitespace else {
                return nil
            }
        }

        let queryStart = draft.index(after: tokenStart)
        guard queryStart < draft.endIndex else {
            return nil
        }

        guard !draft[queryStart...].contains(where: { $0.isWhitespace }) else {
            return nil
        }

        return tokenStart..<draft.endIndex
    }
}
