# Big-Kid Child Mode — Design Spec

**Date:** 2026-05-02
**Status:** Draft, pending user review
**Scope:** First implementation of Evlin's "big kid" (≈8–12 yrs) child-side iOS UI, end-to-end. Eleven screens, pixel-perfect to Esen's React/JSX prototype.

---

## 1. Context & Goals

Evlin's parent-side iOS app is mature. The child-side ("big kid" mode) is the missing half: the experience the kid sees on the device that is being managed. Esen has produced a complete React/JSX prototype in `frontend_for_app_evlin/Evlin_Student_View/Evlin_student_view/` covering home, tasks, bypass, reflection consequence flow, and end-of-day states. This spec defines the iOS implementation matching that prototype 1:1 visually, with the minimum backend additions required to make it real (no parent-end UI changes in scope).

**Goals**
- Pixel-perfect parity with the JSX prototype (colors, spacing, radii, font sizes, shadows, motion timings).
- Real backend integration: tasks / time pool / bypass / reflection are server-driven, not local.
- End-to-end flows working: a kid can complete a task day, request a bypass, complete a reflection, and reach end-of-day states — all driven by real data.
- Bypass-prevention posture for child mode: the reflection flow must resist casual circumvention even before the AAC entitlement lands.

**Non-goals (v1)**
- AAC (Automatic Assessment Configuration) integration — deferred to v1.1, pending Apple entitlement approval.
- Mascot illustrations — `EvlinMascot()` is dead code in the prototype; do not invent.
- Push notifications — polling-only in v1; APNs deferred.
- Parent-side UI changes — bypass approval and reflection approval surfaces will be added on the parent side in a separate spec.
- Onboarding for child mode — separate spec; assume the device is already in child mode.
- Offline mode — assume connectivity; minimum viable error states only.

---

## 2. Source of Truth: JSX Prototype

**Implementation rule:** Every visual detail (color values, padding, border radius, font size, font weight, letter spacing, line height, shadow offsets, gradient stops, animation duration) **must** match the JSX source. No reinvention. When porting a screen, open the corresponding JSX file alongside the SwiftUI view and copy values verbatim.

| iOS view | JSX source (relative to `Evlin_Student_View/Evlin_student_view/`) |
|---|---|
| Design tokens | `theme.jsx` |
| Reusable primitives | `primitives.jsx` |
| Home (variant A) | `home.jsx` → `HomeScreenA` |
| Home (variant B) | `home.jsx` → `HomeScreenB` |
| HomeReflection | `home-reflection.jsx` → `HomeReflectionScreen` |
| TaskDetail | `task-detail.jsx` → `TaskDetailScreen` |
| Bypass | `bypass.jsx` → `BypassScreen` |
| LockedScreen (reflection hub) | `consequence-a.jsx` → `LockedScreen` + `ConsequenceSteps` |
| VideoScreen | `consequence-a.jsx` → `VideoScreen` |
| QuizScreen | `consequence-b.jsx` → `QuizScreen` |
| ReflectionScreen (writing) | `consequence-b.jsx` → `ReflectionScreen` |
| CompleteScreen | `consequence-b.jsx` → `CompleteScreen` |
| ScreenTimeFinishedScreen | `consequence-b.jsx` → `ScreenTimeFinishedScreen` |
| DailyCompleteScreen | `consequence-b.jsx` → `DailyCompleteScreen` |

Decision needed in Phase 1: **Home A vs Home B**. Both are present in the prototype. Default = **A** (clean engaging layout); B (circular dial) is built but not wired to navigation. Final pick before Phase 2 starts.

---

## 3. Screen Inventory (11 screens)

| # | Screen | Sub-states |
|---|---|---|
| 1 | Home | branches by `(allDone, outOfTime)`: locked-placeholder / time-hero / out-of-time |
| 2 | HomeReflection | **State A** (not done): "Finish Reflection to unlock phone" + "Start Reflection" — **State B** (3 steps done, awaiting parent): "You finished" + "Give them a nudge" w/ 5-min cooldown |
| 3 | TaskDetail | input / submitted / redo |
| 4 | Bypass | form / sent |
| 5 | LockedScreen (reflection hub) | shows progress 0/3 → 3/3, "Unlock my devices" enables at 3/3 |
| 6 | VideoScreen | playing / done; "Continue" enables at 100% |
| 7 | QuizScreen | per-question / results (passed: continue, failed: retry) |
| 8 | ReflectionScreen | writing; submission gated on length + sentence + unique-word checks |
| 9 | CompleteScreen | terminal celebration after parent approves → "Back to home" |
| 10 | ScreenTimeFinishedScreen | terminal: minutes pool drained |
| 11 | DailyCompleteScreen | celebration: all tasks newly completed |

