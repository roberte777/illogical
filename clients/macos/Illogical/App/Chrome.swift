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

enum Metrics {
    static let toolbarHeight: CGFloat = 39
    static let breadcrumbHeight: CGFloat = 27
    static let tabHeight: CGFloat = 27
    static let tabCornerRadius: CGFloat = 13
    static let tabMaxWidth: CGFloat = 260
    /// Space the hidden title bar reserves for the traffic lights.
    static let trafficLightInset: CGFloat = 76
    static let labelSize: CGFloat = 13
    static let badgeSize: CGFloat = 17
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
            HStack(spacing: 7) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 13, weight: .regular))
                Text(store.selectedSession?.name ?? "no session")
                    .font(.system(size: Metrics.labelSize, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Palette.textBright)
            .padding(.horizontal, 8)
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
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                TerminalBadge()
                // Residency rides on the badge rather than replacing the glyph,
                // so a parked terminal still reads as a terminal.
                if terminal.residency != .live {
                    Image(systemName: residencyIcon)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(residencyColor)
                        .padding(1.5)
                        .background(Circle().fill(Palette.toolbar))
                        .offset(x: 8, y: -7)
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
        .padding(.horizontal, 10)
        .frame(height: Metrics.tabHeight)
        .frame(maxWidth: Metrics.tabMaxWidth)
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
        .padding(.horizontal, 14)
        .frame(height: Metrics.breadcrumbHeight)
    }
}
