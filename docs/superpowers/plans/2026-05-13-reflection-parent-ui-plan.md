# Reflection Parent UI Implementation Plan

Date: 2026-05-13
Target repo: `/Users/fred/Desktop/Evlin/Evlin iOS`
Reference spec: `/Users/fred/Desktop/Evlin/frontend_for_app_evlin/docs/superpowers/specs/2026-05-13-reflection-parent-ui-design.md`
Status: v2.1, ready for review, not ready for execution until approved

## Hard Constraints

- `frontend_for_app_evlin` is reference-only. Do not implement UI there.
- Implement in the real iOS app under `Evlin iOS/Evlin iOS`.
- Do not touch Small Kids screens.
- Preserve parent-note/message support for reflection approval.
- Do not fake child step progress. Pending assigned reflection uses the calm status page.
- Use XCTest only for new tests in `Evlin iOSTests/`. Do not introduce Swift Testing.
- Light-mode visual target only. Dynamic Type sanity-check is required; Dark Mode polish is out of scope.
- This iteration is fixture-only for parent reflection state. Backend `reflection.confirm_approve` / `reflection.confirm_redo` events still render through chat, but they do not mutate `ParentReflectionFixtureStore`.
- Do not start implementation until this plan is reviewed.

## Verification Commands

Use these at the end of every task unless the task explicitly says otherwise.

Quick build:

```bash
xcodebuild build \
  -project "Evlin iOS.xcodeproj" \
  -scheme "Evlin iOS" \
  -destination "generic/platform=iOS"
```

Tests:

```bash
xcodebuild test \
  -project "Evlin iOS.xcodeproj" \
  -scheme "Evlin iOS" \
  -destination "platform=iOS Simulator,name=iPhone 15"
```

If `iPhone 15` is unavailable:

```bash
xcrun simctl list devices available | head -10
```

Then choose an available iPhone simulator and rerun the test command with that destination.

Commit after every task. Do not make one mega-commit.

All new SwiftUI views must include at least one `#Preview` block showing the most common state.

## Current Ground Truth

- `ContentView.swift` owns parent navigation. `AppRoute` is the route enum and `appNavigationDestination` is the centralized destination resolver. `DashboardView.swift` is not the route owner.
- Chat reflection review already exists at `Evlin iOS/Evlin iOS/Components/Chat/ReflectionSubmissionReviewCard.swift`.
- Existing `ReflectionSubmissionReviewCard` already has prompt, essay, parent note, fallback note, and approve button. It should be restyled, not rewritten.
- Reflection card routing exists at `Evlin iOS/Evlin iOS/Components/Chat/ReflectionCardAdapter.swift`, but `reflection.confirm_approve` and `reflection.confirm_redo` currently fall back to generic PlanArch rendering.
- Child-side BigKid reflection steps exist:
  - `Views/Child/BigKid/Reflection/BigKidVideoView.swift`
  - `Views/Child/BigKid/Reflection/BigKidQuizView.swift`
  - `Views/Child/BigKid/Reflection/BigKidWritingView.swift`
  - `Views/Child/BigKid/Reflection/BigKidCompleteView.swift`
- Parent Home currently renders `ProfileCard(child:)` from `Views/Home/HomeView.swift`.
- Parent Profile currently owns profile header + current tasks in `Views/Profile/ProfileView.swift`.

## Task Boundary Rules

- Task 4 creates the shared reflection status card component only. It does not wire Home or Profile.
- Task 5 wires Profile.
- Task 6 wires Home.
- `ProfileCard` remains the normal non-reflection Home card. Reflection branching happens in `HomeView`, not inside `ProfileCard`.
- `ParentReflectionFixtureStore` must be injected in Task 1. Any later `@Environment(ParentReflectionFixtureStore.self)` access assumes Task 1 already completed.

## Visual Tokens To Use

Use existing design system tokens where possible. Do not hardcode a parallel palette unless a token does not exist.

