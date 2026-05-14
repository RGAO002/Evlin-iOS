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
//  conversationId persists in UserDefaults so a single conversation lives
//  across app launches; resetConversation() rotates it (e.g. "new chat").
//
//  Implementation note: @AppStorage is a SwiftUI property wrapper that does
//  NOT publish changes through ObservableObject. To use this class with
//  @StateObject / @EnvironmentObject we need an explicit @Published, with
//  manual UserDefaults read/write in didSet so the persisted value stays in
//  sync with the @Published value.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class SmartModeStore: ObservableObject {

    private static let smartModeKey = "evlin.smart_mode"
    private static let conversationIdKey = "evlin.conversation_id"

    @Published var isOn: Bool {
        didSet {
            UserDefaults.standard.set(isOn, forKey: Self.smartModeKey)
        }
    }

    init() {
        if UserDefaults.standard.object(forKey: Self.smartModeKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.smartModeKey)
        }
        self.isOn = UserDefaults.standard.bool(forKey: Self.smartModeKey)
    }

    /// Stable per-install conversation id. Lazily creates one the first time
    /// it is requested and persists in UserDefaults.
    var conversationId: UUID {
        let key = Self.conversationIdKey
        if let s = UserDefaults.standard.string(forKey: key),
           let u = UUID(uuidString: s) {
            return u
        }
        let fresh = UUID()
        UserDefaults.standard.set(fresh.uuidString, forKey: key)
        return fresh
    }

    /// Reset conversation on user request (e.g., "new chat").
    func resetConversation() {
        UserDefaults.standard.set(UUID().uuidString, forKey: Self.conversationIdKey)
    }

    /// Read the backend source of truth when Settings opens.
    func sync(familyId: UUID, apiClient: APIClient) async {
        do {
            let remote = try await apiClient.getSmartMode(familyID: familyId)
            isOn = remote
        } catch {
            // Keep the local value so Settings remains usable offline.
        }
    }

    /// Push the toggle state to backend whenever it changes.
    func push(familyId: UUID, apiClient: APIClient) async {
        do {
            try await apiClient.setSmartMode(familyID: familyId, isOn: isOn)
        } catch {
            // Do not revert the toggle on transient local backend failures.
            // The next Settings open will sync from backend truth.
        }
    }
}
