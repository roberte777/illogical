//  SessionMenu.swift
//  The session dropdown, matched to Superlogical's.
//
//      ┌────────────────────────────────┐
//      │ ⊜  Filter or create...         │  capsule field, 22pt
//      │                                │
//      │ ✓   Demo                       │  22pt row, ✓ in the icon column
//      │ ─────────────────────────────  │
//      │ ⊞   New Session          ⇧⌘N   │
//      │ ─────────────────────────────  │
//      │ ⊕   Add Remote Host...         │  hover: blue capsule, dark text
//      └────────────────────────────────┘
//
//  With more than one machine connected it grows a header per host, and the
//  sessions under it are that machine's:
//
//      ┌────────────────────────────────┐
//      │ ⊜  Filter or create...         │
//      │ LOCAL                          │  host header, 10pt, dim
//      │ ✓   Demo                       │
//      │ BUILD-BOX                  ✕   │  remote: removable
//      │     api                        │
//      │     agent                      │
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
    /// The same height as a row, rather than the 17pt the reference measured.
    /// At 17 a 13pt field had two points of air above and below the text and
    /// read as squished; matching `rowHeight` gives the field and the rows
    /// under it one vertical rhythm.
    static let fieldHeight: CGFloat = rowHeight
    static let fieldToRows: CGFloat = 8
    static let separatorInset: CGFloat = 7
    static let separatorPadding: CGFloat = 6
    static let font: CGFloat = 13
    /// A host header. Smaller than a row, because it is a label rather than
    /// something you click.
    static let headerHeight: CGFloat = 18
    static let headerFont: CGFloat = 10

    /// How much room a row's title actually has: the panel, less its padding,
    /// less the row's own, less the icon column and the gap after it.
    ///
    /// Derived rather than written down as 128, so that a test can hold
    /// `SessionNameRefusal`'s sentences against the geometry they are drawn
    /// in. Two of them did not fit and were truncated with an ellipsis, and
    /// the one people actually hit — by typing a space — lost the half that
    /// carried the meaning.
    static let titleWidth: CGFloat =
        width - 2 * padding - 2 * rowPadding - iconColumn - iconToTitle
}

/// The menu's own colours, on the same three relationships the rest of the
/// chrome uses — see `Palette`. The panel is lit from the top and the field
/// inside it is cut in, so the gradient runs from a tint down through the
/// background to a shade, and the field is a shade further still.
extension Palette {
    static var menuTop: Color { tint(0.08) }
    static var menuBottom: Color { shade(0.06) }
    static var menuStroke: Color { color(source.foreground).opacity(0.09) }
    static var menuField: Color { shade(0.12) }
    static var menuSeparator: Color { tint(0.04) }
    /// The theme's own blue. A selected row is the one place in the window
    /// with a colour rather than a shade, and taking it from the palette is
    /// what stops a Rosé Pine menu having a stock macOS blue in the middle
    /// of it.
    static var menuHighlight: Color { color(source.blue) }
    /// On that blue, whichever of the terminal's two colours can be read
    /// against it — which is the background on nearly every theme, and the
    /// foreground on the ones whose blue is dark.
    static var menuHighlightText: Color { readable(on: source.blue) }
    static var menuText: Color { text(0.0) }
    static var menuShortcut: Color { text(0.37) }
}

struct SessionMenu: View {
    @Environment(SessionStore.self) private var store
    @Binding var isPresented: Bool

    @State private var filter = ""
    @State private var hovered: String?
    @FocusState private var fieldFocused: Bool
    @State private var addingHost = false
    @State private var newHost = ""

    /// The session whose row is currently a text field, and what is in it.
    /// Set by the row's own context menu, or by File ▸ Rename Session… leaving
    /// a `pendingRename` on the store for `onAppear` below to pick up.
    @State private var renaming: SessionRef?
    @State private var renameText = ""

