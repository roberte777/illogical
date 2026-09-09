//  Chrome.swift
//  The window chrome, matched to the Superlogical Mac app.
//
//  Every value below was measured off Mitchell's pre-alpha demo recording at
//  2160p, where the traffic lights give a known scale: 25 frame pixels for a
//  12pt light, so 2.083 px/pt. Colours are sampled pixels, not guesses.
//
//      ┌──────────────────────────────────────────────────────────────┐
//      │ ● ● ●  ▤ Demo │ ▣ ~> btop │ ▣ ~> htop │(▣ ~/…> nvim)      +  │ 39pt
//      ├──────────────────────────────────────────────────────────────┤ 1px
//      │ ▢ ~/Documents/ghostty> nvim                                  │ 27pt
//      │                                                              │
//      │  terminal                                                    │
//
//  Notes that are easy to get wrong:
//    * The session glyph is a layered stack, not a house.
//    * Tab glyphs are Terminal.app-style badges: dark rounded square, green
//      prompt. The breadcrumb uses the outlined variant instead.
//    * In a tab label the *path* is dim and the *command* is bright. The
//      breadcrumb renders both dim.
//    * There is a divider under the toolbar but none under the breadcrumb.

import IllogicalProtocol
import SwiftUI

/// Reports a view's position in window coordinates when tracing is on, so the
/// layout can be checked against the measured reference.
extension View {
    func traceFrame(_ label: String) -> some View {
        background {
            if Trace.isEnabled {
                GeometryReader { geo in
                    Color.clear.onAppear {
                        let f = geo.frame(in: .global)
                        Trace.log(
                            "layout \(label) x=\(String(format: "%.1f", f.minX))..\(String(format: "%.1f", f.maxX)) w=\(String(format: "%.1f", f.width))"
                        )
                    }
                }
            }
        }
    }
}

/// Measured from the reference recording, in points from the window's left edge.
///
///     traffic lights   15.0 → 69.6
///     session icon     90.7 → 103.2
///     "Demo"          114.2 → 145.9
///     tab 1 slot      162.3 → 359.5   (badge 172.3 → 193.4, label from 203.0)
///     tab 2 slot      359.6 → 556.9
///     tab 3 slot      557.3 → 753.1   (the active pill fills its slot)
///     "+" glyph      1023.4 → 1033.0
///     window edge            1054.6
///
/// So: tab slots are a fixed ~197pt, laid out edge to edge, with a 1pt hairline
/// drawn on the boundary between two inactive tabs.
enum Metrics {
    static let toolbarHeight: CGFloat = 39
    static let breadcrumbHeight: CGFloat = 27
    static let tabHeight: CGFloat = 27
    static let tabCornerRadius: CGFloat = 13
    /// One tab's slot. Content is left-aligned in it and truncates.
    static let tabWidth: CGFloat = 197
    static let tabLeadingPadding: CGFloat = 10
    /// Where the session menu is anchored, in *window* coordinates: the
    /// session button's leading edge, measured at 80pt in the reference.
    static let contentInset: CGFloat = 81
    /// Leading padding inside the title bar accessory. This is a different
    /// coordinate space from `contentInset`: AppKit already offsets the
    /// accessory past the traffic lights, so this only adds the remainder
    /// needed to land the session icon at 90.7pt in the window.
    static let toolbarLeading: CGFloat = 3
    static let sessionPadding: CGFloat = 8
    /// Gap between the session button and the first tab slot.
    static let sessionToTabs: CGFloat = 6
    /// 12pt, not 13: "Demo" measures 31.7pt of ink in the reference and "btop"
    /// 24.0pt, which is SF Pro at 12.
    static let labelSize: CGFloat = 12
    static let badgeSize: CGFloat = 20
    static let badgeToLabel: CGFloat = 10
    static let iconToTitle: CGFloat = 8
    /// The per-terminal header's controls: split right, split down, zoom,
    /// close. Sized to sit inside the 27pt breadcrumb without crowding it.
    static let paneButtonSize: CGFloat = 20
    static let paneButtonSpacing: CGFloat = 2
    static let paneButtonTrailing: CGFloat = 8
    static let plusTrailing: CGFloat = 12
    static let plusWidth: CGFloat = 28
    /// Inside the card, so the glyph lands ~24pt from the window's edge once
    /// the bezel is added — where it sat before there was one, and where the
    /// reference puts it (23pt of ink).
    static let breadcrumbLeading: CGFloat = 18

