import Foundation
import CodePilotCore

public final class DiagnosticsViewModel {
    public private(set) var redactedLines: [String] = []
    public private(set) var latestLatencyMs: Int?

    private let diagnosticsStore: DiagnosticsStore

    public init(diagnosticsStore: DiagnosticsStore) {
        self.diagnosticsStore = diagnosticsStore
    }

    public func refresh() {
        let entries = diagnosticsStore.entries
        redactedLines = entries.map { DiagnosticsRedactor.redact($0.message) }
        latestLatencyMs = entries
            .reversed()
            .compactMap(parseLatencyMs)
            .first
    }

    private func parseLatencyMs(from entry: DiagnosticEntry) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"pong:(\d+)ms"#) else {
            return nil
        }
        let range = NSRange(entry.message.startIndex..<entry.message.endIndex, in: entry.message)
        guard
            let match = regex.firstMatch(in: entry.message, options: [], range: range),
            let valueRange = Range(match.range(at: 1), in: entry.message)
        else {
            return nil
        }
        return Int(entry.message[valueRange])
    }
}
