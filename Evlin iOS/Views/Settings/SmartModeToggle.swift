//
//  SmartModeToggle.swift
//  Evlin iOS
//
//  Strategy-agent Task 11.6 — drop-in Settings section bound to a
//  SmartModeStore EnvironmentObject. Add via:
//      SmartModeToggle().environmentObject(smartMode)
//

import SwiftUI

struct SmartModeToggle: View {
    @EnvironmentObject var store: SmartModeStore

    var body: some View {
        Section {
            Toggle("Smart mode", isOn: $store.isOn)
            Text("When ON, Evlin can think through complex requests, ask follow-up questions, and propose multi-step plans. When OFF, Evlin only handles simple commands like 'lock IG 30 mins'.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("AI Behavior")
        }
    }
}
