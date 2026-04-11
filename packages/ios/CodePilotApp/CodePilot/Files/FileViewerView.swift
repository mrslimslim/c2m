import SwiftUI
import CodePilotCore

struct FileViewerView: View {
    let file: FileState

    @State private var showCopied = false
    private let syntaxHighlighter = CodeSyntaxHighlighter()

    private var fileName: String {
        (file.path as NSString).lastPathComponent
    }

    private var displayLanguage: String {
        file.language.isEmpty ? "plaintext" : file.language
    }

    private var lines: [(offset: Int, element: String)] {
        Array(file.content.components(separatedBy: "\n").enumerated())
    }

    private var gutterWidth: CGFloat {
        CGFloat(max(String(lines.count).count, 2)) * 9 + 18
    }

    var body: some View {
        Group {
            if file.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(CPTheme.accent)
                    Text("Loading file...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = file.errorMessage {
                ContentUnavailableView(
                    "File Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if file.content.isEmpty {
                ContentUnavailableView(
                    "No Content",
                    systemImage: "doc.text",
                    description: Text("This file has no content to display.")
                )
            } else {
                contentCard
            }
        }
        .navigationTitle(fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = file.content
                    showCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        showCopied = false
                    }
                } label: {
                    if showCopied {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(CPTheme.success)
                    } else {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(file.content.isEmpty)
            }
        }
    }

    private var contentCard: some View {
        VStack(spacing: 0) {
            metadataBar
            Divider()
                .overlay(Color.white.opacity(0.08))
            codeView
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(CPTheme.terminalBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .padding()
    }

    private var metadataBar: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(CPTheme.shortPath(file.path))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .lineLimit(2)

                Text("\(lines.count) lines")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.52))
            }

            Spacer(minLength: 0)

            Text(displayLanguage.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.78))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08), in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.03))
    }

    private var codeView: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines, id: \.offset) { index, line in
                    CodeLineRow(
                        lineNumber: index + 1,
                        gutterWidth: gutterWidth,
                        line: line,
                        language: displayLanguage,
                        syntaxHighlighter: syntaxHighlighter
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.visible)
    }
}

private struct CodeLineRow: View {
    let lineNumber: Int
    let gutterWidth: CGFloat
    let line: String
    let language: String
    let syntaxHighlighter: CodeSyntaxHighlighter

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(lineNumber)")
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.28))
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.top, 1)

            CodeHighlightedText(
                text: line,
                language: language,
                syntaxHighlighter: syntaxHighlighter
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(lineNumber.isMultiple(of: 2) ? Color.white.opacity(0.018) : .clear)
    }
}

private struct CodeHighlightedText: View {
    let text: String
    let language: String
    let syntaxHighlighter: CodeSyntaxHighlighter

