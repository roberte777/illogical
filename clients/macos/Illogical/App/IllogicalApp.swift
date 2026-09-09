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
        // Before the first window, because the font a surface is built with
        // comes from here and a grid cannot be rebuilt for free.
        AppConfig.load()
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
                // On the machine in front, which is where ⌘T would put a
                // terminal too. What it is called is the store's to decide.
                Button("New Session") { store.createSession() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                // No key equivalents. Both are rare, one of them is
                // destructive, and a chord for either would be spent for the
                // life of the app on something reached a few times a week.
                //
                // Rename opens the dropdown rather than a sheet: the field is
                // the row itself, which is where the name is read, and this is
                // the same gesture the row's own context menu performs.
                Button("Rename Session…") {
                    if let ref = store.selectedSession { store.requestRenameSession(ref) }
                }
                .disabled(store.selectedSession == nil)
                // Also disabled while the machine is being reconnected to. The
                // session is still listed — `controlClosed` keeps the lists on
                // purpose — but nothing can be sent, and the dialog behind this
                // says "This cannot be undone."
                Button("Delete Session…") {
                    if let ref = store.selectedSession { store.requestDeleteSession(ref) }
                }
                .disabled(store.selectedSession.map { !store.canDeleteSession($0) } ?? true)
            }
            // Closing and splits. ⌘W itself is deliberately absent: it goes
            // through the responder chain as `performClose:`, so the focused
            // surface gets first refusal and the standard Close Window item
            // keeps working when the terminal it closed was the last one in
            // the window. See TerminalSurfaceView and SessionStore's
            // `closeSurfacePane`.
            CommandGroup(after: .newItem) {
                Divider()
                Button("Close Tab") {
                    if let id = store.selectedTabID { WindowClose.tab(id, in: store) }
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(store.selectedTabID == nil)
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
            // Find, where macOS puts it: after the pasteboard items in Edit.
            // Menu items rather than a key monitor, for the reason the tab
            // chords are — a chord a menu claims never reaches `keyDown`, so
            // ⌘F cannot also be typed into the terminal.
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Find…") { store.beginFind() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(store.selectedController == nil)
                Button("Find Next") { store.findNext() }
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(!store.canFindAgain)
                Button("Find Previous") { store.findPrevious() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(!store.canFindAgain)
            }
            CommandGroup(after: .toolbar) {
                // ⌘K rather than ⇧⌘K: switching sessions is the most reached-for
                // thing in the chrome, and unshifted is where every other app
                // puts its switcher. The cost is the iTerm/Ghostty "clear
                // scrollback" convention — a chord this menu claims can never
                // reach `keyDown`, so ⌘K is now unavailable to the terminal.
                Button("Change Session") { store.toggleSessionMenu() }
                    .keyboardShortcut("k", modifiers: .command)
                // No key equivalent, on the same rule as Rename and Delete
                // Session: a chord spent here would be spent for the life of
                // the app on something most windows, which have one machine in
                // them, never reach for at all.
                //
                // And deliberately not the ⇧⌘K the line above has just freed,
                // tempting as an empty slot beside its own menu item is. A
                // submenu of per-host toggles has no single action for a chord
                // to fire, and ⇧⌘K meant "open the session dropdown" for the
                // whole life of that chord — giving it one release later to
                // something that moves the window to another machine turns a
                // habit into a teleport. It stays fallow.
                //
                // `Toggle` rather than `Button`, for the checkmark: it is the
                // only thing in the menu that says which machine you are on,
                // and macOS draws it for a toggle without being asked.
                Menu("Switch Host") {
                    ForEach(store.hosts) { host in
                        Toggle(
                            host.displayName,
                            isOn: Binding(
                                get: { store.currentHost == host.host },
                                set: { _ in store.switchHost(host.host) }))
                    }
                }
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
            // Tab switching sits in the Window menu, where Terminal.app puts
            // it and where a user looks for it. ⌘1–⌘9 are menu items rather
            // than a key monitor for one reason worth stating: a chord a menu
            // claims never reaches `keyDown`, so it cannot also be typed into
            // the terminal.
            CommandGroup(before: .windowList) {
                Button("Show Next Tab") { store.selectNextTab() }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                    .disabled(store.visibleTabs.count < 2)
                Button("Show Previous Tab") { store.selectPreviousTab() }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                    .disabled(store.visibleTabs.count < 2)
                Divider()
                ForEach(1...SessionStore.lastTabIndex, id: \.self) { index in
                    Button(index == SessionStore.lastTabIndex ? "Last Tab" : "Tab \(index)") {
                        store.selectTab(at: index)
                    }
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(index)")), modifiers: .command
                    )
                    .disabled(!store.canSelectTab(at: index))
                }
                Divider()
            }
        }
    }
}