---

## 4. State Model

```swift
@Observable
final class BigKidState {
    // Mirrored from GET /child/state on every poll — these fields are server-authoritative.
    var childName: String
    var minutesLeft: Int
    var minutesMax: Int                          // 120 in v1
    var tasks: [BigKidTask]
    var reflectionRequest: ReflectionRequest?    // nil if no active reflection
    var notifyParentCooldownEndsAt: Date?        // server-tracked; nil if not in cooldown
    var dailyCompleteAcknowledged: Bool          // for today's local date, per §8.8
    var screenTimeFinishedAcknowledged: Bool     // for today's local date, per §8.9

    // Local-only — UI navigation, never sent to server.
    var currentTaskId: UUID?

    // Derived
    var allTasksDone: Bool {
        // A task counts as done if evidence was approved OR bypass was approved.
        tasks.allSatisfy { $0.status == .done || $0.bypass?.status == .approved }
    }
}

struct BigKidTask {
    let id: UUID
    let title: String
    let description: String
    let category: TaskCategory     // .chores | .homework | .selfCare
    let due: String?               // human-readable, server-formatted
    var status: TaskStatus         // .todo | .submitted | .done | .overdue
    var phase: TaskPhase           // .input | .submitted | .redo
    var redoReason: String?
    var bypass: BypassRequest?
}

struct ReflectionRequest {
    let id: UUID
    let reason: String                       // parent's reason
    let videoId: String                      // resolved by Gemini → YouTube
    let videoTitle: String
    let quiz: [QuizQuestion]                 // 5 questions
    let writingPrompt: String

    // Progress — server-authoritative, mirrored to UI for hub rendering
    var stepsCompleted: Set<ReflectionStepId>  // subset of {video, quiz, writing}
    var quizScore: Int?                        // set when quiz step completes (0…5)
    var essayText: String?                     // set when writing step completes

    // Lifecycle
    var status: ReflectionStatus             // .pending | .submitted | .approved
    var parentNote: String?                  // attached on approval
    var submittedAt: Date?
    var approvedAt: Date?
}

struct QuizQuestion {
    let q: String
    let options: [String]          // 4 options
    // correctIndex stays server-side
}

struct BypassRequest {
    let id: UUID
    let taskId: UUID
    let reason: String
    var status: BypassStatus       // .pending | .approved | .denied | .withdrawn
    var parentResponse: String?
}
```

---

## 5. Routing Logic

Root view selects which top-level screen to show based on state, in this priority order. **All conditions reference fields defined in §4 (BigKidState / ReflectionRequest) and returned by §8.1 (`GET /child/state`); no client-only flags participate in routing.**

```
1. reflectionRequest != nil && reflectionRequest.status == .approved
     → CompleteScreen
2. reflectionRequest != nil
     → HomeReflection
       sub-state: stepsCompleted.count < 3   → State A ("Start Reflection")
                  stepsCompleted.count == 3  → State B ("waiting for parent")
3. allTasksDone && minutesLeft <= 0 && !screenTimeFinishedAcknowledged
     → ScreenTimeFinishedScreen
4. allTasksDone && !dailyCompleteAcknowledged
     → DailyCompleteScreen
5. otherwise
     → Home
```

**Acknowledgement is implicit, not a client flag.** When the kid taps "Back to home" on CompleteScreen, the client calls `POST /child/reflection/{id}/ack` (§8.7); the server then drops the reflection from `/child/state`, so `reflectionRequest` becomes `nil` on the next poll and condition 1 stops matching. DailyComplete and ScreenTimeFinished use the same pattern via §8.8 / §8.9, which set the corresponding `Acknowledged` boolean server-side.

