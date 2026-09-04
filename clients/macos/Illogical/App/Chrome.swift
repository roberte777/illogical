//  Chrome.swift
//  The window chrome, modelled on the Superlogical Mac app.
//
//  Layout, from the demo recordings:
//
//      ┌────────────────────────────────────────────────────────────┐
//      │ ● ● ●   ⌂ Demo │ ▣ ~> blop │ ▣ ~/…> nvim │ ▣ ~/ghostty   + │  toolbar
//      ├────────────────────────────────────────────────────────────┤
//      │ ▣ ~/Documents/ghostty> nvim                                │  breadcrumb
//      │                                                            │
//      │  terminal                                                  │
//
//  The session button sits immediately right of the traffic lights and changes
//  session (⌘⇧K). Tabs are terminals *within* the current session, one per PTY,
//  the active one filled with a rounded pill. A thin breadcrumb row underneath
//  names the focused terminal.

import IllogicalProtocol
import SwiftUI

enum Palette {
    /// Sampled from the Superlogical recordings: a very dark, slightly blue
    /// ground rather than pure black.
    static let background = Color(red: 0.051, green: 0.098, blue: 0.129)
    static let toolbar = Color(red: 0.035, green: 0.075, blue: 0.102)
    static let activeTab = Color.white.opacity(0.10)
    static let hoverTab = Color.white.opacity(0.05)
    static let separator = Color.white.opacity(0.08)
    static let chromeText = Color.white.opacity(0.72)
    static let chromeTextDim = Color.white.opacity(0.42)
}

struct SessionButton: View {
    @Environment(SessionStore.self) private var store
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "house")
                    .font(.system(size: 11, weight: .medium))
                Text(store.selectedSession?.name ?? "no session")
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            .foregroundStyle(Palette.chromeText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Change Session (⌘⇧K)")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            SessionList(isPresented: $isPresented)
                .environment(store)
        }
    }
}

struct SessionList: View {
    @Environment(SessionStore.self) private var store
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Sessions")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 4)

            ForEach(store.sessions) { session in
                Button {
                    if let first = store.terminals.first(where: { $0.session == session.id }) {
                        store.selectedID = first.id
                    }
                    isPresented = false
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "house")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(session.name).font(.system(size: 12))
                        Spacer(minLength: 12)
                        Text("\(session.terminals.count)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if store.sessions.isEmpty {
                Text("No sessions yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }

            Divider().padding(.vertical, 4)

            Button {
                store.createTerminal(sessionName: "session-\(store.sessions.count + 1)")
                isPresented = false
            } label: {
                Label("New Session", systemImage: "plus")
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 6)
        }
        .frame(minWidth: 200)
    }
}

/// One terminal in the tab strip.
struct TerminalTab: View {
    let terminal: TerminalSummary
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(iconColor)
            Text(label)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.head)
                .foregroundStyle(isActive ? Palette.chromeText : Palette.chromeTextDim)

            if isHovering {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Palette.chromeTextDim)
                }
                .buttonStyle(.plain)
                .help("Close terminal")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .frame(maxWidth: 240)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Palette.activeTab : (isHovering ? Palette.hoverTab : .clear))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: select)
    }

    private var label: String {
        terminal.cwd.isEmpty
            ? "\(terminal.name)> \(terminal.command)"
            : "\(abbreviated(terminal.cwd))> \(terminal.command)"
    }

    private var icon: String {
        switch terminal.residency {
        case .live: "terminal"
        case .parked: "moon.zzz"
        case .rehydrating: "arrow.clockwise"
        case .exited: "xmark.circle"
        }
    }

    private var iconColor: Color {
        switch terminal.residency {
        case .live: Palette.chromeText
        case .parked: .orange.opacity(0.7)
        case .rehydrating: .yellow.opacity(0.7)
        case .exited: .red.opacity(0.7)
        }
    }

    private func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// The thin row under the toolbar naming the focused terminal.
struct Breadcrumb: View {
    let terminal: TerminalSummary?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.dashed")
                .font(.system(size: 9))
                .foregroundStyle(Palette.chromeTextDim)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Palette.chromeTextDim)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 22)
    }

    private var title: String {
        guard let terminal else { return "no terminal" }
        let location = terminal.cwd.isEmpty ? terminal.name : terminal.cwd
        return "\(location)> \(terminal.command)"
    }
}
