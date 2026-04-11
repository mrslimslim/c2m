import SwiftUI
import CodePilotCore
import CodePilotFeatures
import CodePilotProtocol

struct DiffViewerView: View {
    @EnvironmentObject private var appModel: AppModel

    let sessionID: String
    let eventId: Int
    let changes: [FileChange]

    @State private var requestedInitialLoad = false
    @State private var localErrorMessage: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                summaryCard

                if let state = diffState {
                    if state.isLoading && state.files.isEmpty {
                        loadingCard
                    } else if let errorMessage = state.errorMessage, state.files.isEmpty {
                        errorCard(message: errorMessage)
                    } else {
                        ForEach(state.files, id: \.path) { file in
                            DiffFileSection(
                                sessionID: sessionID,
                                eventId: eventId,
                                file: file,
                                displayPath: displayPath(file.path),
                                isLoadingMore: state.loadingMorePaths.contains(file.path),
                                fileError: state.fileErrorsByPath[file.path],
                                onLoadNextHunk: loadNextHunk
                            )
                        }
                    }
                } else {
                    loadingCard
                }
            }
            .padding()
        }
        .background(Color(.systemBackground))
        .navigationTitle("Diff")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Error", isPresented: Binding(
            get: { localErrorMessage != nil },
            set: { if !$0 { localErrorMessage = nil } }
        )) {
            Button("OK") { localErrorMessage = nil }
        } message: {
            Text(localErrorMessage ?? "")
        }
        .onAppear {
            ensureDiffLoaded()
        }
    }

    private var diffState: DiffState? {
        appModel.diffState(for: sessionID, eventID: eventId)
    }

    private var viewModel: SessionDetailViewModel {
        appModel.makeSessionDetailViewModel(sessionID: sessionID)
    }

    private var sessionWorkDir: String? {
        appModel.session(for: sessionID)?.workDir
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(changes.count) file\(changes.count == 1 ? "" : "s") changed")
                .font(.headline)

            ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                HStack(spacing: 8) {
                    Image(systemName: CPTheme.fileChangeIcon(change.kind))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CPTheme.fileChangeColor(change.kind))

                    Text(displayPath(change.path))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(CPTheme.fileChangeLabel(change.kind))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CPTheme.fileChangeColor(change.kind))
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Loading diff...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func errorCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Diff unavailable")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(CPTheme.error)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Retry") {
                requestedInitialLoad = false
                ensureDiffLoaded()
            }
            .font(.caption.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(CPTheme.errorBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func ensureDiffLoaded() {
        guard !requestedInitialLoad else { return }
        if let state = diffState, state.isLoading || !state.files.isEmpty {
            requestedInitialLoad = true
            return
        }
        do {
            requestedInitialLoad = true
            try viewModel.requestDiff(eventId: eventId)
            appModel.refreshPublishedState()
        } catch {
            localErrorMessage = "Failed to request diff."
        }
    }

    private func loadNextHunk(path: String, afterHunkIndex: Int) {
        do {
            try viewModel.requestMoreDiffHunks(
                eventId: eventId,
                path: path,
                afterHunkIndex: afterHunkIndex
            )
            appModel.refreshPublishedState()
        } catch {
            localErrorMessage = "Failed to request additional hunks."
        }
    }

    private func displayPath(_ rawPath: String) -> String {
        guard let sessionWorkDir, !sessionWorkDir.isEmpty else {
            return rawPath
        }

        let standardizedRawPath = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        guard standardizedRawPath.hasPrefix("/") else {
            return rawPath
        }

        let standardizedWorkDir = URL(fileURLWithPath: sessionWorkDir).standardizedFileURL.path
        guard standardizedRawPath == standardizedWorkDir
            || standardizedRawPath.hasPrefix(standardizedWorkDir + "/") else {
            return rawPath
        }

        let trimmed = String(standardizedRawPath.dropFirst(standardizedWorkDir.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? rawPath : trimmed
    }
}

private struct DiffFileSection: View {
    let sessionID: String
    let eventId: Int
    let file: DiffFile
    let displayPath: String
    let isLoadingMore: Bool
    let fileError: String?
    let onLoadNextHunk: (String, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayPath)
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Text(CPTheme.fileChangeLabel(file.kind))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(CPTheme.fileChangeColor(file.kind))
                        if let addedLines = file.addedLines, let deletedLines = file.deletedLines {
                            Text("+\(addedLines) / -\(deletedLines)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                if file.kind == .delete {
                    Text("Deleted")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                } else {
                    NavigationLink {
                        RequestedFileViewerView(sessionID: sessionID, path: file.path)
                    } label: {
                        Text("Open File")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
            }

            ForEach(Array(file.loadedHunks.enumerated()), id: \.offset) { _, hunk in
                DiffHunkView(hunk: hunk)
            }

            if let fileError {
                Text(fileError)
                    .font(.caption)
                    .foregroundStyle(CPTheme.error)
            }

            if let nextHunkIndex = file.nextHunkIndex {
                Button {
                    onLoadNextHunk(file.path, nextHunkIndex)
                } label: {
                    HStack(spacing: 8) {
                        if isLoadingMore {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Load next hunk")
                            .font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(CPTheme.accent)
                .disabled(isLoadingMore)
            }

            if file.isTruncated, let truncationReason = file.truncationReason {
                Text(truncationReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct DiffHunkView: View {
    let hunk: DiffHunk

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("@@ -\(hunk.oldStart),\(hunk.oldLineCount) +\(hunk.newStart),\(hunk.newLineCount) @@")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemFill))

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                    DiffLineRow(line: line)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.separator).opacity(0.4), lineWidth: 0.5)
        )
    }
}

private struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        Text(line.text.isEmpty ? " " : line.text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .background(backgroundColor)
    }

    private var backgroundColor: Color {
        switch line.kind {
        case .context:
            return CPTheme.terminalBg.opacity(0.35)
        case .add:
            return CPTheme.success.opacity(0.14)
        case .delete:
            return CPTheme.error.opacity(0.14)
        }
    }
}

private struct RequestedFileViewerView: View {
    @EnvironmentObject private var appModel: AppModel

    let sessionID: String
    let path: String

    @State private var errorMessage: String?
    @State private var requested = false

    var body: some View {
        Group {
            if let file = appModel.fileState(for: sessionID, path: path) {
                FileViewerView(file: file)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading file...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
            }
        }
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            guard !requested else { return }
            requested = true
            do {
                try appModel.makeSessionDetailViewModel(sessionID: sessionID).requestFile(path: path)
                appModel.refreshPublishedState()
            } catch {
                errorMessage = "Failed to request file."
            }
        }
    }
}
