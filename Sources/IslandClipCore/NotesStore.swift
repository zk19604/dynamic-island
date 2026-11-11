import Combine
import Foundation

public struct Note: Codable, Identifiable, Equatable {
    public var id: UUID
    public var text: String
    public var updated: Date

    public init(id: UUID = UUID(), text: String = "", updated: Date = Date()) {
        self.id = id
        self.text = text
        self.updated = updated
    }
}

struct NotesFile: Codable {
    var notes: [Note]
    var selectedID: UUID?
}

/// Quick notes. There is always at least one note.
/// Text changes are saved after a short pause in typing (debounce).
public final class NotesStore: ObservableObject {
    public static let fileName = "notes.json"
    public static let maxNotes = 6

    @Published public private(set) var notes: [Note]
    @Published public private(set) var selectedID: UUID

    private let persistence: Persistence?
    private let saveDelay: TimeInterval
    private var pendingSave: DispatchWorkItem?

    public init(persistence: Persistence?, saveDelay: TimeInterval = 0.5) {
        self.persistence = persistence
        self.saveDelay = saveDelay
        let file = persistence?.load(NotesFile.self, from: Self.fileName)
        let loaded = file?.notes ?? []
        let notes = loaded.isEmpty ? [Note()] : loaded
        self.notes = notes
        self.selectedID = notes.first(where: { $0.id == file?.selectedID })?.id ?? notes[0].id
    }

    public var selectedNote: Note {
        notes.first(where: { $0.id == selectedID }) ?? notes[0]
    }

    public var selectedText: String { selectedNote.text }

    public func setSelectedText(_ text: String) {
        guard let index = notes.firstIndex(where: { $0.id == selectedID }),
              notes[index].text != text else { return }
        notes[index].text = text
        notes[index].updated = Date()
        scheduleSave()
    }

    public func select(_ id: UUID) {
        guard notes.contains(where: { $0.id == id }) else { return }
        selectedID = id
        scheduleSave()
    }

    public var canAddNote: Bool { notes.count < Self.maxNotes }

    public func addNote() {
        guard canAddNote else { return }
        let note = Note()
        notes.append(note)
        selectedID = note.id
        scheduleSave()
    }

    public func deleteNote(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes.remove(at: index)
        if notes.isEmpty { notes = [Note()] }
        if !notes.contains(where: { $0.id == selectedID }) {
            selectedID = notes[min(index, notes.count - 1)].id
        }
        scheduleSave()
    }

    /// Short label for a tab: first line of the note, or "Note N".
    public func title(for note: Note) -> String {
        let firstLine = note.text
            .split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if firstLine.isEmpty {
            let number = (notes.firstIndex(of: note) ?? 0) + 1
            return "Note \(number)"
        }
        return firstLine.count > 12 ? String(firstLine.prefix(11)) + "…" : firstLine
    }

    public func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        try? persistence?.save(NotesFile(notes: notes, selectedID: selectedID), to: Self.fileName)
    }

    private func scheduleSave() {
        guard persistence != nil else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: work)
    }
}