- Reflection surface: `Color.evReflectionSurface` if added, backed by a warm cream close to `#F4E7CF`.
- Reflection border: `Color.evReflectionBorder` if added, backed by a warm tan close to `#C99B55`.
- Primary headline: existing dark navy `Color.evPrimary`.
- Badge text: dark brown close to `#5B4023`.
- Badge background: muted tan close to `#DCCDB4`.
- Primary CTA: cream fill with tan border, dark brown/navy text.
- Card radius: use existing `CornerRadius.xl` where available; otherwise match current large rounded cards.
- Label style: uppercase, semibold/heavy, letter spacing around `0.12em` to `0.16em`.

If adding new colors, add them in `DesignSystem/EvlinColors.swift` and keep names reflection-specific.

## Task 0 — Plan Assumption Guard

Files:

- No code changes.

Steps:

- Confirm working tree only has expected untracked `build/` artifacts.
- Confirm no Small Kids paths are touched.
- Confirm `ContentView.swift` is route owner.
- Confirm new tests will use XCTest.

Verification:

```bash
git status --short
rg -n "enum AppRoute|appNavigationDestination|NavigationStack" "Evlin iOS/ContentView.swift"
```

Commit:

- No commit.

## Task 1 — Parent Reflection Models + Fixture Store

Files:

- Add `Evlin iOS/Evlin iOS/Models/ParentReflectionModels.swift`
- Add `Evlin iOS/Evlin iOSTests/ParentReflectionModelsTests.swift`
- Modify `Evlin iOS/Evlin iOS/ContentView.swift`

Design decisions:

- Do not modify `ChildProfile`.
- Use a sidecar store: `@Observable final class ParentReflectionFixtureStore`.
- Inject store from `ParentRootView` using `.environment(reflectionStore)`.
- Views read it with `@Environment(ParentReflectionFixtureStore.self)`.
- This is fixture/prototype state only.

Model sketch:

```swift
enum ParentReflectionState: String, Codable, Hashable {
    case none
    case assignedPending
    case completedReady
}

enum ParentReflectionStepKind: String, Codable, Hashable {
    case video
    case quiz
    case writing
}

struct ParentReflectionStepArtifact: Identifiable, Codable, Hashable {
    let id: UUID
    let kind: ParentReflectionStepKind
    let title: String
    let subtitle: String
    let body: String
}

struct ParentReflectionSummary: Identifiable, Codable, Hashable {
    let id: UUID
    let childId: String
    let childName: String
    var state: ParentReflectionState
    let reason: String
    let assignedAt: String
    var submittedAt: String?
    var parentNote: String?
    let prompt: String
    var essayText: String?
    var takeaway: String?
    var steps: [ParentReflectionStepArtifact]
}
```

Store behavior:

- `summary(for child: ChildProfile) -> ParentReflectionSummary?`
- `summary(childId: String) -> ParentReflectionSummary?`
- `simulateCompletion(childId: String)` flips the fixture from `.assignedPending` to `.completedReady`, fills `submittedAt`, `essayText`, `takeaway`, and the 3 standard steps.
- `resetToPending(childId: String)` is optional but useful for previews/tests.

Debug trigger:

- `simulateCompletion()` API is defined here only.
- The actual Profile `...` menu wiring happens in Task 5.
- Do not add any debug UI in Task 1.

ParentRootView injection:

```swift
struct ParentRootView: View {
    @State private var selectedTab: EvlinTab = .home
    @State private var profilePath = NavigationPath()
    @State private var insightsPath = NavigationPath()
    @State private var banner: (title: String, body: String, avatarURL: String?)? = nil
    @State private var reflectionStore = ParentReflectionFixtureStore()

    var body: some View {
        VStack(spacing: 0) {
            // existing shell
        }
        .environment(reflectionStore)
    }
}
```

If the actual `ParentRootView` body shape makes the exact placement awkward, attach `.environment(reflectionStore)` to the outermost view returned by `body`.

TDD steps:

- Write XCTest that store returns Liam's assigned pending summary.
- Write XCTest that `simulateCompletion(childId:)` flips Liam to `.completedReady`.
- Write XCTest that standard completed fixture has exactly 3 steps: video, quiz, writing.
- Run tests and confirm they fail before implementation.
- Implement models/store/fixtures.
- Modify `ParentRootView` to create and inject `ParentReflectionFixtureStore`.
- Run tests and quick build.
- Commit: `feat(reflection): add parent reflection fixture models`

