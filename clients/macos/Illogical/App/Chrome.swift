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

// MARK: - Measured design tokens

enum Palette {
    static func rgb(_ hex: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255)
    }

    /// Sampled from empty toolbar, right of the last tab.
    static let toolbar = rgb(0x06_1D_31)
    /// Sampled from empty terminal background.
    static let background = rgb(0x0C_1F_2F)
    /// The hairline under the toolbar.
    static let divider = rgb(0x1D_2D_3E)

    /// Active tab pill.
    static let tabActiveFill = rgb(0x17_2A_3F)
    static let tabActiveStroke = rgb(0x2A_43_55)
    static let tabHoverFill = Color.white.opacity(0.04)
    /// The hairline between inactive tabs.
    static let tabSeparator = rgb(0x2A_3F_52)

    static let textBright = rgb(0xC3_D3_DE)
    static let textDim = rgb(0x7E_93_A4)
    static let textFaint = rgb(0x5E_72_82)

    /// The Terminal.app-style badge on each tab.
    static let badgeFill = rgb(0x3A_3D_42)
    static let badgeStroke = rgb(0x17_19_1C)
    static let badgeGlyph = rgb(0x4E_D8_5F)
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
    /// Content starts here so the session icon lands at 90.7pt, clear of the
    /// traffic lights. AppKit owns where the lights themselves sit.
    static let contentInset: CGFloat = 81
    static let sessionPadding: CGFloat = 8
    /// Gap between the session button and the first tab slot.
    static let sessionToTabs: CGFloat = 6
    /// 12pt, not 13: "Demo" measures 31.7pt of ink in the reference and "btop"
    /// 24.0pt, which is SF Pro at 12.
    static let labelSize: CGFloat = 12
    static let badgeSize: CGFloat = 20
    static let badgeToLabel: CGFloat = 10
    static let iconToTitle: CGFloat = 8
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
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
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
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            SessionList(isPresented: $isPresented).environment(store)
        }
    }
}

struct SessionList: View {
    @Environment(SessionStore.self) private var store
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Sessions")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 4)

            ForEach(store.sessions) { session in
                Button {
                    if let first = store.terminals.first(where: { $0.session == session.id }) {
                        store.selectedID = first.id
                    }
                    isPresented = false
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(session.name).font(.system(size: 12))
                        Spacer(minLength: 12)
                        Text("\(session.terminals.count)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if store.sessions.isEmpty {
                Text("No sessions yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }

            Divider().padding(.vertical, 4)

            Button {
                store.createTerminal(sessionName: "session-\(store.sessions.count + 1)")
                isPresented = false
            } label: {
                Label("New Session", systemImage: "plus")
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 6)
        }
        .frame(minWidth: 210)
    }
}

// MARK: - Tabs

struct TerminalTab: View {
    let terminal: TerminalSummary
    let isActive: Bool
    /// Draw the hairline on this tab's leading edge. Only between two inactive
    /// tabs — the active pill provides its own edge.
    let showsLeadingSeparator: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Metrics.badgeToLabel) {
            ZStack {
                TerminalBadge().traceFrame("badge-\(terminal.id)")
                // Residency rides on the badge rather than replacing the glyph,
                // so a parked terminal still reads as a terminal.
                if terminal.residency != .live {
                    Image(systemName: residencyIcon)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(residencyColor)
                        .padding(1.5)
                        .background(Circle().fill(Palette.toolbar))
                        .offset(x: 9, y: -8)
                }
            }

            TerminalLabel(
                terminal: terminal,
                bright: isActive ? Palette.textBright : Palette.textDim,
                dim: isActive ? Palette.textDim : Palette.textFaint)

            if isHovering {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Palette.textDim)
                }
                .buttonStyle(.plain)
                .help("Close terminal")
            }
        }
        .padding(.horizontal, Metrics.tabLeadingPadding)
        .frame(width: Metrics.tabWidth, height: Metrics.tabHeight, alignment: .leading)
        .traceFrame("tab-\(terminal.id)")
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
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: select)
    }

    private var residencyIcon: String {
        switch terminal.residency {
        case .live: "circle.fill"
        case .parked: "moon.fill"
        case .rehydrating: "arrow.clockwise"
        case .exited: "xmark"
        }
    }

    private var residencyColor: Color {
        switch terminal.residency {
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

// MARK: - Breadcrumb

struct Breadcrumb: View {
    let terminal: TerminalSummary?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "apple.terminal")
                .font(.system(size: 12))
                .foregroundStyle(Palette.textFaint)
            if let terminal {
                TerminalLabel(
                    terminal: terminal, bright: Palette.textDim, dim: Palette.textFaint)
            } else {
                Text("no terminal")
                    .font(.system(size: Metrics.labelSize))
                    .foregroundStyle(Palette.textFaint)
            }
            Spacer()
        }
        .padding(.leading, Metrics.breadcrumbLeading)
        .frame(height: Metrics.breadcrumbHeight)
    }
}
