# Settings Add Child QR Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every Settings `Add Child` action mint a new-child pairing QR so child profile collection occurs only on the kid device.

**Architecture:** Reuse `ParentInviteStep` with `.newChild` and no target child. A small parent flow owns completion and refreshes `FamilyStore`; `HomeSettingsSheet` presents it from both existing Add Child buttons. Existing-child device pairing remains `ParentAddDevicePairingFlow` and always supplies a target UUID.

**Tech Stack:** SwiftUI, existing Pairing v2 `ParentInviteModel`, XCTest.

## Global Constraints

- New child profile collection is kid-device-only.
- Existing-child add-device and restore paths must never collect a child profile.
- Do not change backend pairing contracts or the existing `ParentAddDevicePairingFlow` behavior.
- Do not stage Xcode user-state files or unrelated metering work.

---

### Task 1: Parent New-Child QR Flow

**Files:**
- Create: `Evlin iOS/Views/Onboarding/PairingV2/ParentNewChildPairingFlow.swift`
- Modify: `Evlin iOSTests/PairingV2Tests.swift`

**Interfaces:**
- Consumes: `ParentInviteStep(model:purpose:targetChildProfileID:targetChildName:showsOnboardingProgress:)`.
- Produces: `ParentNewChildPairingFlow(apiClient:onDone:onCancel:)`.

- [ ] Write a failing test proving the new-child presentation contract has purpose `.newChild` and no target child id.
- [ ] Run the focused XCTest and verify it fails because the presentation contract does not exist.
- [ ] Add the thin SwiftUI flow that injects `ParentInviteModel.live`, presents `ParentInviteStep` with `.newChild`/`nil`, and invokes `onDone` after join.
- [ ] Re-run the focused XCTest and verify it passes.

### Task 2: Replace Settings Text Entry

**Files:**
- Modify: `Evlin iOS/Views/Home/HomeSettingsSheet.swift`
- Test: `Evlin iOSTests/PairingV2Tests.swift`

**Interfaces:**
- Consumes: `ParentNewChildPairingFlow` from Task 1.
- Produces: both Settings Add Child buttons present QR pairing and refresh the family after completion.

- [ ] Write a failing test for the Settings presentation destination selecting new-child QR rather than direct child creation.
- [ ] Run it and verify it fails.
- [ ] Replace the `adding` sheet and `addChild(name:age:)` calls with one full-screen `ParentNewChildPairingFlow`; after completion refresh `FamilyStore` and local children.
- [ ] Run `PairingV2Tests` plus the relevant Settings tests and build the iOS app target.
- [ ] Commit only the new flow, Settings hunk, tests, and this plan; exclude `xcuserdata` and unrelated work.