## Task 1.5 — Pin Navigation Routes

Files:

- Modify `Evlin iOS/Evlin iOS/ContentView.swift`
- Add route-focused tests only if practical; otherwise rely on build + manual route verification in later tasks.

Add these route cases to `AppRoute`:

```swift
case reflectionPending(childId: String)
case reflectionArtifact(reflectionId: UUID)
case reflectionStepDetail(reflectionId: UUID, stepId: UUID)
```

Reasoning:

- `String` child ids match existing `ChildProfile.id`.
- `UUID` reflection and step ids match `ParentReflectionSummary.id` and `ParentReflectionStepArtifact.id`.
- All payload types are `Hashable`, so `AppRoute` can keep synthesized `Hashable`.

Destination behavior:

- `reflectionPending` resolves child + summary and opens `ReflectionPendingView`.
- `reflectionArtifact` resolves summary and opens `ReflectionArtifactView`.
- `reflectionStepDetail` resolves summary + step and opens `ReflectionStepDetailView`.
- If fixture lookup fails, show a small fallback error page with a back button. Do not crash.

Temporary placeholder shape:

```swift
private struct ReflectionPendingPlaceholder: View {
    var body: some View {
        VStack {
            Text("ReflectionPendingView — wired in Task 7")
        }
        .navigationTitle("Reflection")
    }
}
```

Use similarly named placeholders for artifact and step detail if Task 1.5 lands before those views exist. Later tasks must delete these placeholder types.

TDD/verification steps:

- Add route cases first and compile.
- Add placeholder destination views if needed to keep build green; later tasks replace placeholders.
- Run quick build.
- Commit: `feat(reflection): add parent reflection navigation routes`

## Task 2 — Restyle Chat Reflection Review Card

Files:

- Modify `Evlin iOS/Evlin iOS/Components/Chat/ReflectionSubmissionReviewCard.swift`
- Modify tests in `Evlin iOS/Evlin iOSTests/PlanArchCardAdapterReflectionEventTests.swift` only if behavior changes.

Scope:

- Restyle only. Do not rewrite card structure.
- Preserve current order:
  1. title row.
  2. explanatory copy.
  3. essay prompt.
  4. child reflection.
  5. parent message/note.
  6. approve CTA.
- Preserve `ReflectionParentNoteFallback`.
- Preserve async `onApprove`.
- Preserve empty-essay disable behavior.

Visual changes:

- Use reflection cream card background.
- Use dark navy title.
- Use uppercase section labels.
- Wrap prompt, essay, and parent message in artifact-like rounded sections.
- Keep parent note label: `Message for \(childName)`.
- Placeholder: `Add a note for \(childName)...`

TDD/verification steps:

- If behavior is unchanged, do not add fragile visual tests.
- Build after restyle.
- Manually preview card in Xcode or existing chat fixture.
- Commit: `feat(reflection): restyle parent review card`

## Task 3 — Route Approve And Redo To Polished Chat Card

Files:

- Modify `Evlin iOS/Evlin iOS/Components/Chat/ReflectionCardAdapter.swift`
- Modify `Evlin iOS/Evlin iOS/Components/Chat/ReflectionSubmissionReviewCard.swift` if mode support is needed.
- Tests: `Evlin iOS/Evlin iOSTests/PlanArchCardAdapterReflectionEventTests.swift`

Decision:

- Polish both `reflection.confirm_approve` and `reflection.confirm_redo` in this round.
- Use one shared polished card with mode:

```swift
enum ReflectionReviewMode {
    case approve
    case redo
}
```

Implementation placement:

- Keep payload parsing helpers private inside `ReflectionCardAdapter.swift`.
- Do not create a new adapter file unless the helper exceeds roughly 100 lines.

Behavior:

- `reflection.confirm_approve` with prompt + essay routes to polished card mode `.approve`.
- `reflection.confirm_redo` with prompt + essay routes to polished card mode `.redo`.
- Malformed/missing prompt or essay falls back to generic PlanArch rendering.
- Parent note remains available for approve.
- Redo mode should show redo reason UI if detail includes reason; otherwise show generic redo copy.