**Why parent approval cannot interrupt mid-step.** Parent approval is gated on `reflectionRequest.status == .submitted`, which is only set when the kid submits the essay (§8.5). The essay is the third and final step; submitting it advances the reflection out of LockedScreen and into HomeReflection State B. By the time the parent reviews and taps approve, no in-flight sub-step exists. Therefore approval surfacing CompleteScreen on the next poll is always a clean transition, never a mid-step interrupt.

**Sub-routing**:
- Home → tap task row → TaskDetail
- TaskDetail (input phase) → tap "I couldn't do this" → Bypass
- HomeReflection State A → tap "Start Reflection" → LockedScreen
- LockedScreen → tap active step → VideoScreen / QuizScreen / ReflectionScreen
- Sub-step screens → on completion → back to LockedScreen with progress updated
- LockedScreen at 3/3 → tap "Unlock my devices" → kid believes they're done → actually transitions back to HomeReflection State B (waiting for parent approval), **not** directly to CompleteScreen
- HomeReflection State B → tap "Give them a nudge" → fires notify-parent action, button enters 5-min cooldown
- (Background) parent approves → next state refresh → reflectionRequest.status = .approved → root routing surfaces CompleteScreen
- CompleteScreen → tap "Back to home" → ack to backend, locks `reflectionRequest = nil` → routing falls through to Home

---

## 6. Three Key Flows

### 6.1 Normal Day Flow (no reflection)

1. Kid opens app → Home (locked-placeholder, "Finish today's tasks to unlock").
2. Kid taps task → TaskDetail → snaps photo → optional note → "Submit for approval".
3. Backend: task.status = .submitted; parent reviews on parent app.
4. Parent approves → next poll: task.status = .done; pip turns green.
5. Repeat for all tasks.
6. **Last task done** → routing surfaces DailyCompleteScreen (one-time, until acknowledged).
7. Kid taps "Continue" → ack → routing surfaces Home (now showing time-hero card with 120 min).
8. Kid uses device; iOS DeviceActivity threshold events report consumption; backend decrements `minutesLeft`.
9. **`minutesLeft` hits 0** → routing surfaces ScreenTimeFinishedScreen (one-time, until acknowledged).
10. Kid taps "(demo: back to home)" / future "OK" → ack → Home shows out-of-time card.

**Redo branch**: parent can reject evidence → task.phase = .redo, task.status reverts to .todo with redoReason → kid sees redo state in TaskDetail → taps "Try again" → back to input phase.

### 6.2 Reflection Flow (parent triggers consequence)

**Trigger**: parent app sends `POST /parent/reflection/trigger {childId, reason}` → backend asks Gemini for video query / 5 quiz questions / writing prompt → resolves YouTube videoId → creates ReflectionRequest{status: .pending}.

**Kid side**:

1. Next `/child/state` poll returns `reflectionRequest != nil` → routing surfaces **HomeReflection State A** (brown palette, "Finish Reflection to unlock phone", "Start Reflection" button).
2. Tap "Start Reflection" → **LockedScreen** (hub showing 3 steps, all locked except step 1).
3. Tap step 1 → **VideoScreen** (YouTube embed forced full-watch, no skip; "Watch the whole video — no skipping" caption). On 100% → "Continue" enables → tap → back to LockedScreen with `video` marked done, step 2 unlocked.
4. Tap step 2 → **QuizScreen** (5 questions, one per screen, radio-style options, "Confirm answer" advances). After 5 → results screen: passed (≥4/5) → "Continue" returns to hub with `quiz` done; failed → "Retry quiz" (state resets, no penalty).
5. Tap step 3 → **ReflectionScreen** (writing prompt + textarea). Submit gated on: ≥3 sentences AND ≥40 chars AND ≥12 unique words. If unique-words check fails on submit, inline "can you add a bit more about how you felt" tip; otherwise → POST essay to backend, state advances.
6. All 3 done → LockedScreen shows "Ready to unlock" + green button "Unlock my devices".
7. Tap "Unlock my devices" → **transition to HomeReflection State B** (NOT CompleteScreen).

**HomeReflection State B (new — divergence from prototype)**:
- Same brown palette as State A, same task list below
- Hero card text:
  - Label chip: "REFLECTION SUBMITTED"
  - Headline: "You finished — nice work."
  - Body: "Your parent will take a look soon. Once they're happy with it, you'll get your screen time back."
