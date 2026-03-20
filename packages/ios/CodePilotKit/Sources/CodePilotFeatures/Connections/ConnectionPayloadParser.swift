import Foundation
import CodePilotCore

public enum ConnectionPayloadParserError: Error, Equatable {
    case emptyPayload
    case invalidPayload
    case missingRelayFields
    case missingRelayPairingData
    case missingLANHostOrPort
    case missingLANCredentials
    case invalidPort
}

public enum ConnectionPayloadParser {
    public static func parse(
        _ payload: String,
        defaultHost: String = "127.0.0.1",
        defaultPort: Int = 19260
    ) throws -> ConnectionConfig {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ConnectionPayloadParserError.emptyPayload
        }

        let parsedFields = try parseFields(from: trimmed)
        return try makeConnectionConfig(
            fields: parsedFields,
            defaultHost: defaultHost,
            defaultPort: defaultPort
        )
    }

    private static func parseFields(from payload: String) throws -> [String: String] {
        if let jsonData = payload.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: jsonData),
           let dictionary = object as? [String: Any] {
            let fields = normalize(dictionary: dictionary)
            if !fields.isEmpty {
                return fields
            }
        }

        if let urlComponents = URLComponents(string: payload),
           let queryItems = urlComponents.queryItems,
           !queryItems.isEmpty {
            return normalize(queryItems: queryItems)
        }

        if let queryStart = payload.firstIndex(of: "?") {
            let query = String(payload[payload.index(after: queryStart)...])
            let fields = normalize(queryItems: queryItems(from: query))
            if !fields.isEmpty {
                return fields
            }
        }

        if payload.contains("=") {
            let fields = normalize(queryItems: queryItems(from: payload))
            if !fields.isEmpty {
                return fields
            }
        }

        throw ConnectionPayloadParserError.invalidPayload
    }

    private static func makeConnectionConfig(
        fields: [String: String],
        defaultHost: String,
        defaultPort: Int
    ) throws -> ConnectionConfig {
        let relay = value(for: "relay", in: fields)
        let channel = value(for: "channel", in: fields)
        let bridgePubkey = value(for: "bridge_pubkey", in: fields)
        let otp = value(for: "otp", in: fields)
        let token = value(for: "token", in: fields)
        let modeIsRelay = !relay.isEmpty || !channel.isEmpty
        let hasPairing = !bridgePubkey.isEmpty && !otp.isEmpty

        if modeIsRelay {
            guard !relay.isEmpty, !channel.isEmpty else {
                throw ConnectionPayloadParserError.missingRelayFields
            }
            guard hasPairing else {
                throw ConnectionPayloadParserError.missingRelayPairingData
            }
            return .relay(
                url: normalizeRelayURL(relay),
                channel: channel,
                bridgePublicKey: bridgePubkey,
                otp: otp
            )
        }

        let host = value(for: "host", in: fields, fallback: defaultHost)
        let portString = value(for: "port", in: fields, fallback: String(defaultPort))
        guard !host.isEmpty, !portString.isEmpty else {
            throw ConnectionPayloadParserError.missingLANHostOrPort
        }
        guard let port = Int(portString) else {
            throw ConnectionPayloadParserError.invalidPort
        }
        guard !token.isEmpty || hasPairing else {
            throw ConnectionPayloadParserError.missingLANCredentials
        }

        return .lan(
            host: host,
            port: port,
            token: token,
            bridgePublicKey: bridgePubkey,
            otp: otp
        )
    }

    static func normalizeRelayURL(_ relayURL: String) -> String {
        relayURL.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(
            of: "/+$",
            with: "",
            options: .regularExpression
        )
    }

    private static func value(for key: String, in fields: [String: String], fallback: String = "") -> String {
        if let value = fields[key] {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if key == "bridge_pubkey", let value = fields["bridgePubkey"] {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalize(dictionary: [String: Any]) -> [String: String] {
        var normalized: [String: String] = [:]
        for (key, value) in dictionary {
            switch value {
            case let string as String:
                normalized[key] = string
            case let number as NSNumber:
                normalized[key] = number.stringValue
            default:
                continue
            }
        }
        return normalized
    }

    private static func normalize(queryItems: [URLQueryItem]) -> [String: String] {
        var normalized: [String: String] = [:]
        for item in queryItems {
            normalized[item.name] = item.value ?? ""
        }
        return normalized
    }

    private static func queryItems(from query: String) -> [URLQueryItem] {
        var components = URLComponents()
        components.query = query
        return components.queryItems ?? []
    }
}
