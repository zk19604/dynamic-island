import IslandClipCore
import SwiftUI

struct NotesSectionView: View {
    @ObservedObject var store: NotesStore
    /// Copies text to the clipboard and adds it to the clipboard history.
    let onCopyText: (String) -> Void

    @State private var justCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(store.notes) { note in
                            NoteTab(title: store.title(for: note),
                                    isSelected: note.id == store.selectedID,
                                    canDelete: store.notes.count > 1,
                                    onSelect: { withAnimation(.easeOut(duration: 0.15)) { store.select(note.id) } },
                                    onDelete: { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { store.deleteNote(note.id) } })
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                circleButton(justCopied ? "checkmark" : "doc.on.doc",
                             tint: justCopied ? .green : .primary,
                             help: "Copy note", disabled: store.selectedText.isEmpty) {
                    onCopyText(store.selectedText)
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { justCopied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        withAnimation(.easeOut(duration: 0.2)) { justCopied = false }
                    }
                }
                circleButton("trash", tint: .primary,
                             help: store.notes.count > 1 ? "Delete note" : "Clear note",
                             disabled: store.notes.count == 1 && store.selectedText.isEmpty) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        if store.notes.count > 1 {
                            store.deleteNote(store.selectedID)
                        } else {
                            store.setSelectedText("")
                        }
                    }
                }

                if store.canAddNote {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { store.addNote() }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.primary.opacity(0.7))
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .help("New note")
                }
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { store.selectedText }, set: { store.setSelectedText($0) }))
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 6)
                    .id(store.selectedID) // fresh editor per note (resets scroll & undo)
                if store.selectedText.isEmpty {
                    Text("Jot something down…")
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(0.35))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
        }
    }

    private func circleButton(_ symbol: String, tint: Color, help: String, disabled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint.opacity(disabled ? 0.25 : 0.7))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .contentTransition(.opacity)
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(disabled)
        .help(help)
    }
}

private struct NoteTab: View {
    let title: String
    let isSelected: Bool
    let canDelete: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Text(title)
                .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(.primary.opacity(isSelected ? 0.95 : 0.5))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(isSelected ? 0.16 : 0)))
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.94))
        .contextMenu {
            if canDelete {
                Button("Delete Note", role: .destructive, action: onDelete)
            }
        }
        .help(canDelete ? "Right-click to delete" : "")
    }
}