- Button: "Give them a nudge"
  - First press: enabled, large brown button (same style as Start Reflection)
  - On press: POST `/child/reflection/{id}/nudge` → starts 5-min local cooldown
  - During cooldown: button disabled, text becomes "Just sent — try again in 4:32" (live countdown using mm:ss)
  - At 0:00: button re-enables
  - Cooldown persists across app relaunches (`notifyParentLastSentAt` is server-synced)

**Parent approves** (via parent-side flow, out of scope here):
- Next `/child/state` poll → `reflectionRequest.status == .approved`, `parentNote` may be present
- Routing immediately surfaces **CompleteScreen**
- CompleteScreen shows "Welcome back" + completion summary card (video watched, quiz score X/5, reflection submitted)
- Tap "Back to home" → POST `/child/reflection/{id}/ack` → backend clears reflection from active state → next poll: `reflectionRequest = nil` → routing falls through to Home (green palette restored).

**Persistence + scenePhase fallback (pre-AAC)**:
- All progress (`consequenceDone`, `quizScore`, `reflectionText`, `notifyParentLastSentAt`) lives server-side; client just renders.
- If kid backgrounds the app or locks screen during a reflection step, the in-flight step (Video / Quiz / ReflectionScreen) resets to its starting state on next foreground (LockedScreen progress is preserved; only the in-flight sub-screen resets). This is the soft fallback before AAC.
- AAC integration (v1.1, post-entitlement): wraps Video + Quiz + ReflectionScreen in `AEAssessmentSession`; LockedScreen and HomeReflection State B are outside the session so kid can leave to home freely there.

### 6.3 Bypass Flow (parallel to task)

1. Kid in TaskDetail (input phase) → tap "I couldn't do this" → **BypassScreen** (form).
2. Kid types reason → "Send to parent" → POST `/child/bypass` → BypassRequest{status: .pending} → screen swaps to "sent" state ("Your parent has been notified") → tap "Back to home" returns to Home.
3. Bypass is **non-blocking**: kid can still open the same task and submit photo evidence normally.
4. **If kid later submits evidence on the same task**: backend marks the pending bypass as `withdrawn` automatically (see §8.5). Task proceeds through normal submitted → done flow.
5. **If parent responds first**:
   - Approved: backend marks task.status = .done with no evidence; bypass.status = .approved; kid sees task as Done on home next poll.
   - Denied: bypass.status = .denied (with optional parentResponse); task remains in .todo; kid keeps doing the task (no UI block, but task pip stays empty).

The kid never sees a "bypass pending" surface in v1; the bypass exits silently (approved → task done; denied → no change; withdrawn → no change). Future v1.1 may surface "your parent said no" or similar; out of scope here.

---

## 7. iOS File Structure

All new code under `Evlin iOS/Views/Child/BigKid/` plus shared models / services.

```
Evlin iOS/
├─ Views/Child/BigKid/
│  ├─ BigKidRootView.swift             # routing logic from §5
│  ├─ BigKidHomeView.swift             # Home (variant A initially)
│  ├─ BigKidHomeReflectionView.swift   # HomeReflection (State A + B)
│  ├─ BigKidTaskDetailView.swift       # 3 phases
│  ├─ BigKidBypassView.swift           # form + sent
│  ├─ BigKidScreenTimeFinishedView.swift
│  ├─ BigKidDailyCompleteView.swift
│  └─ Reflection/
│     ├─ BigKidLockedView.swift        # reflection hub
│     ├─ BigKidVideoView.swift         # YouTube embed, no-skip
│     ├─ BigKidQuizView.swift          # 5-q + results
│     ├─ BigKidWritingView.swift       # textarea + checks
│     └─ BigKidCompleteView.swift      # post-approval celebration
├─ DesignSystem/
│  └─ EvlinKidColors.swift             # NEW: green-only kid palette from theme.jsx
│                                      # (separate from parent's navy palette)
├─ Models/
│  ├─ BigKidState.swift                # @Observable model from §4
│  ├─ BigKidTask.swift
│  ├─ ReflectionRequest.swift
│  └─ BypassRequest.swift
└─ Services/
   ├─ BigKidAPIClient.swift            # /child/* endpoints
   └─ BigKidStatePoller.swift          # foreground + 60s polling loop
```

