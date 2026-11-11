import XCTest
@testable import IslandClipCore

final class ClipboardStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IslandClipTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + seconds) }

    func testNewestFirst() {
        let store = ClipboardStore(persistence: nil)
        store.add("one", date: date(1))
        store.add("two", date: date(2))
        XCTAssertEqual(store.items.map(\.text), ["two", "one"])
    }

    func testSkipsEmptyAndWhitespace() {
        let store = ClipboardStore(persistence: nil)
        XCTAssertNil(store.add(""))
        XCTAssertNil(store.add("  \n\t "))
        XCTAssertTrue(store.items.isEmpty)
    }

    func testDedupeMovesExistingToTop() {
        let store = ClipboardStore(persistence: nil)
        store.add("a", date: date(1))
        store.add("b", date: date(2))
        let firstID = store.items.last!.id
        store.add("a", date: date(3))
        XCTAssertEqual(store.items.map(\.text), ["a", "b"])
        XCTAssertEqual(store.items.first?.id, firstID, "re-copying keeps the same item")
    }

    func testPinnedStayOnTopAndSurviveDedupe() {
        let store = ClipboardStore(persistence: nil)
        store.add("pinned", date: date(1))
        store.togglePin(store.items[0].id)
        store.add("newer", date: date(2))
        XCTAssertEqual(store.items.map(\.text), ["pinned", "newer"])
        store.add("pinned", date: date(3))
        XCTAssertTrue(store.items[0].isPinned)
        store.togglePin(store.items[0].id)
        XCTAssertEqual(store.items.map(\.text), ["pinned", "newer"])
        XCTAssertFalse(store.items[0].isPinned)
    }

    func testEvictionKeepsPinned() {
        let store = ClipboardStore(persistence: nil, maxUnpinned: 3)
        store.add("keep", date: date(0))
        store.togglePin(store.items[0].id)
        for i in 1...10 { store.add("item \(i)", date: date(Double(i))) }
        XCTAssertEqual(store.items.count, 4)
        XCTAssertEqual(store.items.map(\.text), ["keep", "item 10", "item 9", "item 8"])
    }

    func testKeepsFiveNewestAndAllPinned() {
        let store = ClipboardStore(persistence: nil, maxUnpinned: 5)
        store.add("old pinned", date: date(0))
        store.togglePin(store.items[0].id)
        for i in 1...8 { store.add("item \(i)", date: date(Double(i))) }
        XCTAssertEqual(store.items.map(\.text),
                       ["old pinned", "item 8", "item 7", "item 6", "item 5", "item 4"])
    }

    func testEditingKeepsPositionThenMergesDuplicates() {
        let store = ClipboardStore(persistence: nil)
        store.add("a", date: date(1))
        store.add("b", date: date(2))
        let bID = store.items[0].id
        store.updateText(bID, to: "a")          // briefly equal to "a": nothing merged yet
        XCTAssertEqual(store.items.count, 2)
        store.updateText(bID, to: "b edited")
        store.finishEditing(bID)
        XCTAssertEqual(store.items.map(\.text), ["b edited", "a"])
        store.updateText(bID, to: "a")
        store.finishEditing(bID)                // now merged
        XCTAssertEqual(store.items.map(\.id), [bID])
        store.updateText(bID, to: "   ")
        store.finishEditing(bID)                // emptied -> deleted
        XCTAssertTrue(store.items.isEmpty)
    }

    func testDeleteAndClearUnpinned() {
        let store = ClipboardStore(persistence: nil)
        store.add("a", date: date(1))
        store.add("b", date: date(2))
        store.add("c", date: date(3))
        store.togglePin(store.items.first { $0.text == "a" }!.id)
        store.delete(store.items.first { $0.text == "b" }!.id)
        XCTAssertEqual(store.items.map(\.text), ["a", "c"])
        store.clearUnpinned()
        XCTAssertEqual(store.items.map(\.text), ["a"])
    }

    func testSearchIsCaseInsensitive() {
        let store = ClipboardStore(persistence: nil)
        store.add("Hello World", date: date(1))
        store.add("other", date: date(2))
        XCTAssertEqual(store.filtered("hello").map(\.text), ["Hello World"])
        XCTAssertEqual(store.filtered("  ").count, 2)
    }

    func testPersistenceRoundTripAndPermissions() throws {
        let persistence = Persistence(directory: tempDir)
        let store = ClipboardStore(persistence: persistence)
        store.add("secret-ish", date: date(1))
        store.add("pin me", date: date(2))
        store.togglePin(store.items.first { $0.text == "pin me" }!.id)
        store.saveNow()

        let reloaded = ClipboardStore(persistence: persistence)
        XCTAssertEqual(reloaded.items, store.items)

        let attrs = try FileManager.default.attributesOfItem(atPath: persistence.url(for: ClipboardStore.fileName).path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testCorruptFileIsBackedUpAndStoreStartsEmpty() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent(ClipboardStore.fileName)
        try Data("{ not json".utf8).write(to: fileURL)

        let store = ClipboardStore(persistence: Persistence(directory: tempDir))
        XCTAssertTrue(store.items.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("history.json.corrupt-") }, "files: \(files)")
        XCTAssertFalse(files.contains(ClipboardStore.fileName))
    }
}

final class NotesStoreTests: XCTestCase {
    func testNotesRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("IslandClipNotes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = Persistence(directory: dir)

        let store = NotesStore(persistence: persistence)
        XCTAssertEqual(store.notes.count, 1)
        store.setSelectedText("first note")
        store.addNote()
        store.setSelectedText("second")
        store.saveNow()

        let reloaded = NotesStore(persistence: persistence)
        XCTAssertEqual(reloaded.notes.map(\.text), ["first note", "second"])
        XCTAssertEqual(reloaded.selectedText, "second")
        XCTAssertEqual(reloaded.title(for: reloaded.notes[0]), "first note")
    }

    func testDeletingLastNoteLeavesOneEmptyNote() {
        let store = NotesStore(persistence: nil)
        store.setSelectedText("x")
        store.deleteNote(store.selectedID)
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.selectedText, "")
        XCTAssertEqual(store.title(for: store.notes[0]), "Note 1")
    }
}
