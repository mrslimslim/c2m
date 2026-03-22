import Foundation

public struct TimelineToolTodoItem: Equatable, Sendable {
    public let text: String
    public let isCompleted: Bool

    public init(text: String, isCompleted: Bool) {
        self.text = text
        self.isCompleted = isCompleted
    }
}

public struct TimelineToolMetadataRow: Equatable, Sendable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct TimelineToolEventPresentation: Equatable, Sendable {
    public let kind: String
    public let title: String
    public let summary: String
    public let subtitle: String?
    public let detail: String
    public let todoItems: [TimelineToolTodoItem]
    public let searchQueries: [String]
    public let metadataRows: [TimelineToolMetadataRow]

    public init(
        kind: String,
        title: String,
        summary: String,
        subtitle: String?,
        detail: String,
        todoItems: [TimelineToolTodoItem] = [],
        searchQueries: [String] = [],
        metadataRows: [TimelineToolMetadataRow] = []
    ) {
        self.kind = kind
        self.title = title
        self.summary = summary
        self.subtitle = subtitle
        self.detail = detail
        self.todoItems = todoItems
        self.searchQueries = searchQueries
        self.metadataRows = metadataRows
    }
}

public enum TimelineToolEventParser {
    public static func parse(statusMessage: String) -> TimelineToolEventPresentation? {
        let trimmed = statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["),
              let closingBracketIndex = trimmed.firstIndex(of: "]") else {
            return nil
        }

        let kindRange = trimmed.index(after: trimmed.startIndex)..<closingBracketIndex
        let kind = String(trimmed[kindRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kind.isEmpty else {
            return nil
        }

        let payloadStart = trimmed.index(after: closingBracketIndex)
        let payload = String(trimmed[payloadStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else {
            return nil
        }

        let parsedObject = jsonObject(from: payload)
        let detail = prettyPrintedJSON(from: payload) ?? payload
        return TimelineToolEventPresentation(
            kind: kind,
            title: title(for: kind),
            summary: summary(for: kind, object: parsedObject),
            subtitle: subtitle(for: kind, object: parsedObject),
            detail: detail,
            todoItems: todoItems(for: kind, object: parsedObject),
            searchQueries: searchQueries(for: kind, object: parsedObject),
            metadataRows: metadataRows(for: kind, object: parsedObject)
        )
    }

    private static func title(for kind: String) -> String {
        switch kind {
        case "todo_list":
            return "Todo List"
        case "web_search":
            return "Web Search"
        case "mcp_tool_call":
            return "MCP Tool Call"
        default:
            return kind
                .split(separator: "_")
                .map { $0.capitalized }
                .joined(separator: " ")
        }
    }

    private static func summary(for kind: String, object: Any?) -> String {
        switch kind {
        case "todo_list":
            guard let dictionary = object as? [String: Any],
                  let items = dictionary["items"] as? [[String: Any]],
                  !items.isEmpty else {
                return "Todo list updated"
            }
            let completedCount = items.reduce(into: 0) { count, item in
                if item["completed"] as? Bool == true {
                    count += 1
                }
            }
            return "\(completedCount) of \(items.count) completed"

        case "mcp_tool_call":
            guard let dictionary = object as? [String: Any] else {
                return "Tool call"
            }
            let server = stringValue(in: dictionary, key: "server")
            let tool = stringValue(in: dictionary, key: "tool")
                ?? stringValue(in: dictionary, key: "name")

            let combined = [server, tool]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "/")
            return combined.isEmpty ? "Tool call" : combined

        case "web_search":
            guard let dictionary = object as? [String: Any] else {
                return "Search in progress"
            }
            if let query = stringValue(in: dictionary, key: "query") {
                return query
            }
            if let queries = dictionary["queries"] as? [String],
               let firstQuery = queries.first,
               !firstQuery.isEmpty {
                return firstQuery
            }
            return "Search in progress"

        default:
            guard let dictionary = object as? [String: Any] else {
                return "Tool event"
            }
            return stringValue(in: dictionary, key: "title")
                ?? stringValue(in: dictionary, key: "name")
                ?? stringValue(in: dictionary, key: "query")
                ?? stringValue(in: dictionary, key: "id")
                ?? "Tool event"
        }
    }

    private static func subtitle(for kind: String, object: Any?) -> String? {
        guard let dictionary = object as? [String: Any] else {
            return nil
        }

        switch kind {
        case "todo_list":
            return stringValue(in: dictionary, key: "id")

        case "mcp_tool_call":
            return nestedStringValue(in: dictionary, keys: ["arguments", "path"])
                ?? nestedStringValue(in: dictionary, keys: ["input", "path"])
                ?? nestedStringValue(in: dictionary, keys: ["arguments", "query"])

        case "web_search":
            return stringValue(in: dictionary, key: "status")
                ?? stringValue(in: dictionary, key: "engine")

        default:
            return stringValue(in: dictionary, key: "id")
        }
    }

    private static func todoItems(for kind: String, object: Any?) -> [TimelineToolTodoItem] {
        guard kind == "todo_list",
              let dictionary = object as? [String: Any],
              let items = dictionary["items"] as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            guard let text = stringValue(in: item, key: "text") else {
                return nil
            }
            return TimelineToolTodoItem(
                text: text,
                isCompleted: item["completed"] as? Bool == true
            )
        }
    }

    private static func searchQueries(for kind: String, object: Any?) -> [String] {
        guard kind == "web_search",
              let dictionary = object as? [String: Any] else {
            return []
        }

        var queries: [String] = []

        if let query = stringValue(in: dictionary, key: "query") {
            queries.append(query)
        }

        if let rawQueries = dictionary["queries"] as? [String] {
            queries.append(contentsOf: rawQueries.compactMap { query in
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            })
        }

        if let rawQueries = dictionary["queries"] as? [[String: Any]] {
            queries.append(contentsOf: rawQueries.compactMap { queryObject in
                stringValue(in: queryObject, key: "query")
                    ?? stringValue(in: queryObject, key: "text")
            })
        }

        var seen = Set<String>()
        return queries.filter { query in
            seen.insert(query).inserted
        }
    }

    private static func metadataRows(for kind: String, object: Any?) -> [TimelineToolMetadataRow] {
        guard let dictionary = object as? [String: Any] else {
            return []
        }

        switch kind {
        case "mcp_tool_call":
            let arguments = (dictionary["arguments"] as? [String: Any]) ?? (dictionary["input"] as? [String: Any])
            return [
                metadataRow(label: "Server", value: stringValue(in: dictionary, key: "server")),
                metadataRow(label: "Tool", value: stringValue(in: dictionary, key: "tool") ?? stringValue(in: dictionary, key: "name")),
                metadataRow(label: "Path", value: arguments.flatMap { stringValue(in: $0, key: "path") }),
                metadataRow(label: "Query", value: arguments.flatMap { stringValue(in: $0, key: "query") }),
            ]
            .compactMap { $0 }

        case "web_search":
            return [
                metadataRow(label: "Engine", value: stringValue(in: dictionary, key: "engine")),
                metadataRow(label: "Status", value: stringValue(in: dictionary, key: "status")),
            ]
            .compactMap { $0 }

        default:
            return []
        }
    }

    private static func jsonObject(from payload: String) -> Any? {
        guard let data = payload.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func prettyPrintedJSON(from payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let prettyData = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys]
              ),
              let prettyString = String(data: prettyData, encoding: .utf8) else {
            return nil
        }
        return prettyString
    }

    private static func stringValue(in dictionary: [String: Any], key: String) -> String? {
        guard let value = dictionary[key] as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func metadataRow(label: String, value: String?) -> TimelineToolMetadataRow? {
        guard let value else {
            return nil
        }
        return TimelineToolMetadataRow(label: label, value: value)
    }

    private static func nestedStringValue(in dictionary: [String: Any], keys: [String]) -> String? {
        guard !keys.isEmpty else {
            return nil
        }

        var current: Any = dictionary
        for key in keys {
            guard let next = (current as? [String: Any])?[key] else {
                return nil
            }
            current = next
        }

        guard let value = current as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