`EvlinKidColors` lives **alongside** existing `EvlinColors` (parent palette), not replacing it — child mode is visually independent.

---

## 8. Backend API Surface

Conventions:
- All `/child/*` endpoints require child auth token (see §9).
- All `/parent/*` endpoints require parent auth token; not consumed by this spec but listed for completeness.
- All times ISO 8601 UTC; client formats locally.
- Polling cadence: 60s while app foregrounded, immediate on resume.

### 8.1 `GET /api/v1/child/state`

Aggregated read. Returns everything the routing layer needs.

```json
{
  "childName": "Liam",
  "minutesLeft": 47,
  "minutesMax": 120,
  "tasks": [
    {
      "id": "uuid",
      "title": "Make bed",
      "description": "...",
      "category": "Chores",
      "due": "8:00 AM",
      "status": "todo",
      "phase": "input",
      "redoReason": null,
      "bypass": null
    }
  ],
  "reflectionRequest": null,
  "notifyParentCooldownEndsAt": null,
  "dailyCompleteAcknowledged": false,
  "screenTimeFinishedAcknowledged": false
}
```

When a reflection is active, `reflectionRequest` is populated with full content (videoId, quiz array sans correctIndex, writingPrompt, status, parentNote).

### 8.2 `POST /api/v1/child/task/{id}/evidence`

Submit photo + optional note. Request: multipart with `photo` (image/jpeg) + `note` (string). Backend stores photo, sets `task.status = .submitted`, marks any pending BypassRequest for this task as `withdrawn`. Response: updated task object.

### 8.3 `POST /api/v1/child/bypass`

Body: `{taskId, reason}`. Creates BypassRequest{status: .pending}. Response: created BypassRequest.

### 8.4 `POST /api/v1/child/reflection/{id}/quiz-answer`

Body: `{questionIndex, selectedIndex}`. Backend verifies, returns `{correct: Bool, allCorrect: Bool, score: Int}`. Client uses for results screen.

### 8.5 `POST /api/v1/child/reflection/{id}/essay`

Body: `{text}`. Backend stores essay, sets `reflectionRequest.status = .submitted`. Response: updated request.

### 8.6 `POST /api/v1/child/reflection/{id}/nudge`

Empty body. Sends nudge to parent (chat message or notification, parent-side spec). Sets `notifyParentCooldownEndsAt = now + 5 minutes`. Returns new cooldown timestamp. Idempotent within cooldown window (returns existing timestamp without re-sending).

### 8.7 `POST /api/v1/child/reflection/{id}/ack`

Empty body. Called when kid taps "Back to home" on CompleteScreen. Backend clears the reflection from active state (`reflectionRequest = null` on next `/child/state`). Idempotent.

### 8.8 `POST /api/v1/child/daily-complete/ack`

Empty body. Called when kid taps "Continue" on DailyCompleteScreen. Sets `dailyCompleteAcknowledged = true` for today. Idempotent.

### 8.9 `POST /api/v1/child/screen-time-finished/ack`

Empty body. Sets `screenTimeFinishedAcknowledged = true` for today. Idempotent.

### 8.10 `POST /api/v1/child/time-consumption`

Body: `{minutesUsed: Int}`. Reported by iOS DeviceActivity threshold events every 5 minutes during free-time use. Backend decrements `minutesLeft`. If `minutesLeft <= 0`, set `minutesLeft = 0` (no negative).

### 8.11 Parent-side (out of scope, listed for backend reference)

- `POST /api/v1/parent/reflection/trigger` — body `{childId, reason}`; backend Gemini-generates content
- `GET /api/v1/parent/reflections/pending` — list submitted essays awaiting review
- `POST /api/v1/parent/reflection/{id}/approve` — body `{parentNote?}`; sets status .approved
- `GET /api/v1/parent/bypasses/pending`
- `POST /api/v1/parent/bypass/{id}/respond` — body `{decision: approve|deny, message?}`
- `POST /api/v1/parent/task/{id}/review` — body `{decision: approve|redo, redoReason?}`

---

## 9. Auth & Pairing

