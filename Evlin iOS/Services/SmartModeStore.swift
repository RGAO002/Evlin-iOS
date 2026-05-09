//
//  SmartModeStore.swift
//  Evlin iOS
//
//  Strategy-agent Task 11.5 — Smart Mode toggle and stable conversation_id.
//
//  When Smart Mode is ON the agent can think through complex requests, ask
//  follow-up questions, and propose multi-step plans. When OFF the agent
//  only handles simple commands ("lock IG 30 mins").
//
//  conversationId persists in @AppStorage so a single conversation lives
//  across app launches; resetConversation() rotates it (e.g. "new chat").
//

import Foundation
import SwiftUI

@MainActor
final class SmartModeStore: ObservableObject {
    @AppStorage("evlin.smart_mode") var isOn: Bool = true
    @AppStorage("evlin.conversation_id") private var conversationIdString: String = ""

    var conversationId: UUID {
        if let existing = UUID(uuidString: conversationIdString) { return existing }
        let fresh = UUID()
        conversationIdString = fresh.uuidString
        return fresh
    }

    /// Reset conversation on user request (e.g., "new chat").
    func resetConversation() {
        conversationIdString = UUID().uuidString
    }

    /// Push the toggle state to backend whenever it changes (call from a
    /// `.onChange(of: isOn)` modifier in the SettingsView).
    func push(familyId: UUID) async {
        // Backend endpoint: PUT /parent/settings  body: {family_id, smart_mode}
        // Implementation deferred to whichever endpoint is canonical for parent settings.
        // For v1 this can be a no-op until backend exposes the endpoint; the @AppStorage
        // value is the source of truth for the iOS-only switch in the meantime.
    }
}
