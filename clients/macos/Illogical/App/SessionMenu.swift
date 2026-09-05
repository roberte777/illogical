//  SessionMenu.swift
//  The session dropdown, matched to Superlogical's.
//
//      ┌────────────────────────────────┐
//      │ ⊜  Filter or create...         │  capsule field, 17pt
//      │                                │
//      │ ✓   Demo                       │  22pt row, ✓ in the icon column
//      │ ─────────────────────────────  │
//      │ ⊞   New Session          ⇧⌘N   │
//      │ ─────────────────────────────  │
//      │ ⊕   Add Remote Host...         │  hover: blue capsule, dark text
//      └────────────────────────────────┘
//
//  It is not an NSMenu or a system popover: there is no arrow, it is clipped by
//  the window, and it uses the app's own palette. So it is an in-window overlay
//  anchored to the session button's leading edge, just below the toolbar.
//
//  Geometry measured from the reference at 1.256 px/pt (toolbar = 39pt):
//  panel 172×~125pt at x=80, corner radius 10, 4pt padding; icon column at 11pt
//  from the panel edge, titles at 33pt; hover fill #5C9DF9 with dark text.

import IllogicalProtocol
import SwiftUI

enum MenuMetrics {
    static let width: CGFloat = 172
    static let padding: CGFloat = 4
    static let rowHeight: CGFloat = 22
    static let rowPadding: CGFloat = 7
    static let iconColumn: CGFloat = 13
    static let iconToTitle: CGFloat = 9
    static let cornerRadius: CGFloat = 10
    static let rowCornerRadius: CGFloat = 7
    static let fieldHeight: CGFloat = 17
    static let fieldToRows: CGFloat = 8
    static let separatorInset: CGFloat = 7
    static let separatorPadding: CGFloat = 6
    static let font: CGFloat = 13
}

extension Palette {
    static let menuTop = rgb(0x20_2C_3A)
    static let menuBottom = rgb(0x15_1F_2B)
    static let menuStroke = Color.white.opacity(0.09)
    static let menuField = rgb(0x11_1B_25)
    static let menuSeparator = rgb(0x1A_24_30)
    static let menuHighlight = rgb(0x5C_9D_F9)
    static let menuHighlightText = rgb(0x0D_1B_2E)
    static let menuText = rgb(0xD3_DB_DE)
    static let menuShortcut = rgb(0x7E_93_A4)
}

struct SessionMenu: View {
    @Environment(SessionStore.self) private var store
    @Binding var isPresented: Bool

    @State private var filter = ""
    @State private var hovered: String?
    @FocusState private var fieldFocused: Bool
    @State private var showingRemoteHostNotice = false

    private var matches: [SessionSummary] {
        guard !filter.isEmpty else { return store.sessions }
        return store.sessions.filter {
            $0.name.localizedCaseInsensitiveContains(filter)
        }
    }

    /// "Filter **or create**": a name that matches nothing can be made.
    private var canCreate: Bool {
        !filter.isEmpty
            && !store.sessions.contains { $0.name.caseInsensitiveCompare(filter) == .orderedSame }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterField
                .padding(.bottom, MenuMetrics.fieldToRows)

            if canCreate {
                MenuRow(
                    icon: "plus", title: "Create “\(filter)”", shortcut: "↩",
                    isHovered: hovered == "__create",
                    hover: { hovered = $0 ? "__create" : nil },
                    action: create)
                MenuSeparator()
            }

            ForEach(matches) { session in
                MenuRow(
                    icon: session.id == store.selectedSession?.id ? "checkmark" : nil,
                    title: session.name,
                    isHovered: hovered == "s\(session.id)",
                    hover: { hovered = $0 ? "s\(session.id)" : nil },
                    action: { select(session) })
            }

            if matches.isEmpty && !canCreate {
                Text("No sessions")
                    .font(.system(size: MenuMetrics.font))
                    .foregroundStyle(Palette.menuShortcut)
                    .frame(height: MenuMetrics.rowHeight)
            }

            MenuSeparator()

            MenuRow(
                icon: "rectangle.stack.badge.plus", title: "New Session", shortcut: "⇧⌘N",
                isHovered: hovered == "__new",
                hover: { hovered = $0 ? "__new" : nil },
                action: newSession)

            MenuSeparator()

            MenuRow(
                icon: "globe", title: "Add Remote Host…",
                isHovered: hovered == "__remote",
                hover: { hovered = $0 ? "__remote" : nil },
                action: { showingRemoteHostNotice = true })
        }
        .padding(MenuMetrics.padding)
        .frame(width: MenuMetrics.width)
        .background {
            RoundedRectangle(cornerRadius: MenuMetrics.cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Palette.menuTop, Palette.menuBottom],
                        startPoint: .top, endPoint: .bottom)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MenuMetrics.cornerRadius, style: .continuous)
                        .strokeBorder(Palette.menuStroke, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        }
        .onAppear { fieldFocused = true }
        .alert("Remote hosts are not implemented yet", isPresented: $showingRemoteHostNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(
                "Connecting to a server on another machine is milestone M5. "
                    + "Today the client talks to a local illogicald over a unix socket.")
        }
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 11))
                .foregroundStyle(Palette.menuShortcut)
            TextField("Filter or create...", text: $filter)
                .textFieldStyle(.plain)
                .font(.system(size: MenuMetrics.font))
                .foregroundStyle(Palette.menuText)
                .focused($fieldFocused)
                .onSubmit {
                    if canCreate { create() } else if let first = matches.first { select(first) }
                }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .frame(height: MenuMetrics.fieldHeight)
        .background(
            Capsule().fill(Palette.menuField)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
        )
    }

    private func select(_ session: SessionSummary) {
        if let first = store.tabs.first(where: { $0.session == session.id }) {
            store.selectedTabID = first.id
        }
        isPresented = false
    }

    private func create() {
        store.createTerminal(sessionName: filter)
        isPresented = false
    }

    private func newSession() {
        store.createTerminal(sessionName: "session-\(store.sessions.count + 1)")
        isPresented = false
    }
}

struct MenuRow: View {
    var icon: String?
    let title: String
    var shortcut: String?
    let isHovered: Bool
    let hover: (Bool) -> Void
    let action: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                }
            }
            .frame(width: MenuMetrics.iconColumn, alignment: .center)

            Spacer().frame(width: MenuMetrics.iconToTitle)

            Text(title)
                .font(.system(size: MenuMetrics.font))
                .lineLimit(1)

            Spacer(minLength: 8)

            if let shortcut {
                Text(shortcut)
                    .font(.system(size: MenuMetrics.font))
                    .foregroundStyle(
                        isHovered ? Palette.menuHighlightText.opacity(0.7) : Palette.menuShortcut)
            }
        }
        .foregroundStyle(isHovered ? Palette.menuHighlightText : Palette.menuText)
        .padding(.horizontal, MenuMetrics.rowPadding)
        .frame(height: MenuMetrics.rowHeight)
        .background {
            if isHovered {
                RoundedRectangle(cornerRadius: MenuMetrics.rowCornerRadius, style: .continuous)
                    .fill(Palette.menuHighlight)
            }
        }
        .contentShape(Rectangle())
        .onHover(perform: hover)
        .onTapGesture(perform: action)
    }
}

struct MenuSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Palette.menuSeparator)
            .frame(height: 1)
            .padding(.horizontal, MenuMetrics.separatorInset - MenuMetrics.padding)
            .padding(.vertical, MenuMetrics.separatorPadding)
    }
}
