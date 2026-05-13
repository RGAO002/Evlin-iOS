# Reflection Parent UI Implementation Plan

Date: 2026-05-13
Target repo: `/Users/fred/Desktop/Evlin/Evlin iOS`
Reference spec: `/Users/fred/Desktop/Evlin/frontend_for_app_evlin/docs/superpowers/specs/2026-05-13-reflection-parent-ui-design.md`

## Hard Constraints

- `frontend_for_app_evlin` is reference-only. Do not implement UI there.
- Implement in the real iOS app under `Evlin iOS/Evlin iOS`.
- Do not touch Small Kids screens in this plan.
- Preserve parent-note/message support for reflection approval.
- Do not fake child step progress. Pending assigned reflection uses the calm status page.
- Do not start implementation until this plan is reviewed.

## Current Ground Truth

- Chat reflection review already exists at `Evlin iOS/Evlin iOS/Components/Chat/ReflectionSubmissionReviewCard.swift`.
- Reflection card routing exists at `Evlin iOS/Evlin iOS/Components/Chat/ReflectionCardAdapter.swift`, but `reflection.confirm_approve` and `reflection.confirm_redo` currently fall back to generic PlanArch rendering.
- Child-side BigKid reflection steps exist:
  - `Views/Child/BigKid/Reflection/BigKidVideoView.swift`
  - `Views/Child/BigKid/Reflection/BigKidQuizView.swift`
  - `Views/Child/BigKid/Reflection/BigKidWritingView.swift`
  - `Views/Child/BigKid/Reflection/BigKidCompleteView.swift`
- Parent Home currently renders `ProfileCard(child:)` from `Views/Home/HomeView.swift`.
- Parent Profile currently owns profile header + current tasks in `Views/Profile/ProfileView.swift`.

## Task 1 — Add Parent Reflection UI Models

Files:

- Add `Evlin iOS/Evlin iOS/Models/ParentReflectionModels.swift`
- Add `Evlin iOS/Evlin iOSTests/ParentReflectionModelsTests.swift`

Steps:

- Define `ParentReflectionState`: `.none`, `.assignedPending`, `.completedReady`.
- Define `ParentReflectionSummary` with `id`, `childId`, `childName`, `state`, `reason`, `assignedAt`, `submittedAt`, `parentNote`, `prompt`, `essayText`, `takeaway`.
- Define `ParentReflectionStep`: `.video`, `.quiz`, `.writing`.
- Add stable fixture data for Liam:
  - one assigned pending reflection.
  - one completed reflection artifact.
- Keep this model local/prototype-oriented. Do not wire backend persistence in this plan.

Acceptance:

- Tests verify decoding/fixtures and state transitions used by routing.

## Task 2 — Restyle Chat Reflection Review Card

Files:

- Modify `Evlin iOS/Evlin iOS/Components/Chat/ReflectionSubmissionReviewCard.swift`
- Modify or add tests in `Evlin iOS/Evlin iOSTests/PlanArchCardAdapterReflectionEventTests.swift`

Steps:

- Restyle card to match the frontend reference: warm cream/white surface, dark navy headline, compact uppercase labels, rounded artifact sections.
- Keep parent note input.
- Keep fallback note logic via `ReflectionParentNoteFallback`.
- Ensure copy is parent-facing:
  - Pending approval title: `Approve reflection`
  - Description: child completed reflection and parent can optionally leave a message.
  - Parent note label: `Message for Liam`
- Do not remove async `onApprove`.

Acceptance:

- Existing note behavior still works.
- Empty essay still disables approve.
- Visual hierarchy has sections for prompt, child words, parent message, approve CTA.

## Task 3 — Route Reflection Approve/Redo To Polished Card

Files:

- Modify `Evlin iOS/Evlin iOS/Components/Chat/ReflectionCardAdapter.swift`
- Modify `Evlin iOS/Evlin iOS/Components/Chat/PlanArchCardAdapter.swift` if needed.
- Tests: `Evlin iOS/Evlin iOSTests/PlanArchCardAdapterReflectionEventTests.swift`

Steps:

- Stop falling back to generic PlanArch for `reflection.confirm_approve` when detail contains enough review data.
- Map review payload into a render model or dedicated reflection review route.
- Keep fallback to generic PlanArch when required detail is missing.
- Keep `reflection.confirm_redo` fallback unless there is already a polished redo card path.

Acceptance:

- `reflection.confirm_approve` with prompt + essay renders polished review card.
- Unknown/malformed detail still falls back safely.

## Task 4 — Home Card Under Reflection State

Files:

- Modify `Evlin iOS/Evlin iOS/Components/ProfileCard.swift`
- Modify `Evlin iOS/Evlin iOS/Models/ChildProfile.swift` or add derived reflection state input if needed.
- Modify `Evlin iOS/Evlin iOS/Views/Home/HomeView.swift`

Steps:

- Add a rendering path for `UNDER REFLECTION`.
- Remove any countdown/time-left treatment for reflection state.
- Add `View reflection` CTA with reflection icon.
- Keep existing normal/locked/unlocked profile card behavior unchanged.
- For prototype fixture, Liam can be the reflection child.