struct ContentView: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Which of the three things the content area can be.
    ///
    /// The crossfade is keyed on *this* rather than on the selected tab, which
    /// is the whole point: going from one terminal to another is a tab switch
    /// and must be instant, while going from a terminal to "no terminals" is a
    /// different screen and should not snap. `screen` does not change on a tab
    /// switch, so `.animation(_:value:)` never fires for one.
    private enum Screen: Equatable {
        case terminals
        case unavailable
        case empty
    }

    /// Three cases, not four: `.unavailable` covers both "nothing is
    /// reachable" and "this machine is not", because the crossfade must not
    /// run between two screens that differ only in their sentence.
    private var screen: Screen {
        if store.selectedTab != nil { return .terminals }
        if store.connectionError != nil || store.currentHostError != nil { return .unavailable }
        return .empty
    }

    var body: some View {
        @Bindable var store = store
        // No hairline under the toolbar. The card's own border is directly
        // beneath it — its top edge is flush against the tab strip — so a
        // divider here would be a second line doing the first one's job, and
        // it would run the full width of the window rather than stopping at
        // the bezel the way the reference's does.
        VStack(spacing: 0) {
            // A tab wins over an error, and that order is load-bearing. A
            // server that goes away is reconnected to and the terminals on the
            // far side never stopped, so replacing the screen with "no server"
            // would blank a live window over a dropped packet — and tear down
            // every surface in it on the way, which is worse than it looks:
            // the pane comes back attached to a new view with a new grid. Each
            // pane says for itself that it is reconnecting.
            ZStack {
                if let tab = store.selectedTab {
                    // Each pane carries its own header. There is no divider
                    // under it: it sits on the terminal's own background, as in
                    // Superlogical.
                    SplitContainer(tab: tab)
                        .environment(store)
                        .id(tab.id)
                } else if let error = store.connectionError {
                    // Every machine is down, so Try Again means all of them.
                    ServerUnavailable(message: error) { store.connect() }
                        .transition(Motion.screen.transition(reduceMotion: reduceMotion))
                } else if let error = store.currentHostError {
                    // Only the machine you are on. Retrying every host here
                    // would dial machines the person is not looking at and
                    // restart handshakes that were going perfectly well.
                    ServerUnavailable(message: error) { store.reconnect(store.currentHost) }
                        .transition(Motion.screen.transition(reduceMotion: reduceMotion))
                } else {
                    EmptyState()
                        .transition(Motion.screen.transition(reduceMotion: reduceMotion))
                }
            }
            // No `.transition` on the tab branch, and none is wanted: a
            // terminal replaced by another terminal is `.id(tab.id)` swapping
            // one subtree for another, and a transition there would fade the
            // surface on every ⌘1/⌘2. The two placeholder screens carry the
            // crossfade instead, so it only ever runs between screens.
            .animation(Motion.screen.animation(reduceMotion: reduceMotion), value: screen)
        }
        // Clear when the terminal is translucent, because this sits behind
        // the panes and would be what shows through them — the desktop is the
        // point. Opaque otherwise, so a sliver uncovered mid-transition is the
        // chrome colour rather than the window's own. Not `Palette.background`
        // any more: with a bezel around it, every pixel this still reaches is
        // frame rather than terminal.
        .background(AppConfig.isTranslucent ? Color.clear : Palette.toolbar)
        .overlay {
            // The ZStack is unconditional so the *removal* transition has
            // something to run inside. With the `if` outside it, closing the
            // menu took the container with it and the menu just vanished.
            ZStack(alignment: .topLeading) {
                if store.sessionMenuOpen {
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
                        .transition(Motion.menu.transition(reduceMotion: reduceMotion))
                }
            }
            .animation(
                Motion.menu.animation(reduceMotion: reduceMotion), value: store.sessionMenuOpen)
        }
        // ⌃⇥ / ⌃⇧⇥, the one pair of tab chords the Window menu cannot also
        // carry: a menu item holds a single key equivalent, and those items
        // already spend theirs on ⇧⌘] and ⇧⌘[. TabCycleKey says why that
        // leaves a monitor, and why the terminal must never see the chord.
        .onTabCycle { direction in
            switch direction {
            case .next: store.selectNextTab()
            case .previous: store.selectPreviousTab()
            }
        }
        // The menu's filter field held the keyboard while it was open, and
        // nothing in the split tree changed when the overlay went away — so
        // without this, typing after Esc went nowhere. W15.
        .onChange(of: store.sessionMenuOpen) { _, isOpen in
            if !isOpen { store.focusTerminal() }
        }
        // One dialog for every destructive action, driven off the store so the
        // wording and the policy are tested in one place. `presenting:` hands
        // the value back to the buttons rather than making them read the slot
        // that dismissal is about to clear.
        .confirmationDialog(
            store.pendingDestruction?.title ?? "",
            isPresented: Binding(
                get: { store.pendingDestruction != nil },
                set: { if !$0 { store.cancelPendingDestruction() } }),
            titleVisibility: .visible,
            presenting: store.pendingDestruction
        ) { pending in
            Button(pending.confirmTitle, role: .destructive) {
                store.confirmPendingDestruction(pending)
            }
            Button("Cancel", role: .cancel) { store.cancelPendingDestruction() }
        } message: { pending in
            Text(pending.message)
        }
        .frame(minWidth: 720, minHeight: 460)
        // Dark, unless the theme is light. This was `.dark` outright, from
        // when the app had one set of colours and they were dark ones -- and
        // it outranks the `NSAppearance` `WindowChrome` sets, so leaving it
        // alone made `window-theme` do nothing at all. What it decides is
        // every control we do not draw: the alert above, the buttons on the
        // two placeholder screens, a sheet.
        .preferredColorScheme(AppConfig.windowColorScheme)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The active pill is one view that moves between slots rather than one
    /// per slot appearing and disappearing, so selecting a tab slides it.
    @Namespace private var pill

    /// The tab being dragged along the strip, and how far it has come.
    ///
    /// Not `.draggable`/`.dropDestination`. Those are system drag and drop, and
    /// on this strip most of a 197 pt slot is the select `Button`'s hit area —
    /// a control that takes the mouse-down, which is the documented way for a
    /// `.draggable` on macOS to never start. A reorder that silently does
    /// nothing is worse than no reorder, so this is the `DragGesture` slot-swap
    /// the plan named as the fallback (risk R5), attached with
    /// `simultaneousGesture` so it runs *beside* the button rather than
    /// competing with it. It also drops the two bugs the system path came with:
    /// a text selection dragged in from another app no longer lights the strip
    /// up, and a refused move no longer plays the accept animation.
    private struct TabDrag: Equatable {
        var id: TabLayout.ID
        var translation: CGFloat
    }
    @State private var drag: TabDrag?

    /// Far enough that a click with a shaky hand is still a click.
    private static let dragThreshold: CGFloat = 8

    private func isActive(_ index: Int) -> Bool {
        let tabs = store.visibleTabs
        guard tabs.indices.contains(index) else { return false }
        return tabs[index].id == store.selectedTabID
    }

    /// The slot the drag currently points at, if there is one.
    private var dragTarget: Int? {
        guard let drag,
            let from = store.visibleTabs.firstIndex(where: { $0.id == drag.id })
        else { return nil }
        let to = TabStrip.dropIndex(
            from: from, translation: drag.translation, slotWidth: Metrics.tabWidth,
            count: store.visibleTabs.count)
        return to == from ? nil : to
    }

    private func drop(_ id: TabLayout.ID, translation: CGFloat) {
        let tabs = store.visibleTabs
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let to = TabStrip.dropIndex(
            from: from, translation: translation, slotWidth: Metrics.tabWidth,
            count: tabs.count)
        guard to != from else { return }
        Motion.tabs.run { store.moveTab(id, onto: tabs[to].id) }
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
                            isDropTarget: dragTarget == index,
                            isDragging: drag?.id == tab.id,
                            pill: pill,
                            select: { store.selectedTabID = tab.id },
                            // Through the same policy ⇧⌘W uses, so pointer and
                            // keyboard cannot disagree about when closing a tab
                            // asks first — or about the window's last tab
                            // taking the window with it rather than emptying
                            // it.
                            close: { WindowClose.tab(tab.id, in: store) }
                        )
                        // The dragged slot follows the pointer and rides over
                        // its neighbours; everything else stays put until the
                        // drop, when the strip's own animation closes the gap.
                        .offset(x: drag?.id == tab.id ? drag?.translation ?? 0 : 0)
                        .zIndex(drag?.id == tab.id ? 1 : 0)
                        // Drag to reorder — issue #38. Order is client state
                        // and never leaves the window. `simultaneousGesture`
                        // rather than `gesture`: the slot is mostly taken up by
                        // the select button, and a plain gesture would have to
                        // win against it rather than run alongside it.
                        .simultaneousGesture(
                            // `.global`, not the slot's own space. The slot is
                            // offset by the very translation this reports, so
                            // measuring in local coordinates would feed the
                            // offset back into the next event and the tab would
                            // either run away from the pointer or stick to it.
                            DragGesture(
                                minimumDistance: Self.dragThreshold, coordinateSpace: .global
                            )
                            .onChanged { value in
                                drag = TabDrag(id: tab.id, translation: value.translation.width)
                            }
                            .onEnded { value in
                                drag = nil
                                drop(tab.id, translation: value.translation.width)
                            }
                        )
                        // Outermost, so what fades is the whole slot rather
                        // than the content inside a wrapper that stays.
                        .transition(Motion.tabs.transition(reduceMotion: reduceMotion))
                    }
                }
            }
            // Cap the strip at its content width so the leftover toolbar is
            // genuinely empty and can drag the window. When the tabs outgrow
            // the window this clamps to the available width and scrolls.
            .frame(maxWidth: CGFloat(store.visibleTabs.count) * Metrics.tabWidth)
            // One animation for the whole strip: slots arriving and leaving,
            // the width cap moving with them, and the active pill sliding to
            // its new slot. Keyed on the ids rather than the tabs themselves,
            // so a tab whose *label* changed — every `cd`, on every list —
            // does not re-run the strip's animation.
            .animation(
                Motion.tabs.animation(reduceMotion: reduceMotion),
                value: store.visibleTabs.map(\.id)
            )
            .animation(
                Motion.tabs.animation(reduceMotion: reduceMotion), value: store.selectedTabID)

            // Bare title bar drags the window; AppKit handles it because the
            // toolbar is a title bar accessory. This `Spacer` is deliberately
            // the *only* part of the strip that still does -- every control
            // around it calls `claimsMouseDown()`.
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
            // Without this a drag begun on `+` moved the window and made a
            // terminal when it ended, which is two surprises for one gesture.
            .claimsMouseDown()
            .help("New Terminal (⌘T)")
            .padding(.trailing, Metrics.plusTrailing)
        }
        .frame(height: Metrics.toolbarHeight)
        .background(Palette.toolbar)
    }
}

/// The two screens that stand in for a terminal, and the reason both are
/// `Palette.toolbar` rather than `Palette.background`.
///
/// There is no terminal on either of them, so there is no terminal colour to
/// use: what fills the window here is the same frame that surrounds a pane
/// when there is one. It matters more than it sounds, because the content view
/// runs *under* the title bar -- `titlebarAppearsTransparent`, so that the tab
/// strip can be an accessory -- and whatever this paints is therefore also the
/// strip behind the traffic lights. Painted in the terminal's colour, a
/// window with no terminals in it had a band of Gruvbox cream across a
/// window that was otherwise chrome. Invisible before there were themes,
/// when the two colours were four units apart.
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
        .background(Palette.toolbar)
    }
}

struct ServerUnavailable: View {
    let message: String
    /// What Try Again asks for, which is not the same question on both screens
    /// this draws: every host when nothing at all is reachable, and one host
    /// when the window is parked on a machine that is not. Handed in rather
    /// than decided here — the caller is the one that knows which screen this
    /// is, and a view cannot be asked.
    let retry: () -> Void

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
            Button("Try Again", action: retry)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.toolbar)
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
