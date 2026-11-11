import IslandClipCore
import SwiftUI

/// Spring used when a row opens into the editor and back.
private let openSpring = Animation.spring(response: 0.42, dampingFraction: 0.8)

struct ClipboardSectionView: View {
    @ObservedObject var store: ClipboardStore
    let monitor: ClipboardMonitor
    let onCopy: (ClipItem) -> Void
    /// Makes the panel key so the editor can take keyboard focus right away.
    let focusPanel: () -> Void

    @State private var query = ""
    @State private var editingID: UUID?
    @Namespace private var cards

    var body: some View {
        ZStack(alignment: .top) {
            if let id = editingID, let item = store.items.first(where: { $0.id == id }) {
                ClipEditor(item: item, namespace: cards,
                           text: Binding(get: { store.items.first(where: { $0.id == id })?.text ?? "" },
                                         set: { store.updateText(id, to: $0) }),
                           onClose: { closeEditor() },
                           onCopy: { finishAndCopy(item) },
                           onPin: { withAnimation(openSpring) { store.togglePin(id) } },
                           onDelete: {
                               withAnimation(openSpring) {
                                   editingID = nil
                                   store.delete(id)
                               }
                           },
                           focusPanel: focusPanel)
                    // Island closed mid-edit: still tidy up the edit.
                    .onDisappear { store.finishEditing(id) }
                    .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.05)),
                                            removal: .opacity.animation(.easeIn(duration: 0.1))))
            } else {
                list
                    .transition(.opacity)
            }
        }
    }

    private var list: some View {
        let items = store.filtered(query)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SearchField(text: $query)
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { store.clearUnpinned() }
                } label: {
                    Text("Clear all")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.6))
                }
                .buttonStyle(PressableButtonStyle())
                .help("Clear all (except pinned)")
                .disabled(!store.items.contains { !$0.isPinned })
            }

            if monitor.isAccessDenied {
                Text("Clipboard access is denied. Allow IslandClip in System Settings › Privacy & Security.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            if items.isEmpty {
                Text(query.isEmpty ? "Copy some text and it shows up here." : "No matches")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Relative times refresh every 30 s while the panel is open.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 4) {
                            ForEach(items) { item in
                                ClipRow(item: item, now: context.date, namespace: cards,
                                        onOpen: { withAnimation(openSpring) { editingID = item.id } },
                                        onCopy: { onCopy(item) },
                                        onPin: { withAnimation(openSpring) { store.togglePin(item.id) } },
                                        onDelete: { withAnimation(openSpring) { store.delete(item.id) } })
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                            }
                        }
                    }
                }
            }
        }
    }

    private func closeEditor() {
        guard let id = editingID else { return }
        withAnimation(openSpring) {
            editingID = nil
            store.finishEditing(id)
        }
    }

    private func finishAndCopy(_ item: ClipItem) {
        store.finishEditing(item.id)
        if let latest = store.items.first(where: { $0.id == item.id }) { onCopy(latest) }
    }
}

// MARK: - Editor

private struct ClipEditor: View {
    let item: ClipItem
    let namespace: Namespace.ID
    @Binding var text: String
    let onClose: () -> Void
    let onCopy: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void
    let focusPanel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button(action: onClose) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                        Text("Done").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.primary.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
                }
                .buttonStyle(PressableButtonStyle(pressedScale: 0.94))
                .keyboardShortcut(.return, modifiers: .command)
                .help("Save and go back (⌘↩)")

                Spacer()
                Text("Edits are saved automatically")
                    .font(.system(size: 10))
                    .foregroundStyle(.primary.opacity(0.35))
                ClipIconButton(symbol: "doc.on.doc", tint: .primary, bright: true, help: "Copy", action: onCopy)
                ClipIconButton(symbol: item.isPinned ? "pin.fill" : "pin", tint: item.isPinned ? .yellow : .primary,
                               bright: true, help: item.isPinned ? "Unpin" : "Pin", action: onPin)
                ClipIconButton(symbol: "trash", tint: .primary, bright: true, help: "Delete", action: onDelete)
            }

            TextEditor(text: $text)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.09))
                        .matchedGeometryEffect(id: item.id, in: namespace))
        }
        .onAppear {
            // Let the open animation start, then put the cursor in the text.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                focusPanel()
                focused = true
            }
        }
    }
}

// MARK: - List pieces

struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary.opacity(0.45))
            TextField("Search history", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.45))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.08)))
    }
}

struct ClipRow: View {
    let item: ClipItem
    let now: Date
    let namespace: Namespace.ID
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private var preview: String {
        // Long items: only the start is rendered; the tooltip has more.
        String(item.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
    }

    private var relativeTime: String {
        now.timeIntervalSince(item.date) < 10 ? "just now" : Self.formatter.localizedString(for: item.date, relativeTo: now)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(preview)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(0.92))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(relativeTime)
                        .font(.system(size: 10))
                        .foregroundStyle(.primary.opacity(0.4))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 0.98))
            .help("Click to open and edit")

            ClipIconButton(symbol: "doc.on.doc", tint: .primary, bright: true, help: "Copy", action: onCopy)
            ClipIconButton(symbol: item.isPinned ? "pin.fill" : "pin", tint: item.isPinned ? .yellow : .primary,
                           bright: hovering || item.isPinned, help: item.isPinned ? "Unpin" : "Pin", action: onPin)
            ClipIconButton(symbol: "trash", tint: .primary, bright: hovering, help: "Delete", action: onDelete)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.13 : 0.05))
                .matchedGeometryEffect(id: item.id, in: namespace))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

struct ClipIconButton: View {
    let symbol: String
    let tint: Color
    let bright: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint.opacity(bright ? 0.85 : 0.3))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .help(help)
    }
}
