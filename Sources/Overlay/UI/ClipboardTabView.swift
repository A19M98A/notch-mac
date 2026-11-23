import SwiftUI

struct ClipboardTabView: View {
    @EnvironmentObject var clipboardService: ClipboardService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Clipboard History (\(clipboardService.items.count))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                if !clipboardService.items.isEmpty {
                    Button("Clear Unpinned") {
                        clipboardService.clearUnpinned()
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .buttonStyle(.plain)
                }
            }

            if clipboardService.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("Clipboard is empty")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                    Text("Copy text anywhere and it will appear here for quick access.")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(clipboardService.items) { item in
                            HStack(spacing: 8) {
                                Button {
                                    clipboardService.copy(item)
                                } label: {
                                    HStack(spacing: 8) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.preview)
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(.white)
                                                .lineLimit(1)
                                            Text(item.relativeTime)
                                                .font(.system(size: 10))
                                                .foregroundStyle(.white.opacity(0.42))
                                        }
                                        Spacer()
                                        if clipboardService.recentlyCopiedID == item.id {
                                            Text("Copied")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(.green)
                                                .padding(.horizontal, 7)
                                                .padding(.vertical, 2)
                                                .background(Capsule().fill(Color.green.opacity(0.18)))
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Button {
                                    clipboardService.togglePin(item)
                                } label: {
                                    Image(systemName: item.isPinned ? "pin.fill" : "pin")
                                        .font(.system(size: 11))
                                        .foregroundStyle(item.isPinned ? .orange : .white.opacity(0.45))
                                        .frame(width: 22, height: 22)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    clipboardService.delete(item)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.4))
                                        .frame(width: 20, height: 20)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 9)
                                    .fill(item.isPinned ? Color.orange.opacity(0.08) : Color.white.opacity(0.05))
                            )
                        }
                    }
                }
            }
        }
    }
}