Sustains existing pairing model. Each child device has a stable child token; backend enforces:
- `/child/*` endpoints require child token
- Child token can only access its own resources (parent-bound child id)

No changes to pairing flow in scope here; the device is assumed already paired.

---

## 10. Gemini Integration (server-side)

When `/parent/reflection/trigger` is invoked, backend constructs a single Gemini call:

> "For an 8–12 year old, generate reflection content for this issue: `{reason}`. Output JSON with three keys:
> - `videoQuery`: a YouTube search query for an age-appropriate educational video on the underlying topic (1 sentence)
> - `quiz`: an array of 5 multiple-choice questions, each with `q`, `options` (4 strings), and `correctIndex` (0–3). Questions should test understanding of the topic, not memorization of the video.
> - `writingPrompt`: a 1–2 sentence prompt asking the kid to reflect on their behavior and what they could do differently."

Backend then:
1. Calls YouTube Data API with `videoQuery`, takes first result's `videoId` and `title`.
2. Persists ReflectionRequest with full content.
3. Returns success to parent.

Failure modes (Gemini error / YouTube no result) → return error to parent so they can retry; do not create a half-formed ReflectionRequest.

---

## 11. Divergences from JSX Prototype

These are intentional and must be implemented as specified, overriding what the JSX shows:

1. **HomeReflection has a State B** (waiting for parent approval). Not in prototype. See §6.2 + §3 for copy and behavior.
2. **Reflection requires parent approval** before CompleteScreen appears. Prototype self-completes via unique-word heuristic; iOS version routes to State B and waits for backend `status == .approved`.
3. **Bypass auto-withdraws** when evidence is submitted on the same task. Prototype has no such linkage.
4. **No mascot rendering**. Prototype defines `EvlinMascot()` returning null; do not invent.
5. **Time consumption is real, not simulated**. Prototype increments via local timers; iOS uses DeviceActivity threshold events.
6. **Quiz `correctIndex` is server-side only**. Prototype embeds it in the JS bundle; iOS receives questions without it and posts answers for verification.
7. **dev-tool buttons** (e.g. "(demo: simulate redo request)", "(demo: back to home)") are not implemented in iOS.

---

## 12. Out of Scope (v1)

Tracked for future plans:
- **AAC integration** — wrap Video / Quiz / Writing in `AEAssessmentSession` once Apple approves the entitlement (filed; ETA 2–6 weeks).
- **Push notifications** — APNs for reflection nudges, parent decisions; v1 is polling-only.
- **Onboarding** — separate spec; assume child mode is already configured.
- **Mascot illustrations** — when Esen ships final mascot art.
- **Home variant B (circular dial)** — built in JSX but not wired; pick one variant in Phase 1.
- **Offline mode** — no offline UX in v1; show plain error states on network failure.
- **Audit / time-spent analytics** — separate.

---

## 13. Open Questions (resolve before implementation)

1. **Home variant: A or B?** Default = A. Confirm before Phase 2 starts.
2. **Final State B copy.** Draft above is a placeholder; Esen may give exact wording.
3. **Time consumption granularity.** 5-min threshold is a guess; verify against DeviceActivityEvent's minimum threshold (Apple docs say 1 min minimum). Likely fine.
4. **Photo storage.** Where do task evidence photos live (S3? Supabase Storage?)? Backend choice; out of scope here.
5. ~~**What counts as "all tasks done" if a task has bypass approved?**~~ **Resolved**: a task counts as done iff `status == .done` OR `bypass?.status == .approved`. See `BigKidState.allTasksDone` in §4.

---

## 14. Verification

The implementation is correct when:
- Every screen, when placed side-by-side with the corresponding JSX prototype rendered in the brown/green theme, is indistinguishable except for iOS-vs-web rendering quirks (font hinting, scroll bounce). Pixel-level diff is the bar.
- A kid can complete a normal day end-to-end against a real backend.
- A kid can complete a reflection consequence and see the brown HomeReflection State B until a parent approves, after which they see CompleteScreen and revert to green Home.
- A kid can open a bypass, then submit evidence on the same task, and see the bypass silently withdraw (verified by backend log; no kid-facing change).
- The kid cannot bypass a reflection by force-quitting the app and reopening it: progress is preserved server-side, and the in-flight sub-screen resets cleanly on relaunch.