    var body: some View {
        syntaxHighlighter.highlight(line: text, language: language)
            .font(.system(size: 13, weight: .regular, design: .monospaced))
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

private struct CodeSyntaxHighlighter {
    private struct HighlightSpan {
        let range: NSRange
        let color: Color
    }

    private struct HighlightRule {
        let regex: NSRegularExpression
        let color: Color
    }

    private static let baseColor = Color(red: 0.92, green: 0.94, blue: 0.99)
    private static let commentColor = Color(red: 0.48, green: 0.56, blue: 0.64)
    private static let stringColor = Color(red: 0.58, green: 0.84, blue: 0.62)
    private static let keywordColor = Color(red: 0.98, green: 0.58, blue: 0.78)
    private static let numberColor = Color(red: 0.49, green: 0.77, blue: 0.96)
    private static let typeColor = Color(red: 0.72, green: 0.65, blue: 1.0)
    private static let propertyColor = Color(red: 1.0, green: 0.82, blue: 0.46)
    private static let headingColor = Color(red: 0.56, green: 0.82, blue: 1.0)

    func highlight(line: String, language: String) -> Text {
        let source = line.isEmpty ? " " : line
        let nsSource = source as NSString
        let spans = highlightedSpans(in: source, language: language)

        guard !spans.isEmpty else {
            return Text(verbatim: source).foregroundColor(Self.baseColor)
        }

        var cursor = 0
        var result = Text("")

        for span in spans {
            if span.range.location > cursor {
                let plainRange = NSRange(location: cursor, length: span.range.location - cursor)
                result = result + Text(verbatim: nsSource.substring(with: plainRange))
                    .foregroundColor(Self.baseColor)
            }

            result = result + Text(verbatim: nsSource.substring(with: span.range))
                .foregroundColor(span.color)
            cursor = NSMaxRange(span.range)
        }

        if cursor < nsSource.length {
            let trailingRange = NSRange(location: cursor, length: nsSource.length - cursor)
            result = result + Text(verbatim: nsSource.substring(with: trailingRange))
                .foregroundColor(Self.baseColor)
        }

        return result
    }

    private func highlightedSpans(in source: String, language: String) -> [HighlightSpan] {
        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        let length = (source as NSString).length
        var claimed = Array(repeating: false, count: max(length, 1))
        var spans: [HighlightSpan] = []

        for rule in Self.rules(for: language) {
            for match in rule.regex.matches(in: source, range: nsRange) {
                let range = match.range
                guard range.location != NSNotFound, range.length > 0 else {
                    continue
                }
                guard rangeFits(range, in: claimed) else {
                    continue
                }
                reserve(range, in: &claimed)
                spans.append(HighlightSpan(range: range, color: rule.color))
            }
        }

        return spans.sorted { lhs, rhs in
            lhs.range.location < rhs.range.location
        }
    }

    private func rangeFits(_ range: NSRange, in claimed: [Bool]) -> Bool {
        let upperBound = min(NSMaxRange(range), claimed.count)
        guard range.location >= 0, range.location < upperBound else {
            return false
        }

        for index in range.location..<upperBound where claimed[index] {
            return false
        }
        return true
    }

    private func reserve(_ range: NSRange, in claimed: inout [Bool]) {
        let upperBound = min(NSMaxRange(range), claimed.count)
        guard range.location >= 0, range.location < upperBound else {
            return
        }

        for index in range.location..<upperBound {
            claimed[index] = true
        }
    }

    private static func rules(for language: String) -> [HighlightRule] {
        switch language.lowercased() {
        case "swift":
            return swiftRules
        case "rust":
            return rustRules
        case "typescript", "ts", "tsx", "javascript", "js", "jsx":
            return jsRules
        case "json":
            return jsonRules
        case "yaml", "yml":
            return yamlRules
        case "python", "py":
            return pythonRules
        case "shell", "bash", "sh", "zsh":
            return shellRules
        case "markdown", "md":
            return markdownRules
        default:
            return genericRules
        }
    }

    private static let genericRules: [HighlightRule] = [
        .init(regex: regex(#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#), color: stringColor),
        .init(regex: regex(#"//.*$|/\*.*\*/|#.*$"#, options: [.anchorsMatchLines]), color: commentColor),
        .init(regex: regex(#"\b(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)\b"#), color: numberColor),
        .init(regex: keywordRegex([
            "if", "else", "for", "while", "return", "switch", "case", "break",
            "continue", "import", "from", "true", "false", "null"
        ]), color: keywordColor),
        .init(regex: regex(#"\b[A-Z][A-Za-z0-9_]*\b"#), color: typeColor)
    ]

    private static let swiftRules: [HighlightRule] = [
        .init(regex: regex(#""(?:\\.|[^"\\])*""#), color: stringColor),
        .init(regex: regex(#"//.*$|/\*.*\*/"#, options: [.anchorsMatchLines]), color: commentColor),
        .init(regex: keywordRegex([
            "actor", "any", "as", "async", "await", "break", "case", "catch",
            "class", "continue", "default", "defer", "do", "else", "enum",
            "extension", "false", "fileprivate", "for", "func", "guard", "if",
            "import", "in", "init", "internal", "let", "nil", "private",
            "protocol", "public", "repeat", "return", "self", "some", "static",
            "struct", "super", "switch", "throw", "throws", "true", "try",
            "var", "where", "while"
        ]), color: keywordColor),
        .init(regex: regex(#"\b(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)\b"#), color: numberColor),
        .init(regex: regex(#"\b[A-Z][A-Za-z0-9_]*\b"#), color: typeColor),
        .init(regex: regex(#"@[A-Za-z_][A-Za-z0-9_]*"#), color: propertyColor)
    ]

    private static let rustRules: [HighlightRule] = [
        .init(regex: regex(#""(?:\\.|[^"\\])*""#), color: stringColor),
        .init(regex: regex(#"//.*$|/\*.*\*/"#, options: [.anchorsMatchLines]), color: commentColor),
        .init(regex: keywordRegex([
            "as", "async", "await", "break", "const", "continue", "crate", "else",
            "enum", "false", "fn", "for", "if", "impl", "in", "let", "loop",
            "match", "mod", "move", "mut", "pub", "return", "self", "Self",
            "static", "struct", "super", "trait", "true", "type", "unsafe",
            "use", "where", "while"
        ]), color: keywordColor),
        .init(regex: regex(#"\b(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)\b"#), color: numberColor),
        .init(regex: regex(#"\b[A-Z][A-Za-z0-9_]*\b"#), color: typeColor),
        .init(regex: regex(#"#\[[^\]]+\]"#), color: propertyColor)
    ]

    private static let jsRules: [HighlightRule] = [
        .init(regex: regex(#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#), color: stringColor),
        .init(regex: regex(#"//.*$|/\*.*\*/"#, options: [.anchorsMatchLines]), color: commentColor),
        .init(regex: keywordRegex([
            "async", "await", "break", "case", "catch", "class", "const", "continue",
            "default", "else", "export", "extends", "false", "finally", "for",
            "from", "function", "if", "import", "in", "interface", "let", "new",
            "null", "return", "static", "switch", "throw", "true", "try", "type",
            "undefined", "var", "while"
        ]), color: keywordColor),
        .init(regex: regex(#"\b(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)\b"#), color: numberColor),
        .init(regex: regex(#"\b[A-Z][A-Za-z0-9_]*\b"#), color: typeColor),
        .init(regex: regex(#"\b[A-Za-z_][A-Za-z0-9_]*(?=\s*:)"#), color: propertyColor)
    ]

    private static let jsonRules: [HighlightRule] = [
        .init(regex: regex(#""(?:\\.|[^"\\])*"(?=\s*:)"#), color: propertyColor),
        .init(regex: regex(#""(?:\\.|[^"\\])*""#), color: stringColor),
        .init(regex: keywordRegex(["true", "false", "null"]), color: keywordColor),
        .init(regex: regex(#"\b(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)\b"#), color: numberColor)
    ]

    private static let yamlRules: [HighlightRule] = [
        .init(regex: regex(#"#.*$"#, options: [.anchorsMatchLines]), color: commentColor),
        .init(regex: regex(#"^[\s-]*[A-Za-z0-9_.-]+(?=:)"#, options: [.anchorsMatchLines]), color: propertyColor),
        .init(regex: regex(#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#), color: stringColor),
        .init(regex: keywordRegex(["true", "false", "null", "yes", "no", "on", "off"]), color: keywordColor),
        .init(regex: regex(#"\b\d+(?:\.\d+)?\b"#), color: numberColor)
    ]

    private static let pythonRules: [HighlightRule] = [
        .init(regex: regex(#"""{1,3}[\s\S]*?"""{1,3}|'{3}[\s\S]*?'{3}|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#), color: stringColor),
        .init(regex: regex(#"#.*$"#, options: [.anchorsMatchLines]), color: commentColor),
        .init(regex: keywordRegex([
            "and", "as", "async", "await", "break", "class", "continue", "def",
            "elif", "else", "False", "for", "from", "if", "import", "in", "is",
            "lambda", "None", "not", "or", "pass", "return", "self", "True",
            "try", "while", "with", "yield"
        ]), color: keywordColor),
        .init(regex: regex(#"\b\d+(?:\.\d+)?\b"#), color: numberColor),
        .init(regex: regex(#"\b[A-Z][A-Za-z0-9_]*\b"#), color: typeColor)
    ]

    private static let shellRules: [HighlightRule] = [
        .init(regex: regex(#"#.*$"#, options: [.anchorsMatchLines]), color: commentColor),
        .init(regex: regex(#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#), color: stringColor),
        .init(regex: keywordRegex([
            "case", "do", "done", "elif", "else", "esac", "exit", "fi", "for",
            "function", "if", "in", "local", "return", "then", "while"
        ]), color: keywordColor),
        .init(regex: regex(#"\$[A-Za-z_][A-Za-z0-9_]*"#), color: propertyColor),
        .init(regex: regex(#"\b\d+\b"#), color: numberColor)
    ]

    private static let markdownRules: [HighlightRule] = [
        .init(regex: regex(#"^#{1,6}\s.*$"#, options: [.anchorsMatchLines]), color: headingColor),
        .init(regex: regex(#"`[^`]+`|```.*$"#, options: [.anchorsMatchLines]), color: stringColor),
        .init(regex: regex(#"^\s*[-*+]\s"#, options: [.anchorsMatchLines]), color: propertyColor),
        .init(regex: regex(#"^\s*\d+\.\s"#, options: [.anchorsMatchLines]), color: propertyColor),
        .init(regex: regex(#"\[[^\]]+\]\([^)]+\)"#), color: keywordColor)
    ]

    private static func keywordRegex(_ keywords: [String]) -> NSRegularExpression {
        let escaped = keywords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return regex(#"\b(?:\#(escaped))\b"#)
    }

    private static func regex(
        _ pattern: String,
        options: NSRegularExpression.Options = []
    ) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("Invalid regex pattern: \(pattern)")
        }
    }
}

#if DEBUG
#Preview("File Viewer") {
    NavigationStack {
        FileViewerView(file: AppPreviewFixtures.previewFile)
    }
}
#endif