TDD steps:

- Add XCTest for approve payload -> polished render model/card path.
- Add XCTest for redo payload -> polished render model/card path.
- Add XCTest for malformed payload -> fallback nil.
- Confirm tests fail before implementation.
- Implement adapter parsing and mode.
- Run tests + quick build.
- Commit: `feat(reflection): route review cards to polished renderer`

## Task 4 — Shared Reflection Status Card Component Only

Files:

- Add `Evlin iOS/Evlin iOS/Components/Reflection/ParentReflectionStatusCard.swift`
- Do not modify `ChildProfile`.
- Do not modify `HomeView`.
- Do not modify `ProfileView`.
- Do not modify `ProfileCard`.

Component requirements:

- This component is shared by Home and Profile; do not implement two divergent reflection cards.
- Props:
  - `child: ChildProfile`
  - `summary: ParentReflectionSummary`
  - `layout: .homeCard | .profileHeader`
  - `onViewReflection: () -> Void`
- Shows `UNDER REFLECTION`.
- Removes any time/countdown UI.
- Shows `View reflection` CTA.
- Uses reflection icon consistently.
- Include `#Preview` for `.homeCard` and `.profileHeader`.

TDD/verification steps:

- If component logic can be unit-tested without snapshot, add a small test for CTA route selection in store/helper.
- Build and manually inspect previews.
- Commit: `feat(reflection): add shared reflection status card`

## Task 5 — Profile Header Reflection State

Files:

- Modify `Evlin iOS/Evlin iOS/Views/Profile/ProfileView.swift`

Steps:

- Read `ParentReflectionFixtureStore` from environment.
- If `summary(for: child)` returns assigned/completed state, render `ParentReflectionStatusCard(layout: .profileHeader)`.
- Wire `View reflection`:
  - `.assignedPending` -> append `AppRoute.reflectionPending(childId: child.id)`.
  - `.completedReady` -> append `AppRoute.reflectionArtifact(reflectionId: summary.id)`.
- Keep current tasks/devices/rules below the header.
- Add debug-only `Simulate reflection complete` to the existing top-right `...` menu.
- Wrap the debug menu item in `#if DEBUG`.
- Call `reflectionStore.simulateCompletion(childId: child.id)`.

TDD/verification steps:

- Build.
- Manually inspect Profile pending and completed state through fixture/debug toggle.
- Commit: `feat(reflection): show reflection state on profile`

## Task 6 — Home Card Reflection State

Files:

- Modify `Evlin iOS/Evlin iOS/Views/Home/HomeView.swift`
- Do not modify `Evlin iOS/Evlin iOS/Components/ProfileCard.swift`.

Steps:

- Read `ParentReflectionFixtureStore` from environment.
- In `HomeView`, conditionally render:

```swift
if let summary = reflectionStore.summary(for: child) {
    ParentReflectionStatusCard(
        child: child,
        summary: summary,
        layout: .homeCard,
        onViewReflection: { /* append route based on summary.state */ }
    )
} else {
    ProfileCard(child: child) {
        onOpenProfile(child)
    }
}
```

- Wire `View reflection` CTA using the same state routing as Profile.
- Keep normal card rendering for children without reflection.

TDD/verification steps:

- Build.
- Manually inspect Home child card.
- Confirm no `15M` or countdown appears.
- Commit: `feat(reflection): show reflection state on home`

## Task 7 — Pending Reflection Page

Files:

- Add `Evlin iOS/Evlin iOS/Views/Profile/ReflectionPendingView.swift`

Button behavior:

- `Send reminder`: prototype stub. Show local non-blocking feedback such as `Reminder queued`.
- `Cancel reflection`: prototype stub. Show local confirmation text. Do not call backend.
- Add comments:

```swift
// TODO: wire to backend reflection reminder endpoint when available.
// TODO: wire to backend reflection cancel endpoint when available.
```

Feedback behavior:

- Use simple SwiftUI `.alert(...)` for `Send reminder` and `Cancel reflection` stub feedback.
- Do not introduce a custom toast system.

Visual:

- Use the Visual Tokens section colors and label style for new view surfaces.
- Include `#Preview`.

UI copy:

