# Lazy Tagging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let parents say "lock IG" in chat and have iOS resolve "Instagram" → ApplicationToken → shield, with a one-tap fallback ("Tag Instagram") that opens a custom picker the first time iOS doesn't know an app name.

**Architecture:** ChatViewModel runs a pre-flight `LocalAliasStore` lookup on incoming `ProposalDTO`s with `tool == "shield_app"`. On miss, ProposalCard renders a Tag button + warning + disabled Confirm. The Tag button sets `activeLazyTagRequest`, which triggers a `.sheet(item:)` in ChatView presenting a `CustomTokenPickerView`. That view shows existing tokens via `Label(token)` for single-select, with an "Add via Apple picker" footer that widens `selectedApps` as an explicit, intentional side effect. Selection flows through `LazyTagPersistence` into `LocalAliasStore`, which is shared with `ActionExecutor` for shield resolution.

**Tech Stack:** Swift 5, SwiftUI, FamilyControls, ManagedSettings, XCTest. Single-device test mode and `.child` Max mode only — std two-device alias sync is deferred.

**Spec:** `docs/superpowers/specs/2026-05-06-lazy-tagging-design.md`

---

## File Structure

**Create (4 new files):**
- `Evlin iOS/Models/AliasKind.swift` — enum shared by Persistence + ChatViewModel
- `Evlin iOS/Models/LazyTagRequest.swift` — Identifiable struct driving `.sheet(item:)`
- `Evlin iOS/Services/LazyTagPersistence.swift` — pure persistence helper, no UI
- `Evlin iOS/Views/LazyTag/CustomTokenPickerView.swift` — single-select picker with Apple picker fallback

**Modify (3 files):**
- `Evlin iOS/Views/Chat/ChatViewModel.swift` — pre-flight, state, hard guard, callbacks
- `Evlin iOS/Components/ConfirmationCards/ProposalCard.swift` — alias-miss UI
- `Evlin iOS/Views/Chat/ChatView.swift` — wire props + sheet

**Test (1 new test file):**
- `Evlin iOSTests/LazyTagTests.swift` — pure-logic tests (extractAliasTarget, hard guard, persistence-error branches)

---

## Task 1: AliasKind enum + LazyTagRequest model

**Files:**
- Create: `Evlin iOS/Models/AliasKind.swift`
- Create: `Evlin iOS/Models/LazyTagRequest.swift`

Foundation types needed by every other task. No tests — these are 2-field structs / 2-case enums; tests would just assert syntax.

- [ ] **Step 1: Create `AliasKind.swift`**

```swift
// Evlin iOS/Models/AliasKind.swift
//
// Discriminator for lazy-tag flows. ChatViewModel sets this when an alias
// miss is detected; LazyTagPersistence and CustomTokenPickerView branch on
// it for the right token type and the right Apple-picker init.

import Foundation

enum AliasKind: Equatable {
    case app
    case category
}
```

- [ ] **Step 2: Create `LazyTagRequest.swift`**

```swift
// Evlin iOS/Models/LazyTagRequest.swift
//
// Drives the `.sheet(item:)` in ChatView. `id` is the ProposalDTO.token of
// the proposal that triggered the tag flow — that token doubles as a
// stable identifier for the proposal AND satisfies Identifiable so SwiftUI
// can present/dismiss the sheet correctly.

import Foundation

struct LazyTagRequest: Identifiable, Equatable {
    let id: String       // proposalToken
    let target: String   // e.g. "Instagram"
    let kind: AliasKind
}
```

- [ ] **Step 3: Build verify**

Run: `xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination "generic/platform=iOS" build 2>&1 | grep -E "error:" | head -5 && echo OK`
Expected: `OK` only — no errors.

- [ ] **Step 4: Commit**

```bash
git add "Evlin iOS/Models/AliasKind.swift" "Evlin iOS/Models/LazyTagRequest.swift"
git commit -m "feat(lazy-tag): AliasKind enum + LazyTagRequest model"
```

---

## Task 2: LazyTagPersistence service