    /// Sessions on one host that survive the filter.
    ///
    /// Normalized, so that ` wo` finds `work`: the ends of what is typed are
    /// never part of what is meant, and the create path already reads it that
    /// way.
    private func matches(_ host: HostConnection) -> [SessionSummary] {
        let typed = SessionName.normalized(filter)
        guard !typed.isEmpty else { return host.sessions }
        return host.sessions.filter { $0.name.localizedCaseInsensitiveContains(typed) }
    }

    /// "Filter **or create**", and why not when not. The decision belongs to
    /// the store: it is one rule with two visible consequences, and a view
    /// cannot be asked about either.
    private var offer: FilterOffer { store.filterOffer(filter) }

    /// Whether to name the machine each session is on. One host is the common
    /// case and a header over every row would be noise.
    private var showsHosts: Bool { store.hosts.count > 1 }

    private var anyMatches: Bool { store.hosts.contains { !matches($0).isEmpty } }

    var body: some View {
        VStack(spacing: 0) {
            filterField
                .padding(.bottom, MenuMetrics.fieldToRows)

            // The separator after this block divides it from the session rows,
            // so it is drawn only when there are session rows. Typing a name
            // that matches nothing is the ordinary way to reach it, and
            // without the guard the panel drew that separator and the one
            // above "New Session" as a pair of hairlines 13pt apart with
            // nothing at all between them.
            switch offer {
            case .create(let name):
                MenuRow(
                    icon: "plus", title: "Create “\(name)”", shortcut: "↩",
                    isHovered: hovered == "__create",
                    hover: { hovered = $0 ? "__create" : nil },
                    action: create)
                if anyMatches { MenuSeparator() }
            case .refused(let refusal):
                MenuNotice(text: refusal.message)
                if anyMatches { MenuSeparator() }
            case .nothing:
                EmptyView()
            }

            ForEach(store.hosts) { host in
                // Hidden only when a *filter* is excluding this machine's
                // sessions, never merely because it has none.
                //
                // The header is the only place `removeHost` and `reconnect`
                // are reachable from, and a host with no sessions is precisely
                // the one that needs them: a host that failed to connect has
                // an empty list, so gating on emptiness made an unreachable
                // `build-box` disappear from the dropdown while staying in
                // `UserDefaults` — back on every launch and impossible to
                // forget — and left a restarted local daemon with no retry.
                if showsHosts
                    && (SessionName.normalized(filter).isEmpty || !matches(host).isEmpty)
                {
                    HostHeader(
                        host: host,
                        isHovered: hovered == "h\(host.id)",
                        hover: { hovered = $0 ? "h\(host.id)" : nil },
                        remove: { store.removeHost(host.host) },
                        retry: { store.reconnect(host.host) })
                }
                ForEach(matches(host)) { session in
                    let ref = SessionRef(host: host.host, session: session.id)
                    if renaming == ref {
                        SessionRenameRow(
                            text: $renameText,
                            refusal: store.renameRefusal(ref, to: renameText),
                            commit: { commitRename(ref) },
                            cancel: cancelRename)
                    } else {
                        MenuRow(
                            icon: isSelected(session, on: host) ? "checkmark" : nil,
                            title: session.name,
                            isHovered: hovered == rowID(session, on: host),
                            hover: { hovered = $0 ? rowID(session, on: host) : nil },
                            action: { select(session, on: host) }
                        )
                        // Right-click, rather than a hover affordance: the
                        // row is 22pt with an icon column already spoken
                        // for, and both of these are rare next to
                        // "switch to it", which is what the row is for.
                        .contextMenu {
                            Button("Rename") { beginRename(ref, from: session.name) }
                            Divider()
                            Button("Delete…", role: .destructive) {
                                store.requestDeleteSession(ref)
                                // The dialog belongs to the window, and
                                // this menu is an overlay on top of it.
                                // Leaving it up would put a panel between
                                // the person and the question.
                                isPresented = false
                            }
                            // Greyed rather than absent while the machine is
                            // being reconnected to: the row still lists a
                            // session, because the machine is still running
                            // it, but nothing can be sent — and a dialog
                            // saying "this cannot be undone" for something
                            // that cannot happen is worse than no menu item.
                            .disabled(!store.canDeleteSession(ref))
                        }
                    }
                }
            }

            if !anyMatches && offer == .nothing {
                Text(SessionName.normalized(filter).isEmpty ? "No sessions" : "No matches")
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
                action: { addingHost = true })
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
        // File ▸ Rename Session… has no field to reach: `SessionMenu` only
        // exists while the dropdown is open. It leaves the session on the
        // store instead, and these are the two ways this view finds out —
        // `onAppear` when the menu bar had to open the menu first, `onChange`
        // when it was already open, which `sessionMenuOpen = true` cannot
        // reopen and which used to strand the flag until some later, unrelated
        // opening picked it up and put the wrong row into a text field.
        .onAppear { adoptPendingRename(orFocusFilter: true) }
        .onChange(of: store.pendingRename) { _, _ in
            adoptPendingRename(orFocusFilter: false)
        }
        // Nothing outlives the menu. A flag left set here is a rename armed
        // against a session the person has since stopped looking at.
        .onDisappear { store.pendingRename = nil }
        // Escape closes the menu, the way it closes an NSMenu. Not
        // `.onExitCommand`, which was W10's bug: that fires only for the
        // *focused* view, and the focus the line above asks for does not
        // reliably land -- with the menu open the app's focused element was
        // still the terminal surface underneath, so Escape went to the
        // terminal and the menu stayed. `onEscape` watches the event rather
        // than the focus, so it works wherever first responder happens to
        // be. Closing hands the
        // keyboard back to the terminal (SessionStore.focusTerminal).
        .onEscape { isPresented = false }
        .sheet(isPresented: $addingHost) {
            AddRemoteHost(destination: $newHost) { destination in
                store.addHost(.ssh(destination: destination))
                isPresented = false
            }
        }
    }

    private func rowID(_ session: SessionSummary, on host: HostConnection) -> String {
        "s\(host.id)-\(session.id)"
    }

    private func isSelected(_ session: SessionSummary, on host: HostConnection) -> Bool {
        store.selectedSession == SessionRef(host: host.host, session: session.id)
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
                    if case .create = offer {
                        create()
                    } else if let host = store.hosts.first(where: { !matches($0).isEmpty }),
                        let first = matches(host).first
                    {
                        select(first, on: host)
                    }
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

    private func select(_ session: SessionSummary, on host: HostConnection) {
        let ref = SessionRef(host: host.host, session: session.id)
        if let first = store.tabs.first(where: { $0.session == ref }) {
            store.selectedTabID = first.id
        } else {
            // A session with no tabs is one whose terminals have all gone.
            // Making one is what "switch to it" means.
            store.createTerminal(sessionName: session.name, on: host.host)
        }
        isPresented = false
    }

    /// Takes the name out of the offer rather than off the field, so that the
    /// row shown and the name sent cannot be two different strings — the offer
    /// is what already normalized it.
    private func create() {
        guard case .create(let name) = offer else { return }
        store.createTerminal(sessionName: name)
        isPresented = false
    }

    /// "session-N" is digits and a dash, so it is always a name the server
    /// accepts; no gate is needed here beyond the one in the store.
    private func newSession() {
        let count = store.selectedHost?.sessions.count ?? 0
        store.createTerminal(sessionName: "session-\(count + 1)")
        isPresented = false
    }

    // MARK: - Renaming in place

    private func beginRename(_ ref: SessionRef, from name: String) {
        renameText = name
        renaming = ref
    }

    /// Whatever the store left for the dropdown to pick up, or the filter
    /// field taking focus when there is nothing to pick up.
    ///
    /// `orFocusFilter` is false for the `onChange` arm: the menu is already
    /// open there, and stealing focus back to the filter every time the flag
    /// happened to clear would fight whatever the person is typing in.
    private func adoptPendingRename(orFocusFilter: Bool) {
        guard let ref = store.pendingRename else {
            if orFocusFilter { fieldFocused = true }
            return
        }
        store.pendingRename = nil
        beginRename(ref, from: store.session(ref)?.name ?? "")
    }

    /// Enter. A name the server would refuse — or that was never sent, because
    /// the machine is mid-reconnect — leaves the field open with the text
    /// still in it, rather than closing on a rename that will not happen.
    /// There is no room in a 22pt row for a sentence, so the field going amber
    /// and staying put is the whole of the feedback.
    ///
    /// The rule is the store's, and only the store's. This used to keep half
    /// of it: it validated the raw text and committed a trimmed one, so
    /// `work ` painted amber, showed the tooltip and then renamed anyway.
    private func commitRename(_ ref: SessionRef) {
        guard store.renameSession(ref, to: renameText) else { return }
        renaming = nil
        // Back to the field the menu opened on, so the next keystroke filters
        // rather than falling on nothing.
        fieldFocused = true
    }

    private func cancelRename() {
        renaming = nil
        fieldFocused = true
    }
}

/// A session row turned into a text field for the length of a rename.
///
/// Its own view so the field owns its focus. A `@FocusState` shared with the
/// filter field would have the two fighting over it: the filter takes focus
/// when the menu appears, and the rename would have to take it back on a later
/// pass.
struct SessionRenameRow: View {
    @Binding var text: String
    /// Handed in rather than worked out here, and by the same call that Enter
    /// goes through (`SessionStore.renameRefusal`). This view used to decide
    /// for itself, on the untrimmed text and with no idea which names were
    /// taken, so the colour and the commit disagreed in both directions.
    let refusal: SessionNameRefusal?
    let commit: () -> Void
    let cancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "pencil")
                .font(.system(size: 11))
                .frame(width: MenuMetrics.iconColumn, alignment: .center)

            Spacer().frame(width: MenuMetrics.iconToTitle)

            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: MenuMetrics.font))
                .focused($focused)
                .onSubmit(commit)
        }
        .foregroundStyle(refusal == nil ? Palette.menuText : Color.orange)
        .padding(.horizontal, MenuMetrics.rowPadding)
        .frame(height: MenuMetrics.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: MenuMetrics.rowCornerRadius, style: .continuous)
                .fill(Palette.menuField)
                .overlay(
                    RoundedRectangle(
                        cornerRadius: MenuMetrics.rowCornerRadius, style: .continuous
                    )
                    .strokeBorder(
                        refusal == nil ? Color.white.opacity(0.06) : Color.orange,
                        lineWidth: 1))
        }
        .onAppear { focused = true }
        // Escape. The field is the first responder, so `cancelOperation:`
        // arrives here rather than at the menu — which is why the menu's own
        // dismissal cannot double as this.
        .onExitCommand(perform: cancel)
        .help(refusal?.message ?? "")
    }
}

