//  IllogicalApp.swift
//  Entry point for the Illogical Mac client.
//
//  Launch budget: the window and its chrome must not wait on the network. We
//  draw immediately and fill the terminal in as the attach handshake's snapshot
//  arrives. See docs/GOALS.md G7.

import SwiftUI

@main
struct IllogicalApp: App {
    @State private var store = SessionStore()

    init() {
        Signposts.processStart = Date()
        Trace.log("app init")
    }

    var body: some Scene {
        Window("Illogical", id: "main") {
            ContentView()
                .environment(store)
                .task {
                    Trace.log("content task fired")
                    store.connect()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Terminal") { store.createTerminal() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("New Session") {
                    store.createTerminal(sessionName: "session-\(store.sessions.count + 1)")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Split Right") { store.split(.horizontal) }
                    .keyboardShortcut("d", modifiers: .command)
                Button("Split Down") { store.split(.vertical) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Close Pane") { store.closeFocusedPane() }
                    .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh Sessions") { store.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

struct ContentView: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            Rectangle().fill(Palette.divider).frame(height: 1)
            // No divider under the breadcrumb: it sits on the terminal's own
            // background, as in Superlogical.
            Breadcrumb(terminal: store.focusedTerminal ?? store.selected)

            if let error = store.connectionError {
                ServerUnavailable(message: error)
            } else if store.selected != nil {
                SplitTreeView(
                    tree: store.layout,
                    terminals: Dictionary(
                        uniqueKeysWithValues: store.terminals.map { ($0.id, $0) }))
            } else {
                EmptyState()
            }
        }
        .background(Palette.background)
        .overlay {
            if store.sessionMenuOpen {
                ZStack(alignment: .topLeading) {
                    // Dismiss on a click anywhere else, the way a menu does.
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { store.sessionMenuOpen = false }

                    SessionMenu(isPresented: $store.sessionMenuOpen)
                        .environment(store)
                        // Anchored to the session button's leading edge. The
                        // toolbar is in the title bar now, so this is measured
                        // from the top of the content view.
                        .offset(x: Metrics.contentInset - 1, y: 1)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .preferredColorScheme(.dark)
        .onAppear { Signposts.markWindowVisible() }
        .background(
            WindowChrome(toolbarHeight: Metrics.toolbarHeight) {
                Toolbar().environment(store)
            }
        )
    }
}

/// The unified toolbar: traffic lights, session button, tab strip, new-tab.
struct Toolbar: View {
    @Environment(SessionStore.self) private var store

    private func isActive(_ index: Int) -> Bool {
        let terminals = store.visibleTerminals
        guard terminals.indices.contains(index) else { return false }
        return terminals[index].id == store.selectedID
    }

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 0) {
            // AppKit has already offset this accessory past the traffic
            // lights; this is the remainder that lands the session icon at
            // 90.7pt in the window, where Superlogical's sits.
            Color.clear.frame(width: Metrics.toolbarLeading, height: 1)

            SessionButton(isPresented: $store.sessionMenuOpen)

            Color.clear.frame(width: Metrics.sessionToTabs, height: 1)

            // Fixed-width slots laid edge to edge, as in the reference.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(store.visibleTerminals.enumerated()), id: \.element.id) {
                        index, terminal in
                        TerminalTab(
                            terminal: terminal,
                            isActive: isActive(index),
                            showsLeadingSeparator: index > 0 && !isActive(index)
                                && !isActive(index - 1),
                            select: { store.selectedID = terminal.id },
                            close: { store.kill(terminal.id) })
                    }
                }
            }
            // Cap the strip at its content width so the leftover toolbar is
            // genuinely empty and can drag the window. When the tabs outgrow
            // the window this clamps to the available width and scrolls.
            .frame(maxWidth: CGFloat(store.visibleTerminals.count) * Metrics.tabWidth)

            // Bare title bar drags the window; AppKit handles it because the
            // toolbar is a title bar accessory.
            Spacer(minLength: 8)

            Button {
                store.createTerminal()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Palette.textDim)
                    .frame(width: Metrics.plusWidth, height: Metrics.tabHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Terminal (⌘T)")
            .padding(.trailing, Metrics.plusTrailing)
        }
        .frame(height: Metrics.toolbarHeight)
        .background(Palette.toolbar)
    }
}

struct EmptyState: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("No terminals")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.textBright)
            Text("Sessions keep running after you close this window.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.textDim)
            Button("New Terminal") { store.createTerminal() }
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
    }
}

struct ServerUnavailable: View {
    let message: String
    @Environment(SessionStore.self) private var store

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 26))
                .foregroundStyle(Palette.textDim)
            Text("No server")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.textBright)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Palette.textDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Try Again") { store.connect() }
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
    }
}
