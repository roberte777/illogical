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
    static let fieldHeight: CGFloat = 17
    static let fieldToRows: CGFloat = 8
    static let separatorInset: CGFloat = 7
    static let separatorPadding: CGFloat = 6
    static let font: CGFloat = 13
    /// A host header. Smaller than a row, because it is a label rather than
    /// something you click.
    static let headerHeight: CGFloat = 18
    static let headerFont: CGFloat = 10
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
    @State private var addingHost = false
    @State private var newHost = ""

    /// Sessions on one host that survive the filter.
    private func matches(_ host: HostConnection) -> [SessionSummary] {
        guard !filter.isEmpty else { return host.sessions }
        return host.sessions.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    /// "Filter **or create**": a name that matches nothing can be made. On the
    /// machine in front, since that is where a new terminal would go.
    ///
    /// Checked against *every* host's sessions, not just that one. The rows
    /// below list them all, so a name that matches a session on another machine
    /// is one you can switch to — offering "Create" for it as well meant Enter
    /// silently made a second, local session with the same name instead of
    /// going where the visible row pointed.
    private var canCreate: Bool {
        guard !filter.isEmpty, store.selectedHost != nil else { return false }
        return !store.hosts.contains { host in
            host.sessions.contains { $0.name.caseInsensitiveCompare(filter) == .orderedSame }
        }
    }

    /// Whether to name the machine each session is on. One host is the common
    /// case and a header over every row would be noise.
    private var showsHosts: Bool { store.hosts.count > 1 }

    private var anyMatches: Bool { store.hosts.contains { !matches($0).isEmpty } }

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
                if showsHosts && (filter.isEmpty || !matches(host).isEmpty) {
                    HostHeader(
                        host: host,
                        isHovered: hovered == "h\(host.id)",
                        hover: { hovered = $0 ? "h\(host.id)" : nil },
                        remove: { store.removeHost(host.host) },
                        retry: { store.reconnect(host.host) })
                }
                ForEach(matches(host)) { session in
                    MenuRow(
                        icon: isSelected(session, on: host) ? "checkmark" : nil,
                        title: session.name,
                        isHovered: hovered == rowID(session, on: host),
                        hover: { hovered = $0 ? rowID(session, on: host) : nil },
                        action: { select(session, on: host) })
                }
            }

            if !anyMatches && !canCreate {
                Text(filter.isEmpty ? "No sessions" : "No matches")
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
        .onAppear { fieldFocused = true }
        // Escape closes the menu, the way it closes an NSMenu. It has to be
        // here rather than on the overlay: key events go where focus is, and
        // the filter field takes it as the menu appears. Closing hands the
        // keyboard back to the terminal (SessionStore.focusTerminal).
        .onExitCommand { isPresented = false }
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
                    if canCreate {
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

    private func create() {
        store.createTerminal(sessionName: filter)
        isPresented = false
    }

    private func newSession() {
        let count = store.selectedHost?.sessions.count ?? 0
        store.createTerminal(sessionName: "session-\(count + 1)")
        isPresented = false
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
        .background(Palette.background)
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