/// A row that says something rather than doing something. Not a `MenuRow`:
/// there is nothing to hover and nothing to click.
struct MenuNotice: View {
    let text: String

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 11))
                .frame(width: MenuMetrics.iconColumn, alignment: .center)

            Spacer().frame(width: MenuMetrics.iconToTitle)

            Text(text)
                .font(.system(size: MenuMetrics.font))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .foregroundStyle(Palette.menuShortcut)
        .padding(.horizontal, MenuMetrics.rowPadding)
        .frame(height: MenuMetrics.rowHeight)
    }
}

/// A machine's name over its sessions, with what it is doing.
struct HostHeader: View {
    let host: HostConnection
    let isHovered: Bool
    let hover: (Bool) -> Void
    let remove: () -> Void
    let retry: () -> Void

    private var status: (icon: String, color: Color, help: String)? {
        switch host.status {
        case .connecting: ("arrow.clockwise", Palette.menuShortcut, "Connecting…")
        case .connected: nil
        // Amber rather than red: nothing has been given up on, and a machine
        // asleep behind a network that will come back is the ordinary case.
        case .reconnecting(let attempt, let detail):
            (
                "arrow.triangle.2.circlepath", .orange,
                // `ssh`'s own complaint where there is one, and otherwise the
                // wording `Status` uses, so this tooltip and the "no server"
                // screen cannot drift apart.
                detail ?? HostConnection.Status.reconnectingMessage(attempt: attempt)
            )
        case .failed(let message): ("exclamationmark.triangle.fill", .red, message)
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(host.displayName.uppercased())
                .font(.system(size: MenuMetrics.headerFont, weight: .semibold))
                .foregroundStyle(Palette.menuShortcut)
                .lineLimit(1)

            if let status {
                Button(action: retry) {
                    Image(systemName: status.icon)
                        .font(.system(size: 9))
                        .foregroundStyle(status.color)
                }
                .buttonStyle(.plain)
                // The whole reason a failure is a marker rather than a modal:
                // one unreachable machine must not stop the window working.
                .help(status.help)
            }

            // The server answering this socket is not the one the app shipped.
            // Deliberately *not* a button and not an action: whatever is
            // running owns the terminals behind it, restarting it would end
            // every one of them (there is no descriptor handoff yet), and a
            // daemon from another checkout usually works perfectly well. This
            // says so and gets out of the way. A snapshot that genuinely does
            // not match fails loudly at `snapshot_begin` on its own.
            if let skew = host.versionSkew {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    // Says nothing about *why* the two differ. An app update is
                    // one way to get here and the least likely one today: the
                    // bundle carries a Debug host-arch daemon from `just build`
                    // while a released one is ReleaseFast and universal, so a
                    // developer -- or anyone who installed the tarball and
                    // started it by hand -- sees this against an app built from
                    // the identical commit (REVIEW F16).
                    .help(
                        "The server answering this socket is \(skew.server); this app ships "
                            + "\(skew.shipped). Whatever started it owns its terminals, and they "
                            + "are still here.")
            }

            Spacer(minLength: 4)

            // Only what the user added can be removed; the local daemon is not
            // a host they chose, and removing it would leave nowhere to make a
            // terminal.
            //
            // Not hover-gated. `Chrome.swift` records the lesson for the tab
            // close button in as many words -- "hover-only made it
            // undiscoverable" -- and the diagram at the top of this file draws
            // it unconditionally.
            if host.host.isRemote {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Palette.menuShortcut)
                }
                .buttonStyle(.plain)
                .help("Forget \(host.displayName)")
            }
        }
        .padding(.horizontal, MenuMetrics.rowPadding)
        .frame(height: MenuMetrics.headerHeight)
        .contentShape(Rectangle())
        .onHover(perform: hover)
    }
}

/// Ask for an SSH destination. There is nothing else to ask for: no key, no
/// port, no password. `ssh` reads the user's own config, so a `Host` alias out
/// of it is a perfectly good answer.
struct AddRemoteHost: View {
    @Binding var destination: String
    let add: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private var trimmed: String {
        destination.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Remote Host")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.textBright)

            TextField("user@host, or a Host from ~/.ssh/config", text: $destination)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(commit)

            Text(
                "Runs `ssh <host> illogicald --stdio`. Your SSH config, keys, "
                    + "jump hosts and agent forwarding apply — nothing is stored here "
                    + "but the name."
            )
            .font(.system(size: 11))
            .foregroundStyle(Palette.textDim)
            .frame(width: 320, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        // The panel colour, not the terminal's: this is a sheet over the
        // window, and the only thing in the app that is the terminal's colour
        // is a terminal.
        .background(Palette.menuBottom)
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        add(trimmed)
        destination = ""
        dismiss()
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
