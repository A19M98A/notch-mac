import Foundation
import AppKit
import Combine

struct ClipboardItem: Identifiable, Equatable, Codable {
    let id: UUID
    let content: String
    let date: Date
    var isPinned: Bool = false

    var preview: String {
        content
            .replacingOccurrences(of: "\n", with: " ↵ ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var relativeTime: String {
        let sec = Int(Date().timeIntervalSince(date))
        if sec < 10 { return "Just now" }
        if sec < 60 { return "\(sec)s ago" }
        let min = sec / 60
        if min < 60 { return "\(min)m ago" }
        let hr = min / 60
        if hr < 24 { return "\(hr)h ago" }
        let days = hr / 24
        return "\(days)d ago"
    }
}

final class ClipboardService: ObservableObject {
    @Published var items: [ClipboardItem] = []
    @Published var recentlyCopiedID: UUID? = nil

    private var lastChangeCount: Int
    private var pollTimer: Timer?
    private var maxItems = 100
    private let storageURL: URL

    func setMaxItems(_ limit: Int) {
        maxItems = max(10, min(500, limit))
        sortAndTrim(save: true)
    }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/.config/overlay"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        storageURL = URL(fileURLWithPath: "\(dir)/clipboard_history.json")

        lastChangeCount = NSPasteboard.general.changeCount
        loadFromDisk()

        if let initial = NSPasteboard.general.string(forType: .string),
           !initial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           items.first?.content != initial {
            insertClip(initial)
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }
    }

    deinit {
        pollTimer?.invalidate()
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: storageURL),
              let saved = try? JSONDecoder().decode([ClipboardItem].self, from: data) else {
            return
        }
        items = saved
        sortAndTrim(save: false)
    }

    private func saveToDisk() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(items) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }

    private func checkPasteboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        guard let text = pb.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        DispatchQueue.main.async {
            self.insertClip(text)
        }
    }

    private func insertClip(_ text: String) {
        if let existingIdx = items.firstIndex(where: { $0.content == text }) {
            let wasPinned = items[existingIdx].isPinned
            items.remove(at: existingIdx)
            items.insert(ClipboardItem(id: UUID(), content: text, date: Date(), isPinned: wasPinned), at: 0)
        } else {
            items.insert(ClipboardItem(id: UUID(), content: text, date: Date()), at: 0)
        }
        sortAndTrim(save: true)
    }

    func copy(_ item: ClipboardItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(item.content, forType: .string)
        lastChangeCount = pb.changeCount

        recentlyCopiedID = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.recentlyCopiedID == item.id {
                self?.recentlyCopiedID = nil
            }
        }
    }

    func togglePin(_ item: ClipboardItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].isPinned.toggle()
        sortAndTrim(save: true)
    }

    func delete(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        saveToDisk()
    }

    func clearUnpinned() {
        items.removeAll { !$0.isPinned }
        saveToDisk()
    }

    private func sortAndTrim(save: Bool) {
        let pinned = items.filter { $0.isPinned }
        let unpinned = items.filter { !$0.isPinned }.prefix(maxItems)
        items = pinned + unpinned
        if save {
            saveToDisk()
        }
    }
}
