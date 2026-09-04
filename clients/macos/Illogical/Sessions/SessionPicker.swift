//  SessionPicker.swift
//  The session dropdown in the window's toolbar.

import IllogicalProtocol
import SwiftUI

struct SessionPicker: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Picker("Session", selection: $store.selectedID) {
            ForEach(store.terminals) { session in
                Label {
                    Text(session.name)
                } icon: {
                    Image(systemName: icon(for: session.residency))
                }
                .tag(Optional(session.id))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(minWidth: 160)
    }

    private func icon(for residency: Residency) -> String {
        switch residency {
        case .live: "circle.fill"
        case .parked: "moon.zzz"
        case .rehydrating: "arrow.clockwise"
        case .exited: "xmark.circle"
        }
    }
}
