import Foundation

public enum DiagnosticsRedactor {
    public static func redact(_ message: String) -> String {
        var redacted = message
        for rule in rules {
            let range = NSRange(redacted.startIndex..<redacted.endIndex, in: redacted)
            redacted = rule.regex.stringByReplacingMatches(
                in: redacted,
                options: [],
                range: range,
                withTemplate: rule.template
            )
        }
        return redacted
    }

    private struct RedactionRule {
        let regex: NSRegularExpression
        let template: String
    }

    private static let rules: [RedactionRule] = [
        .init(regex: try! NSRegularExpression(pattern: #"(?i)(token\s*[=:]\s*)([^\s,;&]+)"#), template: "$1[REDACTED]"),
        .init(regex: try! NSRegularExpression(pattern: #"(?i)(otp\s*[=:]\s*)([^\s,;&]+)"#), template: "$1[REDACTED]"),
        .init(regex: try! NSRegularExpression(pattern: #"(?i)(ciphertext\s*[=:]\s*)([^\s,;&]+)"#), template: "$1[REDACTED]"),
        .init(regex: try! NSRegularExpression(pattern: #"(?i)("token"\s*:\s*")([^"]+)(")"#), template: "$1[REDACTED]$3"),
        .init(regex: try! NSRegularExpression(pattern: #"(?i)("otp"\s*:\s*")([^"]+)(")"#), template: "$1[REDACTED]$3"),
        .init(regex: try! NSRegularExpression(pattern: #"(?i)("ciphertext"\s*:\s*")([^"]+)(")"#), template: "$1[REDACTED]$3"),
    ]
}