    /// The bezel: how far a pane is held off the window's edges, with the
    /// chrome colour showing in the gap.
    ///
    /// Measured off a *light-mode* capture of the reference, where the chrome
    /// and the card are far enough apart in tone to find an edge at all: 8px
    /// of chrome either side of the card and 8px below it, on a window whose
    /// traffic lights are 16px across — so a 4:3 capture, and 6pt. It is what
    /// makes a pane read as a card the window holds rather than as the
    /// window's own lining, and it is the one piece of the chrome that is a
    /// *colour* difference rather than a layout one: the gap is
    /// `Palette.toolbar`, which is darker than `Palette.background`.
    ///
    /// A pane, and not a terminal: the breadcrumb is inside the card, because
    /// the cwd, the command and the split controls on it all belong to the
    /// terminal below rather than to the window around it.
    ///
    /// **Three sides, not four.** In the reference the card's top edge is
    /// flush against the toolbar — the toolbar ends at 52px and the card's
    /// border is the next pixel down — so the card's own edge is what
    /// separates the two. There is no gap above the card and no hairline
    /// under the tab strip; a bezel *and* a divider would be two separators
    /// doing one job.
    ///
    /// Not the same thing as `RendererConfig.windowPadding`, which is slack
    /// *inside* the surface painted in the terminal's own background. That
    /// one keeps a glyph off the edge; this one frames the terminal.
    static let terminalInset: CGFloat = 6
    /// The card's corners.
    ///
    /// Fitted rather than guessed, but against a *ratio* rather than a
    /// number. In the reference the card's curve leaves the straight edge
    /// 13px from the corner and the window's own leaves it at 18px, so the
    /// card is roughly 0.72 of the window it sits in — and it is the window
    /// that this has to stay clear of. A corner tighter than that reads as
    /// crowding the window's border along the bottom, because the two curves
    /// stop running parallel and the gap closes at the diagonal.
    ///
    /// The window's radius cannot be read back: the window server owns that
    /// rounding and every layer in the hierarchy reports 0, so this is the
    /// ratio applied to what macOS 26 draws rather than a measurement of it.
    /// Each point here buys about 0.3pt of clearance at the diagonal, so the
    /// step from 10 was deliberately small — it is one line if it wants to be
    /// rounder still.
    static let terminalCornerRadius: CGFloat = 12
    /// The card's edge. The reference draws one on all four sides, a single
    /// pixel a little darker than both the chrome outside it and the terminal
    /// within — and with the top edge flush against the toolbar, this is the
    /// line that divides them.
    static let terminalBorderWidth: CGFloat = 1
}

// MARK: - Shared pieces

/// The Terminal.app-style badge: dark rounded square, green prompt.
struct TerminalBadge: View {
    var size: CGFloat = Metrics.badgeSize

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Palette.badgeFill)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(Palette.badgeStroke, lineWidth: 1)
            )
            .overlay(
                Image(systemName: "chevron.right")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(Palette.badgeGlyph)
                    .offset(x: -size * 0.06, y: -size * 0.08)
            )
            .overlay(
                Rectangle()
                    .fill(Palette.badgeGlyph)
                    .frame(width: size * 0.30, height: max(1, size * 0.085))
                    .offset(x: size * 0.16, y: size * 0.22)
            )
            .frame(width: size, height: size)
    }
}

/// A terminal's label: dim path, bright command.
struct TerminalLabel: View {
    let terminal: TerminalSummary
    var bright: Color = Palette.textBright
    var dim: Color = Palette.textDim

    var body: some View {
        (Text(path + "> ").foregroundColor(dim)
            + Text(command).foregroundColor(bright))
            .font(.system(size: Metrics.labelSize))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var path: String {
        guard !terminal.cwd.isEmpty else { return terminal.name }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return terminal.cwd.hasPrefix(home)
            ? "~" + terminal.cwd.dropFirst(home.count) : terminal.cwd
    }

    private var command: String {
        (terminal.command as NSString).lastPathComponent
    }
}

// MARK: - Session button

struct SessionButton: View {
    @Environment(SessionStore.self) private var store
    @Binding var isPresented: Bool

