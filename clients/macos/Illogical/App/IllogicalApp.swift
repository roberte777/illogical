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

    init() { Trace.log("app init") }

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
        VStack(spacing: 0) {
            Toolbar()
            Rectangle().fill(Palette.divider).frame(height: 1)
            // No divider under the breadcrumb: it sits on the terminal's own
            // background, as in Superlogical.
            Breadcrumb(terminal: store.selected)

            if let error = store.connectionError {
                ServerUnavailable(message: error)
            } else if let selected = store.selected {
                TerminalPane(terminal: selected)
                    .id(selected.id)
            } else {
                EmptyState()
            }
        }
        .background(Palette.background)
        .frame(minWidth: 720, minHeight: 460)
        .preferredColorScheme(.dark)
        .background(WindowChrome(toolbarHeight: Metrics.toolbarHeight))
        .ignoresSafeArea(.container, edges: .top)
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
        HStack(spacing: 0) {
            // Room the hidden title bar keeps for the traffic lights.
            Color.clear.frame(width: Metrics.trafficLightInset, height: 1)

            SessionButton()

            TabSeparator().padding(.horizontal, 7)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(store.visibleTerminals.enumerated()), id: \.element.id) {
                        index, terminal in
                        // A separator only between two adjacent inactive tabs;
                        // the active pill provides its own edge.
                        if index > 0, !isActive(index), !isActive(index - 1) {
                            TabSeparator().padding(.horizontal, 7)
                        } else if index > 0 {
                            Color.clear.frame(width: 3)
                        }

                        TerminalTab(
                            terminal: terminal,
                            isActive: terminal.id == store.selectedID,
                            select: { store.selectedID = terminal.id },
                            close: { store.kill(terminal.id) })
                    }
                }
            }

            Spacer(minLength: 8)

            Button {
                store.createTerminal()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Palette.textDim)
                    .frame(width: 28, height: Metrics.tabHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Terminal (⌘T)")
            .padding(.trailing, 10)
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