Acceptance:

- Reflection child card resembles the provided screenshot structure.
- No `15M` or countdown appears in reflection state.
- Tapping `View reflection` routes to reflection flow, not just profile.

## Task 5 — Profile Header Reflection State

Files:

- Modify `Evlin iOS/Evlin iOS/Views/Profile/ProfileView.swift`
- Optionally add `Evlin iOS/Evlin iOS/Components/Reflection/ParentReflectionStatusCard.swift`

Steps:

- Extract the current summary card into a helper if needed.
- Add reflection summary header matching screenshot:
  - avatar.
  - lock/status overlay.
  - large child name.
  - `UNDER REFLECTION` badge.
  - `View reflection` CTA.
- Use this header when `ParentReflectionState.assignedPending` or `.completedReady` exists for that child.
- Keep current tasks/devices/rules sections below.

Acceptance:

- Profile top area matches screenshot.
- CTA route depends on state:
  - assigned pending -> pending page.
  - completed ready -> artifact page.

## Task 6 — Add Parent Reflection Pending Page

Files:

- Add `Evlin iOS/Evlin iOS/Views/Profile/ReflectionPendingView.swift`
- Update navigation in parent stack, likely `ContentView.swift` / `DashboardView.swift` depending current route ownership.

Steps:

- Build calm status card:
  - title: `Reflection in progress`
  - body: `Liam hasn't finished this reflection yet. You'll get notified when it's ready to review.`
  - actions: `Send reminder`, `Cancel reflection`
- Do not show step progress.
- Use warm reflection styling consistent with Home/Profile reflection card.
- Buttons can be prototype no-op callbacks unless existing backend endpoints are already available.

Acceptance:

- Assigned pending state opens this page.
- No fake Step 1/3 progress appears.

## Task 7 — Add Parent Reflection Artifact Page

Files:

- Add `Evlin iOS/Evlin iOS/Views/Profile/ReflectionArtifactView.swift`
- Add reusable components under `Evlin iOS/Evlin iOS/Components/Reflection/` if needed.

Steps:

- Render completed artifact sections:
  - assignment summary.
  - Evlin prompt.
  - child written words.
  - quiz result/question if fixture available.
  - Evlin takeaway.
  - approve / request redo actions.
  - optional parent response note.
- Use existing child-side data concepts but parent-side styling.
- Do not trigger Gemini or video network calls from this prototype page.

Acceptance:

- Completed reflection notification and profile CTA open artifact page.
- Prompt/text/takeaway visible.
- Parent actions visible.

## Task 8 — Add Parent Reflection Step Detail Pages

Files:

- Add `Evlin iOS/Evlin iOS/Views/Profile/ReflectionStepDetailView.swift`
- Optionally share display models with Task 7.

Steps:

- Show `Step 1 of 3` video state.
- Show `Step 2 of 3` quiz state.
- Show `Step 3 of 3` written reflection state.
- Reference child-side reflection files for structure, but do not copy child-only lock UI.
- Represent fallback video as normal educational fallback, not joke/Rickroll copy.

Acceptance:

- Artifact page can navigate to each step detail.
- Step labels match `Step N of 3`.

## Task 9 — Home Notification Deep-Link

Files:

- Modify `Evlin iOS/Evlin iOS/Views/Home/NotificationPanel.swift`
- Modify route owner (`ContentView.swift` or dashboard parent).
- Add tests if route logic is testable.

Steps:

- Add reflection completion notification fixture:
  - title: `Liam completed reflection`
  - body: `Liam finished his reflection and it's ready for your review.`
- Tapping notification routes directly to `ReflectionArtifactView`.
- Mark notification read after tap.

Acceptance:

- Notification opens artifact page without requiring manual profile navigation.

## Task 10 — Navigation Integration

Files:

- Inspect and modify the actual navigation owner:
  - `Evlin iOS/Evlin iOS/ContentView.swift`
  - `Evlin iOS/Evlin iOS/Views/Dashboard/DashboardView.swift`
  - `Evlin iOS/Evlin iOS/Views/Profile/ProfileView.swift`

Steps:

- Add route cases for:
  - reflection pending.
  - reflection artifact.
  - reflection step detail.
- Preserve existing profile/task/device navigation.
- Keep back navigation and swipe-back behavior.

Acceptance:

- Home -> reflection child card -> pending/artifact works.
- Profile -> View reflection -> pending/artifact works.
- Notification -> artifact works.
- Artifact -> step detail -> back works.

## Task 11 — Visual Verification

Steps:

- Build in Xcode.
- Run iOS tests in Xcode.
- Manually inspect:
  - Chat reflection review card.
  - Home reflection child card.
  - Profile reflection header.
  - Pending page.
  - Completed artifact page.
  - Step detail pages.
  - Notification deep-link.
- Compare against frontend reference and provided screenshot.

Acceptance:

- Pixel direction matches design: warm card, dark navy type, rounded borders, reflection badge, no countdown.
- Parent note remains available.
- No Small Kids files changed.

## Task 12 — Commit Boundary

Commit after tests/manual verification with message:

```text
feat(reflection): align parent reflection UI
```

Do not commit `build/` artifacts.

