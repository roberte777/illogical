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
    /// The breadcrumb glyph starts at 27pt of ink in the reference.
    static let breadcrumbLeading: CGFloat = 24
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

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: Metrics.iconToTitle) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 13, weight: .regular))
                    .traceFrame("session-icon")
                Text(store.selectedSession?.name ?? "no session")
                    .font(.system(size: Metrics.labelSize, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Palette.textBright)
            .padding(.horizontal, Metrics.sessionPadding)
            .frame(height: Metrics.tabHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Change Session (⌘⇧K)")
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
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    private let closeWidth: CGFloat = 16

    /// Always on the active tab, on hover for the rest — the way tab bars
    /// everywhere behave. Hover-only made it undiscoverable.
    private var showsClose: Bool { isActive || isHovering }

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
                .help("Close terminal")
            }
        }
        .padding(.horizontal, Metrics.tabLeadingPadding)
        .frame(width: Metrics.tabWidth, height: Metrics.tabHeight)
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
            } else if isHovering {
                RoundedRectangle(cornerRadius: Metrics.tabCornerRadius, style: .continuous)
                    .fill(Palette.tabHoverFill)
            }
        }
        .overlay(alignment: .leading) {
            if showsLeadingSeparator { TabSeparator() }
        }
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
                }
            }

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
