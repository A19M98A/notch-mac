import SwiftUI
import UniformTypeIdentifiers

struct ClipboardTabView: View {
    @EnvironmentObject var clipboardService: ClipboardService
    @State private var isDropTargeted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Top Header: 2-Mode Switcher (Text Clips | File Shelf) + Clear Action
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(ClipsMode.allCases) { mode in
                        let isSelected = clipboardService.clipsMode == mode
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                clipboardService.clipsMode = mode
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: mode.icon)
                                    .font(.system(size: 10, weight: .semibold))
                                Text(mode == .text
                                     ? "Text (\(clipboardService.items.count))"
                                     : "Files (\(clipboardService.shelfFiles.count))")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(isSelected ? Color.white.opacity(0.18) : Color.clear)
                            )
                            .foregroundStyle(isSelected ? .white : .white.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Capsule().fill(Color.white.opacity(0.07)))

                Spacer()

                if clipboardService.clipsMode == .text && !clipboardService.items.isEmpty {
                    Button("Clear Unpinned") {
                        clipboardService.clearUnpinned()
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .buttonStyle(.plain)
                } else if clipboardService.clipsMode == .files && !clipboardService.shelfFiles.isEmpty {
                    Button("Clear Shelf") {
                        clipboardService.clearShelf()
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .buttonStyle(.plain)
                }
            }

            // Mode Body
            if clipboardService.clipsMode == .text {
                textClipsView
            } else {
                fileShelfView
            }
        }
    }

    // MARK: - Mode 1: Persistent Text Clipboard History

    @ViewBuilder
    private var textClipsView: some View {
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

    // MARK: - Mode 2: Shortcut-Only File Shelf (Drop & Drag-Out Original Files)

    private var fileShelfView: some View {
        ZStack {
            if clipboardService.shelfFiles.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "tray.and.arrow.down")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(isDropTargeted ? .cyan : .white.opacity(0.45))
                    Text(isDropTargeted ? "Release to pin file shortcut" : "Drop files here")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(isDropTargeted ? .cyan : .white.opacity(0.7))
                    Text("Stores shortcuts only (zero copying) · Drag out to any app as the original file")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.42))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(clipboardService.shelfFiles) { file in
                            fileShelfCard(file)
                        }
                    }
                    .padding(2)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isDropTargeted ? Color.cyan.opacity(0.14) : Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(
                            isDropTargeted ? Color.cyan : Color.white.opacity(0.12),
                            style: StrokeStyle(lineWidth: isDropTargeted ? 1.5 : 1, dash: [5, 4])
                        )
                )
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleFileDrop(providers)
        }
    }

    private func fileShelfCard(_ file: FileShelfItem) -> some View {
        let icon = NSWorkspace.shared.icon(forFile: file.path)

        return HStack(spacing: 8) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(file.fileName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(file.exists ? .white : .red.opacity(0.8))
                    .lineLimit(1)
                Text(file.exists ? file.parentFolder : "Moved / Missing")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }

            Spacer(minLength: 2)

            Button {
                clipboardService.revealInFinder(file)
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Reveal original file in Finder")

            Button {
                clipboardService.removeShelfFile(file)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help("Remove shortcut from shelf")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
        .onDrag {
            // Drag the original file URL directly from its original disk location (never copies!)
            NSItemProvider(object: file.url as NSURL)
        }
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    var resolvedURL: URL?
                    if let data = item as? Data {
                        resolvedURL = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let url = item as? URL {
                        resolvedURL = url
                    } else if let str = item as? String {
                        resolvedURL = URL(string: str)
                    }
                    if let url = resolvedURL, url.isFileURL {
                        DispatchQueue.main.async {
                            clipboardService.addShelfURLs([url])
                        }
                    }
                }
            }
        }
        return accepted
    }
}