    /// The machine the window is on, when it is not this one. A window can be
    /// looking at several at once, so which one is not a detail.
    ///
    /// Read off `currentHost` rather than off the front session, so that a
    /// machine with nothing on it still says whose empty screen you are
    /// looking at: "build-box no session".
    private var remote: String? {
        guard store.currentHost.isRemote else { return nil }
        return store.currentHost.displayName
    }

    private var name: String { store.selectedSessionSummary?.name ?? "no session" }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: Metrics.iconToTitle) {
                Image(systemName: remote == nil ? "rectangle.stack" : "globe")
                    .font(.system(size: 13, weight: .regular))
                    .traceFrame("session-icon")
                // The host is dim and the session bright, the same way a tab
                // label dims the path and brightens the command.
                (Text(remote.map { $0 + " " } ?? "").foregroundColor(Palette.textDim)
                    + Text(name).foregroundColor(Palette.textBright))
                    .font(.system(size: Metrics.labelSize, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Palette.textBright)
            .padding(.horizontal, Metrics.sessionPadding)
            .frame(height: Metrics.tabHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The toolbar is a title bar accessory, so without this a drag begun on
        // the button moved the window and *then* opened the menu on the
        // mouse-up. See `WindowChrome`.
        .claimsMouseDown()
        // Out of the command table rather than written here, which is what
        // finally settles this line: it said ⌘⇧K — in the wrong modifier order
        // and bound to nothing at all — until the View menu's "Change Session"
        // landed and the two could be held against each other. Derived now from
        // the same `KeyboardShortcut` that menu item applies, so there is
        // nothing left to get out of order or out of date.
        .help(Commands.help(.changeSession, store))
    }
}

// MARK: - Tabs

struct TerminalTab: View {
    /// Nil while the server has not yet listed the tab's terminal, which is
    /// the window between creating one and the list arriving.
    let terminal: TerminalSummary?
    let isActive: Bool
    /// Draw the hairline on this tab's leading edge. Only between two inactive
    /// tabs — the active pill provides its own edge.
    let showsLeadingSeparator: Bool
    /// A tab is being dragged over this slot, so say where it would land.
    var isDropTarget: Bool = false
    /// This slot is the one being dragged.
    var isDragging: Bool = false
    /// The strip's namespace for the active pill. One pill moves between slots
    /// rather than one per slot fading in and out, which is what makes
    /// selecting a tab slide rather than blink.
    let pill: Namespace.ID
    let select: () -> Void
    let close: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Only for the ✕'s tooltip, which names a command and so reads its
    /// wording out of `Commands`. A slot draws nothing else off the store —
    /// what it shows is handed to it, so that a strip of them is one `ForEach`
    /// over values rather than twenty views each observing the world.
    @Environment(SessionStore.self) private var store
    @State private var isHovering = false

    private let closeWidth: CGFloat = 16
    /// One id for the whole strip, not one per tab: the pill is a single view
    /// moving between slots.
    private static let pillID = "active-pill"

    /// Always on the active tab, on hover for the rest — the way tab bars
    /// everywhere behave. Hover-only made it undiscoverable.
    ///
    /// Never on the slot being dragged. The dragged slot rides under the
    /// pointer, so the ✕ rides with it and the mouse-up that ends the drag
    /// lands *inside* the close button — dragging a tab by its ✕ closed it,
    /// measured. Taking the ✕ away for the length of the drag leaves the
    /// mouse-up on the select button instead, which is the behaviour the strip
    /// already wants: a dragged tab comes to the front.
    private var showsClose: Bool { (isActive || isHovering) && !isDragging }

    private var name: String { terminal?.name ?? "terminal" }
    private var residency: Residency { terminal?.residency ?? .live }
    /// Identifies the slot for layout tracing, whether or not the server has
    /// listed the terminal yet.
    private var traceID: String { terminal.map { "\($0.id)" } ?? "pending" }

    var body: some View {
        // Select and close are *siblings*, never nested. SwiftUI does not
        // reliably deliver events to a control inside another control — not in
        // a button's label, and not in its overlay either — so a close button
        // drawn "on top of" the tab is inert and the tab swallows the click.
        HStack(spacing: 0) {
            Button(action: select) {
                label.frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(name))
            .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)

            if showsClose {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Palette.textDim)
                        .frame(width: closeWidth, height: Metrics.tabHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Close \(name)"))
                // A slot is a tab, so this closes the tab and everything split
                // inside it — through `requestCloseTab`, which asks first when
                // that is more than one terminal.
                //
                // The chord is named only on the *active* tab, because that is
                // the only tab ⇧⌘W acts on. This ✕ also appears on hover over
                // an inactive one, where advertising it would be a lie. Both
                // halves come out of the command table, so the title and the
                // chord are the menu item's own.
                .help(
                    isActive
                        ? Commands.help(.closeTab, store)
                        : Commands.command(.closeTab).title(store))
            }
        }
        .padding(.horizontal, Metrics.tabLeadingPadding)
        .frame(width: Metrics.tabWidth, height: Metrics.tabHeight)
        // A slot is a control, not window chrome. Without this the title bar
        // takes the mouse-down and drags the window with it, so the drag
        // gesture the strip attaches below never starts and reordering (#38)
        // did nothing at all. Sized to the whole slot, so the ✕ inside it is
        // covered too. See `WindowChrome` for why the title bar behaves this
        // way and why the *empty* toolbar must keep doing so.
        .claimsMouseDown()
        .background {
            if isActive {
                RoundedRectangle(cornerRadius: Metrics.tabCornerRadius, style: .continuous)
                    .fill(Palette.tabActiveFill)
                    .overlay(
                        RoundedRectangle(
                            cornerRadius: Metrics.tabCornerRadius, style: .continuous
                        )
                        .strokeBorder(Palette.tabActiveStroke, lineWidth: 1)
                    )
                    // Exactly one slot carries this at a time, so SwiftUI has a
                    // source and a destination and slides the pill between
                    // them instead of fading one out and another in.
                    .matchedGeometryEffect(id: Self.pillID, in: pill)
            } else if isHovering {
                RoundedRectangle(cornerRadius: Metrics.tabCornerRadius, style: .continuous)
                    .fill(Palette.tabHoverFill)
            }
        }
        .overlay(alignment: .leading) {
            if showsLeadingSeparator { TabSeparator() }
        }
        // Where a dragged tab would land. An outline rather than a moving gap:
        // the slots are a fixed width laid edge to edge, so opening one would
        // shove every tab after it sideways for the length of the drag.
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: Metrics.tabCornerRadius, style: .continuous)
                    .strokeBorder(Palette.menuHighlight, lineWidth: 2)
                    .padding(1)
            }
        }
        .animation(Motion.tabs.animation(reduceMotion: reduceMotion), value: isDropTarget)
        .onHover { isHovering = $0 }
        .traceFrame("tab-\(traceID)")
    }

    private var label: some View {
        HStack(spacing: Metrics.badgeToLabel) {
            ZStack {
                TerminalBadge().traceFrame("badge-\(traceID)")
                // Residency rides on the badge rather than replacing the glyph,
                // so a parked terminal still reads as a terminal.
                if residency != .live {
                    Image(systemName: residencyIcon)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(residencyColor)
                        .padding(1.5)
                        .background(Circle().fill(Palette.toolbar))
                        .offset(x: 9, y: -8)
                        // Parking is a normal thing that happens on its own, on
                        // a timer nobody asked about. A marker that pops into
                        // existence reads as an error; one that fades reads as
                        // a state.
                        .transition(Motion.badge.transition(reduceMotion: reduceMotion))
                }
            }
            .animation(Motion.badge.animation(reduceMotion: reduceMotion), value: residency)

            if let terminal {
                TerminalLabel(
                    terminal: terminal,
                    bright: isActive ? Palette.textBright : Palette.textDim,
                    dim: isActive ? Palette.textDim : Palette.textFaint)
            } else {
                Text("starting…")
                    .font(.system(size: Metrics.labelSize))
                    .foregroundStyle(Palette.textFaint)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var residencyIcon: String {
        switch residency {
        case .live: "circle.fill"
        case .parked: "moon.fill"
        case .rehydrating: "arrow.clockwise"
        case .exited: "xmark"
        }
    }

    private var residencyColor: Color {
        switch residency {
        case .live: .green
        case .parked: .orange
        case .rehydrating: .yellow
        case .exited: .red
        }
    }
}

/// The hairline between adjacent inactive tabs.
struct TabSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Palette.tabSeparator)
            .frame(width: 1, height: 17)
    }
}
