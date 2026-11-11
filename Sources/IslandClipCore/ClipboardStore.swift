import Combine
import Foundation

public struct ClipItem: Codable, Identifiable, Equatable {
    public var id: UUID
    public var text: String
    public var date: Date
    public var isPinned: Bool

    public init(id: UUID = UUID(), text: String, date: Date = Date(), isPinned: Bool = false) {
        self.id = id
        self.text = text
        self.date = date
        self.isPinned = isPinned
    }
}

/// Clipboard history: pinned items first, then newest first.
/// Unpinned items are capped at `maxUnpinned`; pinned items are never evicted.
public final class ClipboardStore: ObservableObject {
    public static let fileName = "history.json"
    /// Very large copies (e.g. whole log files) are skipped to keep the history file small.
    public static let maxTextLength = 200_000

    @Published public private(set) var items: [ClipItem] = []
    public let maxUnpinned: Int

    private let persistence: Persistence?
    private var pendingSave: DispatchWorkItem?
    private let saveDelay: TimeInterval

    public init(persistence: Persistence?, maxUnpinned: Int = 50, saveDelay: TimeInterval = 1.0) {
        self.persistence = persistence
        self.maxUnpinned = maxUnpinned
        self.saveDelay = saveDelay
        if let loaded = persistence?.load([ClipItem].self, from: Self.fileName) {
            items = Self.normalized(loaded, maxUnpinned: maxUnpinned)
        }
    }

    /// Adds text to the top. If the same text is already stored it is moved
    /// to the top instead (keeping its pin). Returns nil for skipped input.
    @discardableResult
    public func add(_ text: String, date: Date = Date()) -> ClipItem? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= Self.maxTextLength else { return nil }
        var updated = items
        let item: ClipItem
        if let index = updated.firstIndex(where: { $0.text == text }) {
            updated[index].date = date
            item = updated[index]
        } else {
            item = ClipItem(text: text, date: date)
            updated.append(item)
        }
        commit(updated)
        return item
    }

    /// Marks an item as just used (e.g. copied back) so it moves to the top.
    public func touch(_ id: UUID, date: Date = Date()) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var updated = items
        updated[index].date = date
        commit(updated)
    }

    /// Live edit of an item's text. Order and date stay the same, and
    /// duplicates aren't merged until `finishEditing` (so typing never
    /// deletes another item by briefly matching it).
    public func updateText(_ id: UUID, to text: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].text != text else { return }
        var updated = items
        updated[index].text = text
        commit(updated)
    }

    /// Call when editing ends: an emptied item is deleted, and other items
    /// with the same text are merged into this one.
    public func finishEditing(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            delete(id)
            return
        }
        let merged = items.filter { $0.id == id || $0.text != item.text }
        if merged.count != items.count { commit(merged) }
    }

    public func togglePin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var updated = items
        updated[index].isPinned.toggle()
        commit(updated)
    }

    public func delete(_ id: UUID) {
        commit(items.filter { $0.id != id })
    }

    /// Clears everything except pinned items.
    public func clearUnpinned() {
        commit(items.filter(\.isPinned))
    }

    public func filtered(_ query: String) -> [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        return items.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    public func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        try? persistence?.save(items, to: Self.fileName)
    }

    // MARK: - Private

    private func commit(_ newItems: [ClipItem]) {
        items = Self.normalized(newItems, maxUnpinned: maxUnpinned)
        scheduleSave()
    }

    private func scheduleSave() {
        guard persistence != nil else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: work)
    }

    static func normalized(_ items: [ClipItem], maxUnpinned: Int) -> [ClipItem] {
        let pinned = items.filter(\.isPinned).sorted { $0.date > $1.date }
        let unpinned = items.filter { !$0.isPinned }.sorted { $0.date > $1.date }
        return pinned + unpinned.prefix(max(0, maxUnpinned))
    }
}
