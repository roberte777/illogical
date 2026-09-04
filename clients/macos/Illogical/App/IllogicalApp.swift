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
            Divider().overlay(Palette.separator)
            Breadcrumb(terminal: store.selected)
            Divider().overlay(Palette.separator)

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
    }
}

/// The unified toolbar: traffic lights, session button, tab strip, new-tab.
struct Toolbar: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        HStack(spacing: 0) {
            // Room for the traffic lights, which the hidden title bar keeps.
            Color.clear.frame(width: 78, height: 1)

            SessionButton()

            Divider()
                .frame(height: 16)
                .overlay(Palette.separator)
                .padding(.horizontal, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(store.visibleTerminals) { terminal in
                        TerminalTab(
                            terminal: terminal,
                            isActive: terminal.id == store.selectedID,
                            select: { store.selectedID = terminal.id },
                            close: { store.kill(terminal.id) })
                    }
                }
                .padding(.horizontal, 2)
            }

            Spacer(minLength: 8)

            Button {
                store.createTerminal()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.chromeText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Terminal (⌘T)")
            .padding(.trailing, 8)
        }
        .frame(height: 38)
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
                .foregroundStyle(Palette.chromeText)
            Text("Sessions keep running after you close this window.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.chromeTextDim)
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
                .foregroundStyle(Palette.chromeTextDim)
            Text("No server")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.chromeText)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Palette.chromeTextDim)
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
