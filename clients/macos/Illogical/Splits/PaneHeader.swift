//  PaneHeader.swift
//  Each terminal's own header: what it is, and what you can do to it.
//
//  The controls live here rather than in the window toolbar because they act
//  on *this* terminal. In a tab with four panes, "split right" has to mean
//  "split this one", and a button in the title bar cannot say which one it
//  means without the user first having selected it.

import IllogicalProtocol
import SwiftUI

struct PaneHeader: View {
    @Environment(SessionStore.self) private var store
    let pane: Pane
    let tab: TabLayout.ID
    let isFocused: Bool

    private var terminal: TerminalSummary? { store.terminal(pane.terminal) }
    private var isSplit: Bool { store.tabs.first { $0.id == tab }?.isSplit ?? false }
    private var isZoomed: Bool { store.tabs.first { $0.id == tab }?.zoomed == pane.id }

    /// Nil for the local machine: "Local" in front of every breadcrumb on a
    /// laptop is noise. On a remote pane it is the first thing worth knowing,
    /// and the breadcrumb is the only place that can say it per pane — a tab
    /// with a split has one strip entry and two machines' worth of panes is
    /// not a thing a tab can express.
    private var remote: String? {
        pane.terminal.host.isRemote ? pane.terminal.host.displayName : nil
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: remote == nil ? "apple.terminal" : "globe")
                .font(.system(size: 12))
                .foregroundStyle(Palette.textFaint)

            if let remote {
                Text(remote)
                    .font(.system(size: Metrics.labelSize, weight: .medium))
                    .foregroundStyle(isFocused ? Palette.textDim : Palette.textFaint)
                    .lineLimit(1)
            }

            if let terminal {
                TerminalLabel(
                    terminal: terminal,
                    // The focused pane's label is the brighter one. With one
                    // pane this is the only state, and matches the reference.
                    bright: isFocused ? Palette.textDim : Palette.textFaint,
                    dim: Palette.textFaint)
            } else {
                Text("starting…")
                    .font(.system(size: Metrics.labelSize))
                    .foregroundStyle(Palette.textFaint)
            }

            Spacer(minLength: 8)

            HStack(spacing: Metrics.paneButtonSpacing) {
                // Every chord in this row comes out of the command table, so a
                // chord that moves in the menu bar moves here too. These
                // tooltips are further from the menu bar than any other in the
                // app, which is exactly why they were the ones most able to go
                // quietly stale.
                PaneButton(
                    systemImage: "square.split.2x1", help: Commands.help(.splitRight, store)
                ) {
                    store.split(pane: pane.id, in: tab, direction: .columns)
                }
                PaneButton(
                    systemImage: "square.split.1x2", help: Commands.help(.splitDown, store)
                ) {
                    store.split(pane: pane.id, in: tab, direction: .rows)
                }
                PaneButton(
                    systemImage: isZoomed
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right",
                    // The chord is the table's; the word is this header's, and
                    // deliberately so on both counts. "Zoom" rather than the
                    // menu's "Zoom Pane" because this button is already sitting
                    // on the pane it would zoom — and `isZoomed` is *this*
                    // pane, where the menu item can only ask whether anything
                    // in the front tab is zoomed. Different word, different
                    // question.
                    help: Commands.help(.toggleZoom, titled: isZoomed ? "Unzoom" : "Zoom"),
                    // Nothing to zoom out of in a tab with one pane, which is
                    // why the reference draws this one dimmed.
                    isEnabled: isSplit
                ) {
                    store.toggleZoom(pane.id, in: tab)
                }
                // Through `closeSurfacePane` — the policy ⌘W goes through,
                // because that is the chord this button advertises. Calling
                // `closePane` directly made the two differ on the one case
                // that matters: the last pane of the last tab, where ⌘W closes
                // the window and this left an empty one behind.
                //
                // Dimmed in an unsplit tab, like zoom: this ✕ closes *a pane*,
                // and in a tab with one pane that is the whole tab, so a click
                // would take it from a control that never said so. The strip's
                // own ✕ is the one that closes a tab, and it asks first when
                // that means more than one terminal. ⌘W still works — the
                // chord is allowed to mean both; a button is not.
                //
                // The one hand-written chord left in the client, and it has to
                // be: ⌘W is deliberately not in the command table, because it
                // is not a menu item at all — it travels the responder chain as
                // `performClose:` so the focused surface gets first refusal
                // (docs/CLIENT.md's keybinding table records this). There is no
                // `KeyboardShortcut` anywhere to derive it from. Said out loud
                // so the next sweep for stale chords stops here rather than
                // treating it as one that was missed.
                PaneButton(
                    systemImage: "xmark", help: "Close Pane (⌘W)",
                    isEnabled: isSplit
                ) {
                    WindowClose.pane(pane.id, in: tab, of: store)
                }
            }
            .traceFrame("pane-buttons")
        }
        .padding(.leading, Metrics.breadcrumbLeading)
        .padding(.trailing, Metrics.paneButtonTrailing)
        .frame(height: Metrics.breadcrumbHeight)
    }
}

private struct PaneButton: View {
    let systemImage: String
    let help: String
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(
                    isEnabled
                        ? (isHovering ? Palette.textBright : Palette.textDim)
                        : Palette.textFaint.opacity(0.5)
                )
                .frame(width: Metrics.paneButtonSize, height: Metrics.paneButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .help(help)
    }
}
