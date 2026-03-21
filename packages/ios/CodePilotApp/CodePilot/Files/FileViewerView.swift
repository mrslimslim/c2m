import SwiftUI
import CodePilotCore

struct FileViewerView: View {
    let file: FileState

    @State private var showCopied = false

    private var fileName: String {
        (file.path as NSString).lastPathComponent
    }

    private var displayLanguage: String {
        file.language.isEmpty ? "plaintext" : file.language
    }

    private var lines: [(offset: Int, element: String)] {
        Array(file.content.components(separatedBy: "\n").enumerated())
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
            } else if file.content.isEmpty {
                ContentUnavailableView(
                    "No Content",
                    systemImage: "doc.text",
                    description: Text("This file has no content to display.")
                )
            } else {
                codeView
            }
        }
        .overlay(alignment: .topTrailing) {
            if !file.isLoading && !file.content.isEmpty {
                Text(displayLanguage)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(12)
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

    private var codeView: some View {
        ScrollView([.horizontal, .vertical]) {
            let gutterWidth: CGFloat = CGFloat(String(lines.count).count) * 10 + 16

            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines, id: \.offset) { index, line in
                    HStack(alignment: .top, spacing: 0) {
                        Text("\(index + 1)")
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(Color(.systemGray3))
                            .frame(width: gutterWidth, alignment: .trailing)
                            .padding(.trailing, 12)

                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.85))
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 1)
                }
            }
            .padding()
        }
        .background(CPTheme.terminalBg)
    }
}

#if DEBUG
#Preview("File Viewer") {
    NavigationStack {
        FileViewerView(file: AppPreviewFixtures.previewFile)
    }
}
#endif
