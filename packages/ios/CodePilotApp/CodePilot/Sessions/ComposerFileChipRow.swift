import SwiftUI
import CodePilotProtocol

struct ComposerFileChipRow: View {
    let files: [FileSearchMatch]
    let onRemove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(files, id: \.path) { file in
                    HStack(spacing: 6) {
                        Image(systemName: "at")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(CPTheme.accent)

                        Text(file.displayName ?? file.path)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)

                        Button {
                            onRemove(file.path)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(CPTheme.divider, lineWidth: 0.5)
                    )
                }
            }
        }
    }
}