**Files:**
- Create: `Evlin iOS/Services/LazyTagPersistence.swift`
- Create: `Evlin iOSTests/LazyTagTests.swift` (test the wrong-type rejection — success path requires real tokens, which can't be minted in tests)

Pure data layer. Validates token type matches AliasKind, calls into `LocalAliasStore.shared`. We use `Any` for the token parameter because we want callers to pass either `ApplicationToken` or `ActivityCategoryToken` from a `selectedApps` iteration where the static type is the union; the persistence layer enforces the right type at runtime.

- [ ] **Step 1: Write the failing test**

Create `Evlin iOSTests/LazyTagTests.swift`:

```swift
// Evlin iOSTests/LazyTagTests.swift
import XCTest
@testable import Evlin_iOS

final class LazyTagPersistenceTests: XCTestCase {
    /// Passing a non-token Any (e.g. String) for `.app` mode must produce
    /// `.wrongTokenType`. We can't mint real ApplicationToken in tests
    /// (FamilyControls auth is unavailable), so we test only the
    /// type-mismatch branch — the success branch is covered by manual E2E.
    func test_persistAlias_rejectsWrongTypeForApp() {
        let result = LazyTagPersistence.persistAlias(
            token: "not a token" as Any,
            kind: .app,
            target: "Instagram"
        )
        switch result {
        case .failure(let err): XCTAssertEqual(err, .wrongTokenType)
        case .success: XCTFail("expected wrongTokenType failure")
        }
    }

    func test_persistAlias_rejectsWrongTypeForCategory() {
        let result = LazyTagPersistence.persistAlias(
            token: 42 as Any,
            kind: .category,
            target: "games"
        )
        switch result {
        case .failure(let err): XCTAssertEqual(err, .wrongTokenType)
        case .success: XCTFail("expected wrongTokenType failure")
        }
    }

    func test_persistAlias_rejectsEmptyTarget() {
        let result = LazyTagPersistence.persistAlias(
            token: "x" as Any,
            kind: .app,
            target: "   "
        )
        switch result {
        case .failure(let err): XCTAssertEqual(err, .emptyTarget)
        case .success: XCTFail("expected emptyTarget failure")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails (no implementation yet)**

Run: `xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination "platform=iOS Simulator,name=iPhone 15" test 2>&1 | grep -E "error:|LazyTagPersistence" | head -5`
Expected: error along the lines of `cannot find 'LazyTagPersistence' in scope`.

- [ ] **Step 3: Implement `LazyTagPersistence.swift`**

```swift
// Evlin iOS/Services/LazyTagPersistence.swift
//
// Pure persistence helper for lazy tag. No UI, no presentation — just
// validates that the token type matches the kind, then delegates to
// LocalAliasStore. Caller (ChatViewModel.handleTagSelection) is
// responsible for sheet dismissal + miss-state cleanup.

import Foundation
import FamilyControls
import ManagedSettings

enum LazyTagError: Error, Equatable {
    case wrongTokenType
    case emptyTarget
}

enum LazyTagPersistence {
    static func persistAlias(
        token: Any,
        kind: AliasKind,
        target: String
    ) -> Result<Void, LazyTagError> {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyTarget) }

        switch kind {
        case .app:
            guard let appToken = token as? ApplicationToken else {
                return .failure(.wrongTokenType)
            }
            LocalAliasStore.shared.saveApplicationAliases(
                token: appToken,
                displayName: trimmed,
                bundleIdentifier: nil
            )
            return .success(())
        case .category:
            guard let catToken = token as? ActivityCategoryToken else {
                return .failure(.wrongTokenType)
            }
            LocalAliasStore.shared.saveCategoryToken(catToken, forName: trimmed)
            return .success(())
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination "platform=iOS Simulator,name=iPhone 15" test 2>&1 | grep -E "Test Case|FAILED|passed" | head -10`
Expected: 3 LazyTagPersistenceTests pass. No FAILED output for these tests.

- [ ] **Step 5: Commit**

```bash
git add "Evlin iOS/Services/LazyTagPersistence.swift" "Evlin iOSTests/LazyTagTests.swift"
git commit -m "feat(lazy-tag): LazyTagPersistence helper + type-rejection tests"
```

---

## Task 3: ChatViewModel — extractAliasTarget + alias-miss state

**Files:**
- Modify: `Evlin iOS/Views/Chat/ChatViewModel.swift`
- Modify: `Evlin iOSTests/LazyTagTests.swift` (add `extractAliasTarget` tests)

Adds the parsing function that reads `tool` + `args` from a ProposalDTO and returns `(target, kind)` if the proposal needs alias resolution.

- [ ] **Step 1: Write failing test**

Add to `Evlin iOSTests/LazyTagTests.swift` (append a new class at the bottom):

```swift
final class ExtractAliasTargetTests: XCTestCase {
    private func proposal(tool: String, args: [String: Any]) -> ProposalDTO {
        let typed = args.mapValues { AnyCodable($0) }
        return ProposalDTO(
            tool: tool,
            args: typed,
            label: "test",
            danger: "low",
            token: UUID().uuidString
        )
    }

    func test_returnsAppTarget_forShieldApp_withAppKind() {
        let p = proposal(tool: "shield_app", args: [
            "target": "Instagram",
            "target_kind": "app"
        ])
        let result = ChatViewModel.extractAliasTarget(from: p)
        XCTAssertEqual(result?.target, "Instagram")
        XCTAssertEqual(result?.kind, .app)
    }

    func test_returnsCategoryTarget_forShieldApp_withCategoryKind() {
        let p = proposal(tool: "shield_app", args: [
            "target": "games",
            "target_kind": "category"
        ])
        let result = ChatViewModel.extractAliasTarget(from: p)
        XCTAssertEqual(result?.target, "games")
        XCTAssertEqual(result?.kind, .category)
    }

    func test_returnsNil_forAllKind() {
        let p = proposal(tool: "shield_app", args: [
            "target": "his phone",
            "target_kind": "all"
        ])
        XCTAssertNil(ChatViewModel.extractAliasTarget(from: p))
    }

    func test_returnsNil_forListKind() {
        let p = proposal(tool: "shield_app", args: [
            "target": "bedtime apps",
            "target_kind": "list"
        ])
        XCTAssertNil(ChatViewModel.extractAliasTarget(from: p))
    }

    func test_returnsNil_forNonShieldTool() {
        let p = proposal(tool: "propose_reflection", args: [
            "target": "anything"
        ])
        XCTAssertNil(ChatViewModel.extractAliasTarget(from: p))
    }

    func test_returnsNil_whenTargetMissing() {
        let p = proposal(tool: "shield_app", args: [
            "target_kind": "app"
        ])
        XCTAssertNil(ChatViewModel.extractAliasTarget(from: p))
    }
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination "platform=iOS Simulator,name=iPhone 15" test 2>&1 | grep -E "error:" | head -5`
Expected: error `type 'ChatViewModel' has no member 'extractAliasTarget'`.

- [ ] **Step 3: Implement `extractAliasTarget` + alias-miss state**

Modify `Evlin iOS/Views/Chat/ChatViewModel.swift`. Add to the `@Published` block (right after `@Published var errorMessage: String?` near line 11):

```swift
    /// ProposalToken → kind for proposals whose alias didn't resolve at
    /// pre-flight. Drives ProposalCard's "Tag <target>" UI and the hard
    /// guard inside `confirmProposal(_:)`.
    @Published var pendingAliasMisses: [String: AliasKind] = [:]

    /// Non-nil when ChatView should present the lazy-tag sheet.
    /// Set when parent taps "Tag <target>"; cleared on save / cancel.
    @Published var activeLazyTagRequest: LazyTagRequest? = nil
```

Add the parsing function as a `static` method on ChatViewModel (anywhere in the class — pick a spot after `init` for visibility, e.g. just before `// MARK: - Agent envelope handlers (Phase E)` near line 641):

```swift
    // MARK: - Lazy tagging

    /// Pure parser: pull `(target, kind)` out of a ProposalDTO if it's a
    /// `shield_app` call with a kind that needs alias resolution (`"app"`
    /// or `"category"`). Returns nil for `"all"`, `"list"`, missing target,
    /// or any other tool.
    static func extractAliasTarget(from proposal: ProposalDTO) -> (target: String, kind: AliasKind)? {
        guard proposal.tool == "shield_app" else { return nil }
        guard let target = proposal.args["target"]?.value as? String,
              !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        guard let rawKind = proposal.args["target_kind"]?.value as? String else { return nil }
        switch rawKind {
        case "app": return (target, .app)
        case "category": return (target, .category)
        default: return nil   // "all", "list", anything else: no alias needed
        }
    }

    /// Computed view of whether a proposal needs alias resolution before Confirm.
    /// True = OK to confirm, false = miss outstanding.
    func aliasHit(for proposal: ProposalDTO) -> Bool {
        pendingAliasMisses[proposal.token] == nil
    }

    /// Returns the alias-miss target string (e.g. "Instagram") for ProposalCard
    /// rendering — nil if no miss for this proposal.
    func aliasMissTarget(for proposal: ProposalDTO) -> String? {
        guard pendingAliasMisses[proposal.token] != nil else { return nil }
        return Self.extractAliasTarget(from: proposal)?.target
    }
```

Now wire pre-flight detection at the spot where ProposalDTOs first enter the view model. Find the block in `sendMessage` near line 213 that reads:

```swift
        if (resp.proposals?.isEmpty == false) || (resp.receipts?.isEmpty == false) {
            var msg = ChatMessage(
                role: .agent, content: resp.message, timestamp: Date(),
                reasoning: resp.reasoning, action: nil
            )
            msg.proposals = resp.proposals
            msg.receipts = resp.receipts
            messages.append(msg)
            isThinking = false
            return
        }
```

Replace it with:

```swift
        if (resp.proposals?.isEmpty == false) || (resp.receipts?.isEmpty == false) {
            // Pre-flight every incoming proposal: if it's shield_app with an
            // app/category target we don't know yet, mark it as a miss so
            // ProposalCard can render the "Tag <target>" button and Confirm
            // is held back until the alias is bound.
            for p in resp.proposals ?? [] {
                guard let (target, kind) = Self.extractAliasTarget(from: p) else { continue }
                let aliasResolved: Bool = {
                    switch kind {
                    case .app: return LocalAliasStore.shared.applicationToken(forLookupKey: target) != nil
                    case .category: return LocalAliasStore.shared.categoryToken(forName: target) != nil
                    }
                }()
                if !aliasResolved {
                    pendingAliasMisses[p.token] = kind
                }
            }
            var msg = ChatMessage(
                role: .agent, content: resp.message, timestamp: Date(),
                reasoning: resp.reasoning, action: nil
            )
            msg.proposals = resp.proposals
            msg.receipts = resp.receipts
            messages.append(msg)
            isThinking = false
            return
        }
```

- [ ] **Step 4: Run tests + build to verify pass**

Run: `xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination "platform=iOS Simulator,name=iPhone 15" test 2>&1 | grep -E "error:|Test Case '-\[Evlin_iOSTests\.ExtractAliasTargetTests" | head -10`
Expected: 6 ExtractAliasTargetTests pass, no errors.

- [ ] **Step 5: Commit**

```bash
git add "Evlin iOS/Views/Chat/ChatViewModel.swift" "Evlin iOSTests/LazyTagTests.swift"
git commit -m "feat(lazy-tag): pre-flight alias detection in ChatViewModel"
```

---

## Task 4: ChatViewModel — `confirmProposal` hard guard

**Files:**
- Modify: `Evlin iOS/Views/Chat/ChatViewModel.swift` (line ~647 — `confirmProposal`)

Defense-in-depth: even if the UI lets a Confirm tap through (state race, future entry point, etc.), the view model itself refuses to dispatch when an alias miss is outstanding.

- [ ] **Step 1: Modify `confirmProposal(_:)`**

Find:

```swift
    @MainActor
    func confirmProposal(_ p: ProposalDTO) async {
        let client = AgentClient(baseURL: apiClient.baseURL)
        do {
            let receipt = try await client.executeProposal(token: p.token)
```

Replace the opening with:

```swift
    @MainActor
    func confirmProposal(_ p: ProposalDTO) async {
        // Hard guard: never dispatch if the alias for this proposal hasn't
        // been bound yet. The UI also disables the button, but this catches
        // races and future programmatic entry points.
        if pendingAliasMisses[p.token] != nil {
            errorMessage = "Tap \"Tag\" first so I know which app you mean."
            return
        }
        let client = AgentClient(baseURL: apiClient.baseURL)
        do {
            let receipt = try await client.executeProposal(token: p.token)
```

- [ ] **Step 2: Build verify**

Run: `xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination "generic/platform=iOS" build 2>&1 | grep -E "error:" | head -5 && echo OK`
Expected: `OK` only.

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Views/Chat/ChatViewModel.swift"
git commit -m "feat(lazy-tag): hard guard in confirmProposal — refuse if alias miss"
```

---

## Task 5: ChatViewModel — tag flow callbacks

**Files:**
- Modify: `Evlin iOS/Views/Chat/ChatViewModel.swift`

Adds three small callbacks: parent taps "Tag" (open sheet), parent picks a token (persist + cleanup), parent cancels (close sheet, leave miss intact).

- [ ] **Step 1: Add the three methods**

In `ChatViewModel.swift`, append inside the `// MARK: - Lazy tagging` section (right after `aliasMissTarget(for:)` from Task 3):

```swift
    /// Called from ProposalCard "Tag <target>" button. Opens the lazy-tag
    /// sheet by setting `activeLazyTagRequest`. Caller's responsibility:
    /// proposal must currently have a miss in `pendingAliasMisses`.
    @MainActor
    func beginLazyTag(for proposal: ProposalDTO) {
        guard let kind = pendingAliasMisses[proposal.token] else { return }
        guard let (target, _) = Self.extractAliasTarget(from: proposal) else { return }
        activeLazyTagRequest = LazyTagRequest(
            id: proposal.token,
            target: target,
            kind: kind
        )
    }

    /// Called from CustomTokenPickerView's `onSelect` after parent taps Save.
    /// Persists the alias and clears the miss for this proposal token.
    @MainActor
    func handleTagSelection(token: Any, request: LazyTagRequest) {
        let result = LazyTagPersistence.persistAlias(
            token: token,
            kind: request.kind,
            target: request.target
        )
        switch result {
        case .success:
            pendingAliasMisses.removeValue(forKey: request.id)
            activeLazyTagRequest = nil
        case .failure(let err):
            errorMessage = "Couldn't save the tag: \(err)"
            // Leave activeLazyTagRequest intact so user can retry without
            // losing the sheet context.
        }
    }

    /// Called from CustomTokenPickerView's `onCancel`. Dismisses the sheet
    /// but leaves `pendingAliasMisses` intact — Tag button stays visible
    /// on the card so parent can retry.
    @MainActor
    func cancelLazyTag() {
        activeLazyTagRequest = nil
    }
```

- [ ] **Step 2: Build verify**

Run: `xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination "generic/platform=iOS" build 2>&1 | grep -E "error:" | head -5 && echo OK`
Expected: `OK` only.

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Views/Chat/ChatViewModel.swift"
git commit -m "feat(lazy-tag): beginLazyTag / handleTagSelection / cancelLazyTag callbacks"
```

---

## Task 6: ProposalCard — alias-miss UI

**Files:**
- Modify: `Evlin iOS/Components/ConfirmationCards/ProposalCard.swift`

Adds two parameters and a conditional warning + Tag button. When `aliasMissTarget` is nil, the card renders exactly as today.

- [ ] **Step 1: Replace the file with the new version**

Rewrite `Evlin iOS/Components/ConfirmationCards/ProposalCard.swift`:

```swift
import SwiftUI

/// Generic AI proposal card — surface AI-staged tool calls for parent
/// approval. One card per Proposal in the agent response. Tap Confirm
/// → POST /parent/agent/exec → in-place becomes a ReceiptBubble.
///
/// When `aliasMissTarget` is non-nil, the card renders an additional
/// warning row + "Tag <target>" button and disables Confirm until the
/// view model removes the miss (after lazy-tag flow saves an alias).
struct ProposalCard: View {
    let proposal: ProposalDTO
    var onConfirm: () async -> Void
    var onSkip: () -> Void
    var aliasMissTarget: String? = nil
    var onTag: () -> Void = {}
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: dangerIcon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(dangerColor)
                Text(proposal.label)
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Color.evOnSurface)
            }
            if !bodyText.isEmpty {
                Text(bodyText)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .lineSpacing(2)
            }
            if let missTarget = aliasMissTarget {
                aliasMissBlock(target: missTarget)
            }
            HStack(spacing: 10) {
                Button(action: { Task { await runConfirm() } }) {
                    Text(working ? "Working…" : "Confirm")
                        .font(.system(size: 15, weight: .heavy))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(confirmBackground)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(confirmDisabled)
                Button(action: onSkip) {
                    Text("Skip")
                        .font(.system(size: 15, weight: .heavy))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color.evSurfaceContainerLow)
                        .foregroundStyle(Color.evOnSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(16)
        .background(Color.evSurfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(dangerColor.opacity(0.3), lineWidth: 1)
        )
    }

    /// Warning row + "Tag <target>" button shown above the Confirm/Skip bar
    /// when an alias miss is outstanding.
    @ViewBuilder
    private func aliasMissBlock(target: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange)
                    .font(.system(size: 13))
                Text("Evlin doesn't know which app is \u{201C}\(target)\u{201D} yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }
            Button(action: onTag) {
                Text("Tag \(target)")
                    .font(.system(size: 14, weight: .heavy))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Color.orange)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func runConfirm() async {
        working = true
        await onConfirm()
        working = false
    }

    private var confirmDisabled: Bool { working || aliasMissTarget != nil }

    private var confirmBackground: Color {
        aliasMissTarget != nil ? Color.evOutline : dangerColor
    }

    private var dangerColor: Color {
        switch proposal.danger {
        case "high": return Color.evError
        case "medium": return Color.orange
        default: return Color.evSecondary
        }
    }

    private var dangerIcon: String {
        switch proposal.danger {
        case "high": return "exclamationmark.triangle.fill"
        case "medium": return "questionmark.circle.fill"
        default: return "sparkles"
        }
    }

    private var bodyText: String {
        if let reason = proposal.args["reason"]?.value as? String {
            return "Reason: \"\(reason)\""
        }
        if let title = proposal.args["title"]?.value as? String {
            return "Title: \(title)"
        }
        if let minutes = proposal.args["minutes"]?.value as? Int {
            return "Duration: \(minutes) min"
        }
        return ""
    }
}
```

- [ ] **Step 2: Build verify**

Run: `xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination "generic/platform=iOS" build 2>&1 | grep -E "error:" | head -5 && echo OK`
Expected: `OK` only. (ChatView still passes the old 3-arg init, but Swift will accept it because the new params have defaults.)

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Components/ConfirmationCards/ProposalCard.swift"
git commit -m "feat(lazy-tag): ProposalCard renders warning + Tag button when alias miss"
```

---

## Task 7: CustomTokenPickerView

**Files:**
- Create: `Evlin iOS/Views/LazyTag/CustomTokenPickerView.swift`

The single-select picker shown in the sheet. Lists `Label(token)` rows from `screenTimeManager.selectedApps` (apps or categories per `request.kind`), with an "Add via Apple picker" footer. The Apple picker fallback for category mode MUST use `FamilyActivitySelection(includeEntireCategory: true)` — without that flag, tapping a category row enumerates individual app tokens instead of producing a category token.

- [ ] **Step 1: Create the file**

Create `Evlin iOS/Views/LazyTag/CustomTokenPickerView.swift`:

```swift
// Evlin iOS/Views/LazyTag/CustomTokenPickerView.swift
//
// Single-select picker presented as a `.sheet(item:)` from ChatView when
// ChatViewModel sets `activeLazyTagRequest`. Reads existing tokens from
// `screenTimeManager.selectedApps` (the source of truth for what's
// shieldable). Provides an "Add via Apple picker" footer that opens the
// system FamilyActivityPicker — picking there both widens selectedApps
// (so the token becomes shieldable) AND surfaces it in our custom list
// for the parent to bind.

import SwiftUI
import FamilyControls
import ManagedSettings

struct CustomTokenPickerView: View {
    let request: LazyTagRequest
    let onSelect: (Any, LazyTagRequest) -> Void
    let onCancel: () -> Void

    @EnvironmentObject var screenTimeManager: ScreenTimeManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedAppToken: ApplicationToken? = nil
    @State private var selectedCategoryToken: ActivityCategoryToken? = nil
    @State private var applePickerOpen = false
    /// For .app: empty selection so Apple picker starts blank; we read
    /// it via .onChange and merge into screenTimeManager.selectedApps.
    /// For .category: MUST be `includeEntireCategory: true` so a category-row
    /// tap produces an ActivityCategoryToken instead of N app tokens.
    @State private var pickerSelection: FamilyActivitySelection = FamilyActivitySelection()

    private var apps: [ApplicationToken] {
        Array(screenTimeManager.selectedApps.applicationTokens)
            .sorted { $0.hashValue < $1.hashValue }
    }
    private var categories: [ActivityCategoryToken] {
        Array(screenTimeManager.selectedApps.categoryTokens)
            .sorted { $0.hashValue < $1.hashValue }
    }
    private var canSave: Bool {
        switch request.kind {
        case .app: return selectedAppToken != nil
        case .category: return selectedCategoryToken != nil
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                listBody
                Divider()
                footer
            }
            .navigationTitle(request.kind == .app ? "Tag app" : "Tag category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveTapped() }
                        .disabled(!canSave)
                }
            }
            .familyActivityPicker(isPresented: $applePickerOpen, selection: $pickerSelection)
            .onChange(of: applePickerOpen) { _, isOpen in
                if !isOpen { mergePickerIntoSelectedApps() }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Which one is")
                .font(.custom("Inter", size: 13))
                .foregroundStyle(Color.evOnSurfaceVariant)
            Text("\u{201C}\(request.target)\u{201D}?")
                .font(.custom("Manrope", size: 24).weight(.bold))
                .foregroundStyle(Color.evOnSurface)
            Text("Tap the \(request.kind == .app ? "app" : "category") below. Evlin will remember it for next time.")
                .font(.custom("Inter", size: 12))
                .foregroundStyle(Color.evOutline)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.evSurfaceContainerLow)
    }

    @ViewBuilder
    private var listBody: some View {
        switch request.kind {
        case .app:
            if apps.isEmpty {
                emptyState(
                    message: "No apps in Managed Apps yet. Tap \u{201C}Add via Apple picker\u{201D} below to add \(request.target)."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(apps.enumerated()), id: \.offset) { _, tok in
                            appRow(token: tok)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                }
            }
        case .category:
            if categories.isEmpty {
                emptyState(
                    message: "No categories yet. Tap \u{201C}Add via Apple picker\u{201D} and tap the \(request.target) row."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(categories.enumerated()), id: \.offset) { _, tok in
                            categoryRow(token: tok)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                }
            }
        }
    }

    @ViewBuilder
    private func emptyState(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(Color.evOutline)
            Text(message)
                .font(.custom("Inter", size: 13))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func appRow(token: ApplicationToken) -> some View {
        let isSelected = selectedAppToken == token
        return Button {
            selectedAppToken = token
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.evPrimary : Color.evOutline)
                Label(token)
                    .labelStyle(.titleAndIcon)
                    .font(.custom("Inter", size: 15).weight(.semibold))
                    .foregroundStyle(Color.evOnSurface)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(isSelected ? Color.evPrimary.opacity(0.08) : Color.evSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.evPrimary : Color.evOutline.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func categoryRow(token: ActivityCategoryToken) -> some View {
        let isSelected = selectedCategoryToken == token
        return Button {
            selectedCategoryToken = token
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.evPrimary : Color.evOutline)
                Label(token)
                    .labelStyle(.titleAndIcon)
                    .font(.custom("Inter", size: 15).weight(.semibold))
                    .foregroundStyle(Color.evOnSurface)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(isSelected ? Color.evPrimary.opacity(0.08) : Color.evSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.evPrimary : Color.evOutline.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Don't see \u{201C}\(request.target)\u{201D}?")
                .font(.custom("Inter", size: 12).weight(.semibold))
                .foregroundStyle(Color.evOnSurfaceVariant)
            Text("Open Apple's picker to add it. New tokens will appear in the list above.")
                .font(.custom("Inter", size: 11))
                .foregroundStyle(Color.evOutline)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                openApplePicker()
            } label: {
                Label("Open Apple picker", systemImage: "plus.circle")
                    .font(.custom("Inter", size: 13).weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.evSurfaceContainerLow)
    }

    private func openApplePicker() {
        // Required init flag for category mode — without `includeEntireCategory: true`,
        // tapping a category row in the system picker enumerates individual apps
        // instead of producing a single ActivityCategoryToken.
        switch request.kind {
        case .app:
            pickerSelection = FamilyActivitySelection()
        case .category:
            pickerSelection = FamilyActivitySelection(includeEntireCategory: true)
        }
        applePickerOpen = true
    }

    /// Apple picker dismissed → merge whatever was picked into the persisted
    /// `selectedApps` so the row appears in our custom list and the token
    /// is also in the FamilyControls authorization scope (shieldable).
    private func mergePickerIntoSelectedApps() {
        var merged = screenTimeManager.selectedApps
        merged.applicationTokens.formUnion(pickerSelection.applicationTokens)
        merged.categoryTokens.formUnion(pickerSelection.categoryTokens)
        merged.webDomainTokens.formUnion(pickerSelection.webDomainTokens)
        screenTimeManager.selectedApps = merged
        screenTimeManager.saveSelection()
    }

    private func saveTapped() {
        switch request.kind {
        case .app:
            guard let tok = selectedAppToken else { return }
            onSelect(tok, request)
            dismiss()
        case .category:
            guard let tok = selectedCategoryToken else { return }
            onSelect(tok, request)
            dismiss()
        }
    }
}
```

- [ ] **Step 2: Build verify**

Run: `xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination "generic/platform=iOS" build 2>&1 | grep -E "error:" | head -5 && echo OK`
Expected: `OK` only.

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Views/LazyTag/CustomTokenPickerView.swift"
git commit -m "feat(lazy-tag): CustomTokenPickerView with single-select + Apple picker fallback"
```

---

## Task 8: ChatView wiring

**Files:**
- Modify: `Evlin iOS/Views/Chat/ChatView.swift`

Pass alias-miss state into ProposalCard, present the lazy-tag sheet, ensure `screenTimeManager` is in the environment.

- [ ] **Step 1: Update ProposalCard call site**

Find in `Evlin iOS/Views/Chat/ChatView.swift` (around line 76):

```swift
                                        ForEach(proposals, id: \.token) { p in
                                            ProposalCard(
                                                proposal: p,
                                                onConfirm: { await viewModel.confirmProposal(p) },
                                                onSkip: { viewModel.skipProposal(p) }
                                            )
                                        }
```

Replace with:

```swift
                                        ForEach(proposals, id: \.token) { p in
                                            ProposalCard(
                                                proposal: p,
                                                onConfirm: { await viewModel.confirmProposal(p) },
                                                onSkip: { viewModel.skipProposal(p) },
                                                aliasMissTarget: viewModel.aliasMissTarget(for: p),
                                                onTag: { viewModel.beginLazyTag(for: p) }
                                            )
                                        }
```

- [ ] **Step 2: Add the lazy-tag sheet modifier**

Find the existing modifier chain at the bottom of `ChatView.body` (look for `.environmentObject` / `.onAppear` / `.background` near the outer container). Add a `.sheet(item:)` next to the existing modifiers. If no obvious spot, attach it to the `NavigationStack` or root container:

```swift
        .sheet(item: $viewModel.activeLazyTagRequest) { req in
            CustomTokenPickerView(
                request: req,
                onSelect: { token, request in
                    viewModel.handleTagSelection(token: token, request: request)
                },
                onCancel: {
                    viewModel.cancelLazyTag()
                }
            )
        }
```

If `screenTimeManager` is not already in the environment of the view tree containing ChatView, propagate it. In single-device test mode, it's typically injected at app root via `@EnvironmentObject` — verify with a grep:

```bash
grep -rn "environmentObject(screenTimeManager\|screenTimeManager: ScreenTimeManager()" "Evlin iOS/" | head -5
```

If it's at app root: nothing more to do — `.sheet`'s root view inherits the environment. If not: add `.environmentObject(screenTimeManager)` to the sheet content.

- [ ] **Step 3: Build verify**

Run: `xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination "generic/platform=iOS" build 2>&1 | grep -E "error:" | head -10 && echo OK`
Expected: `OK` only. If errors mention `screenTimeManager` not found in CustomTokenPickerView, fix per Step 2 fallback.

- [ ] **Step 4: Commit**

```bash
git add "Evlin iOS/Views/Chat/ChatView.swift"
git commit -m "feat(lazy-tag): wire ProposalCard alias-miss + sheet presentation in ChatView"
```

---

## Task 9: Manual E2E smoke test

**No code changes. Verifies the integrated flow end-to-end on a real device.**

Single device, parent + kid mode toggle. Picker should already have at least one specific app selected (recommended onboarding path). If `selectedApps.applicationTokens` is empty, Step 4 below tests the Apple-picker-fallback path explicitly.

- [ ] **Step 1: Install on device**

Run from Xcode (▶︎). Wait for app to launch and reach Chat tab.

- [ ] **Step 2: Pre-test — verify alias is empty**

In chat, type: `lock Instagram`
Expected: Backend returns ProposalDTO. Card appears. Card shows orange "Evlin doesn't know which app is "Instagram" yet." warning + "Tag Instagram" button. Confirm button is grey/disabled.

- [ ] **Step 3: Tag flow with existing token in selection**

Tap "Tag Instagram". Sheet slides up titled "Tag app". Header reads "Which one is "Instagram"?". List shows already-selected apps as `Label(token)` rows with radio circles.

If Instagram is in the list: tap that row (radio fills). Tap "Save" (top-right). Sheet dismisses. Card warning vanishes; Confirm becomes red/active. Tap Confirm. Receipt bubble appears, IG locked.

- [ ] **Step 4: Tag flow via Apple picker fallback**

In chat, type: `lock Snapchat` (assuming Snapchat is NOT yet in selectedApps).
Expected: Card with miss warning.
Tap "Tag Snapchat". Sheet slides up. List doesn't contain Snapchat.
Tap "Open Apple picker" footer button. Apple's FamilyActivityPicker opens.
Tap Snapchat to select it. Tap Done.
Apple picker closes; back in custom picker. List now contains a new Label(token) row. Tap it (radio fills). Tap Save.
Sheet dismisses, Card warning gone, Confirm enabled. Tap Confirm. Receipt + Snapchat shielded.

- [ ] **Step 5: Repeat-hit (alias persisted)**

In chat, type: `lock instagram` (lowercase).
Expected: Card appears WITHOUT alias-miss warning. Confirm directly active. Tap Confirm. Works.

- [ ] **Step 6: Cancel flow**

In chat, type: `lock TikTok` (assuming not yet tagged).
Card appears with miss warning. Tap "Tag TikTok". Sheet opens. Tap "Cancel" (top-left).
Expected: Sheet dismisses. Card STILL shows the warning + Tag button. Confirm STILL disabled. Parent can retry by tapping Tag again.

- [ ] **Step 7: Hard guard verification**

Open Xcode debugger console while card has outstanding miss. Have to find a way to call `confirmProposal` programmatically — easiest is to set a breakpoint on `confirmProposal`, then from LLDB:

```
po viewModel.pendingAliasMisses
```

Should show `[token: kind]`. Then continue past the guard — should hit the `errorMessage` set, not the `executeProposal` call. If you can't easily test the LLDB path, consider this verified by code inspection of Task 4.

- [ ] **Step 8: Category tag flow**

In chat, type: `lock games`
Expected: Card with miss warning ("Evlin doesn't know which app is "games" yet" — wording is generic, copy can be refined later).
Tap "Tag games". Sheet titled "Tag category". List shows existing category tokens.
If empty: tap Apple picker footer. Apple picker opens. Tap the "Games" category row (top-level row, NOT a specific game app). Tap Done.
Custom picker now shows the Games category token. Tap it, Save.
Sheet dismisses, card Confirm enables, tap Confirm. Receipt — games category shielded.

- [ ] **Step 9: Final commit (smoke test docs)**

Nothing to commit unless any wording/copy issues turned up. If they did, fix and commit.

---

## Self-Review Notes

Spec coverage check:
- Pre-flight detection ✓ Task 3
- ProposalCard miss UI ✓ Task 6
- Hard guard ✓ Task 4
- ChatViewModel callbacks (begin/handle/cancel) ✓ Task 5
- CustomTokenPickerView with single-select + Apple picker fallback ✓ Task 7
- Category mode with `includeEntireCategory: true` ✓ Task 7 step 1
- LazyTagPersistence type validation ✓ Task 2
- ChatView .sheet(item:) ✓ Task 8
- Manual E2E happy path + cancel + category + repeat-hit ✓ Task 9

Out of scope (per spec, not included in this plan):
- Std two-device alias sync — separate spec
- Multi-target merged tag wizard — future
- Tag editing/deletion UI — future
- DeviceActivityReport extension write-back — abandoned

Type consistency check (single pass): `AliasKind` only appears with `.app` / `.category`; `LazyTagRequest.id` is `String` (proposalToken) everywhere; `aliasMissTarget` is `String?` everywhere; `LazyTagError` cases used: `.wrongTokenType`, `.emptyTarget` — match between Task 2 implementation and Task 2 tests.
