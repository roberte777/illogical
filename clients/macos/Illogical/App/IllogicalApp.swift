//  IllogicalApp.swift
//  Entry point for the Illogical Mac client.
//
//  Launch budget: the window and its chrome must not wait on the network. We
//  draw immediately and fill the terminal in as the attach handshake's snapshot
//  arrives. See docs/GOALS.md G7.

import QuartzCore
import SwiftUI

@main
struct IllogicalApp: App {
    @State private var store = SessionStore()

    init() {
        Trace.log("app init")
        Signposts.milestone("app-init", seconds: Signposts.sinceLaunch())
    }

    var body: some Scene {
        Window("Illogical", id: "main") {
            ContentView()
                .environment(store)
                .onAppear { LaunchReport.contentDidAppear() }
                .task {
                    Trace.log("content task fired")
                    // Connecting is deliberately *after* the first layout:
                    // nothing on screen waits for the network. G7.
                    store.connect()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Terminal") { store.createTerminal() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("New Session") {
                    // On the machine in front, which is where ⌘T would put a
                    // terminal too.
                    let count = store.selectedHost?.sessions.count ?? 0
                    store.createTerminal(sessionName: "session-\(count + 1)")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            // Splits. ⌘W is deliberately absent: closing a pane goes through
            // the responder chain as `performClose:`, so the surface gets
            // first refusal and the standard Close Window item keeps working
            // when there is only one pane. See TerminalSurfaceView.
            CommandGroup(after: .newItem) {
                Divider()
                Button("Split Right") { store.split(.columns) }
                    .keyboardShortcut("d", modifiers: .command)
                Button("Split Down") { store.split(.rows) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button(store.selectedTab?.zoomed == nil ? "Zoom Pane" : "Unzoom Pane") {
                    store.toggleZoomOnFocusedPane()
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(store.selectedTab?.isSplit != true)
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh Sessions") { store.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Focus Pane Left") { store.moveFocus(.left) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("Focus Pane Right") { store.moveFocus(.right) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Focus Pane Above") { store.moveFocus(.up) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Focus Pane Below") { store.moveFocus(.down) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
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

            if let error = store.connectionError {
                ServerUnavailable(message: error)
            } else if let tab = store.selectedTab {
                // Each pane carries its own header. There is no divider under
                // it: it sits on the terminal's own background, as in
                // Superlogical.
                SplitContainer(tab: tab)
                    .environment(store)
                    .id(tab.id)
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
        let tabs = store.visibleTabs
        guard tabs.indices.contains(index) else { return false }
        return tabs[index].id == store.selectedTabID
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
                    ForEach(Array(store.visibleTabs.enumerated()), id: \.element.id) {
                        index, tab in
                        TerminalTab(
                            // A tab's label is its focused pane's terminal, so
                            // a split tab names what you are working in rather
                            // than what it started as.
                            terminal: store.label(for: tab),
                            isActive: isActive(index),
                            showsLeadingSeparator: index > 0 && !isActive(index)
                                && !isActive(index - 1),
                            select: { store.selectedTabID = tab.id },
                            close: { store.closeTab(tab.id) })
                    }
                }
            }
            // Cap the strip at its content width so the leftover toolbar is
            // genuinely empty and can drag the window. When the tabs outgrow
            // the window this clamps to the available width and scrolls.
            .frame(maxWidth: CGFloat(store.visibleTabs.count) * Metrics.tabWidth)

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

/// When the window actually reached the screen.
///
/// `onAppear` fires during a layout pass, before anything has been handed to
/// the render server. Committing an empty transaction from inside that pass
/// gets a completion block that runs once the enclosing commit has gone
/// through — which is the first moment the chrome is genuinely visible, and
/// the number docs/GOALS.md G7 is about.
@MainActor
enum LaunchReport {
    private static var reported = false

    static func contentDidAppear() {
        guard !reported else { return }
        reported = true
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            Signposts.milestone("window-visible", seconds: Signposts.sinceLaunch())
        }
        CATransaction.commit()
    }
}