```text
Reflection in progress
Liam hasn't finished this reflection yet. You'll get notified when it's ready to review.
```

TDD/verification steps:

- Build.
- Manually route from Profile/Home to pending page.
- Confirm no fake step progress.
- Commit: `feat(reflection): add pending reflection page`

## Task 8 — Completed Artifact Page

Files:

- Add `Evlin iOS/Evlin iOS/Views/Profile/ReflectionArtifactView.swift`
- Add reusable subcomponents in `Evlin iOS/Evlin iOS/Components/Reflection/` only if needed.

Button behavior:

- `Approve`: prototype stub unless existing callback is available in this surface. Show local feedback.
- `Request redo`: prototype stub. Show local feedback.
- Add TODO comments for backend wiring.
- Parent note/message area is visible in the artifact action area by default.
- Submitting the note is a prototype stub and does not save or call backend.

Required sections:

- Reflection assignment summary.
- Evlin prompt.
- Child written words.
- Quiz result or quiz question/answer fixture.
- Evlin takeaway.
- Parent actions.
- Parent note/message area if responding to child.
- Use the Visual Tokens section colors and label style for new view surfaces.
- Include `#Preview`.

TDD/verification steps:

- Build.
- Manually route from completed Home/Profile/notification to artifact page.
- Commit: `feat(reflection): add completed reflection artifact`

## Task 9 — Step Detail Pages

Files:

- Add `Evlin iOS/Evlin iOS/Views/Profile/ReflectionStepDetailView.swift`
- Modify `ReflectionArtifactView.swift` to link rows.

Behavior:

- Render steps from `summary.steps`.
- Display `Step N of \(summary.steps.count)`.
- Standard fixture has three steps: video, quiz, writing.
- If a future fixture lacks quiz, do not render fake quiz; the numbering follows the actual `steps` array.
- Parent UI should represent fallback video as normal educational fallback, not Rickroll copy.
- Use the Visual Tokens section colors and label style for new view surfaces.
- Include `#Preview`.

TDD/verification steps:

- Add model/store test if needed for step lookup.
- Build.
- Manually navigate artifact -> each step -> back.
- Commit: `feat(reflection): add reflection step detail pages`

## Task 10 — Notification Deep-Link

Files:

- Modify `Evlin iOS/Evlin iOS/Views/Home/NotificationPanel.swift`
- Modify `Evlin iOS/Evlin iOS/ContentView.swift` only if route callback signature needs extension.

Steps:

- Read existing `NotificationPanel.swift` first and locate the current mock/fixture notification array before adding a reflection notification.
- Add reflection completion notification fixture:

```text
Liam completed reflection
Liam finished his reflection and it's ready for your review.
```

- Tapping it appends `AppRoute.reflectionArtifact(reflectionId: summary.id)`.
- Mark notification read after tap.
- Existing task notification behavior must stay unchanged.

TDD/verification steps:

- Add XCTest only if notification route callback is isolated enough to test.
- Build.
- Manually tap notification and verify artifact opens.
- Commit: `feat(reflection): deep-link reflection notification`

## Task 11 — Reference Screenshot Baseline

Files:

- Add directory `Evlin iOS/docs/reflection/reference-screenshots/`
- Add a short README in that directory.

Steps:

- Save the provided profile reflection screenshot there if available as a local file, or add README instructions describing the reference.
- Do not implement automated visual diff.
- Include manual comparison checklist:
  - Home reflection card.
  - Profile reflection header.
  - Pending page.
  - Artifact page.
  - Step pages.
  - Chat review card.

Verification:

- Documentation-only commit.
- Commit: `docs(reflection): add visual reference checklist`

## Task 12 — Final Verification

Steps:

- Run quick build.
- Run XCTest.
- Xcode manual inspection:
  - Chat reflection review card.
  - Home reflection child card.
  - Profile reflection header.
  - Pending page.
  - Completed artifact page.
  - Step detail pages.
  - Notification deep-link.
- Confirm `git diff --name-only` contains no Small Kids files.
- Confirm `build/` artifacts are not staged.

Commit:

- If final verification requires a code fix, commit it separately with a focused message.
- Otherwise no commit.
