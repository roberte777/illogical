//  IllogicalApp.swift
//  Entry point for the Illogical Mac client.
//
//  Launch budget: the window and the first painted frame must not wait on the
//  network. The app renders its chrome immediately, then fills the terminal in
//  as the attach handshake's snapshot READY prefix arrives. See docs/GOALS.md.

import SwiftUI

@main
struct IllogicalApp: App {
    @State private var store = SessionStore()

    var body: some Scene {
        Window("Illogical", id: "main") {
            ContentView()
                .environment(store)
                .task { store.connect() }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") {
                    // TODO(M2): send `create`.
                }
                .keyboardShortcut("t", modifiers: .command)
            }
        }
    }
}

struct ContentView: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        TerminalSurface()
            .frame(minWidth: 640, minHeight: 400)
            .toolbar {
                ToolbarItem(placement: .navigation) { SessionPicker() }
                ToolbarItem(placement: .primaryAction) {
                    Text(store.host.displayName)
                        .foregroundStyle(.secondary)
                }
            }
    }
}
