# iOS UI Rebuild — Parity with Esen's React Prototype

**Date:** 2026-04-21
**Repo:** `Evlin iOS/`
**Reference:** `frontend_for_app_evlin/` (Esen's React prototype, `python3 -m http.server 3333`)
**Branch policy:** Main branch, one-shot rewrite; in-progress commits acceptable.
**Preservation rule:** Never delete a file unless strictly necessary. Prefer rewrites over deletions.

---

## 1. Goal

Rebuild the iOS parent-mode UI so that, opened side-by-side, the 6 main screens match Esen's React prototype in layout, data, hierarchy, and primary interactions.

Out of scope for this spec: iOS extension signing, FamilyControls Distribution approval, custom font file bundling, new backend schemas, MDM.

---

## 2. Scope

**In scope (rebuild):**
- Parent-mode routing (after SetupView chooses "parent")
- Home tab dashboard
- Profile sub-screen (reached by tapping a child card on Home)
- Calendar tab (24-hour timeline with multi-child rails)
- Evlin (Chat) tab — style-only refinements; existing Gemini wiring preserved
- Library tab (Trending Reels / Lessons / Categories + CategoryDetail overlay)
- Insights tab — replaced with AI-analysis editorial layout per Esen
- Shared components: TabBar (flatten), GlassHeader (extend), per-child ProfileCard, StrategyCard, ObservationBubble, ReelCard, LessonCard, TaskRow, RuleRow, DeviceRow, ChildFilterPills
- Design tokens (colors) aligned to Esen's `tokens.js`
- Mock data aligned to Esen's `EvlinFamily` (Liam / Maya / Emma)

**Preserved, not touched:**
- `Views/Onboarding/OnboardingView.swift` — 4-step permissions walkthrough
- `Views/Onboarding/SetupView.swift` — parent/child mode picker
- `Views/Child/ChildModeView.swift` — child-device polling
- `Views/SettingsView.swift` — the existing gear-icon settings (server URL / child name / app picker). The new design's "Settings sheet" on Home is additive (family management), not a replacement.
- `Services/ScreenTimeManager.swift` — FamilyControls wiring
- `Services/APIClient.swift` — backend client
- `Views/Chat/ChatViewModel.swift` — chat state + Gemini wiring
- `Models/ChatModels.swift`
- All existing chat card components (`AgentReasoningCard`, `LockConfirmationCard`, `SafetyStatusCard`, `VideoRecommendationCard`, `InterventionBriefingCard`, `ChatBubble`, `ChatInputBar`, `QuickPromptChip`, `SafariWebView`, `YouTubePlayerView`) — reused as-is or lightly re-skinned; not deleted.
- `Views/ProfilePicker/ProfilePickerView.swift` — kept on disk, unwired from ContentView. Explanatory comment added at top noting it is replaced by HomeView's dashboard entry but preserved for reference.
- `EvlinDeviceActivityMonitor/*` — extension code unchanged.

**Deletions:** none.

---

## 3. Design Token Migration

Update `DesignSystem/EvlinColors.swift` with the following changes. All other tokens (primary, tertiary, error, spacing, radius) unchanged.

| Token | Old | New | Reason |
|---|---|---|---|
| `evSurface` | `#F9F9FD` | `#FCFCFD` | Esen's `tokens.color.surface` |
| `evSecondary` | `#1B6D24` | `#2E7D32` | Slightly lighter forest green |
| `evSecondaryContainer` | `#A0F399` | `#E8F5E9` | Pale container green for pills |
| `evOutlineVariant` | `#C4C6CD` | `#E2E4E9` | Softer divider tone |
| `evOnSurfaceVariant` | `#44474C` | `#5A5E66` | Slightly lighter secondary text |

Additions:

```swift
static let evChildLiam  = Color(hex: 0x2563EB)  // calm blue
static let evChildMaya  = Color(hex: 0x2E7D32)  // forest green
static let evChildEmma  = Color(hex: 0xEF6C00)  // amber
```

Plus a shadow helper namespace:

```swift
enum EvlinShadow {
    static let premium = Shadow(color: .black.opacity(0.04), radius: 30, x: 0, y: 10)
    static let premiumHover = Shadow(color: .black.opacity(0.08), radius: 40, x: 0, y: 20)
    static let ambient = Shadow(color: Color(hex: 0x191C1E).opacity(0.06), radius: 32, x: 0, y: 12)
}
```

*(If SwiftUI Shadow type not available in target iOS, expand inline on each use.)*

**Expected visual drift on preserved screens** (OnboardingView, SetupView, ChildModeView, existing SettingsView): secondary text slightly lighter, dividers slightly softer, surface slightly warmer. Acceptable; no rework needed.

---

## 4. Data Model Updates

### `Models/ChildProfile.swift`

Replace the existing mock data. Struct shape extended to match Esen's richer fields.

```swift
struct ChildProfile: Identifiable, Hashable {
    enum Status: String { case unlocked, locked }

    let id: String              // "liam" / "maya" / "emma"
    let name: String
    let age: Int
    let avatarURL: String?      // nil → fall back to initial letter
    let accentColor: Color
    let status: Status
    let timeLeft: String        // "1h 30m"
    let timePct: Double         // 0.0 ... 1.0
    let subtitle: String
}
```

Mock data mirrors `frontend_for_app_evlin/tokens.js` exactly:

- **Liam** — 12, blue accent, unlocked, `1h 30m` left, 75%, subtitle `"Focused today · 3 of 5 tasks done"`
- **Maya** — 8, green accent, unlocked, `45m` left, 38%, subtitle `"On bedtime wind-down in 2h"`
- **Emma** — 6, amber accent, locked, `0m`, 0%, subtitle `"Quiet time · unlocks at 4:00 PM"`

Avatar URLs copied verbatim from Esen's tokens.js (Google-hosted URLs + pravatar).

### New `@AppStorage("parentName", default: "Morgan")`

Consumed by HomeView's greeting: `"\(greeting), \(parentName)"` where greeting depends on current hour.

---

## 5. File Plan

### Rewritten (keep filename; body replaced)

- `Views/Home/HomeView.swift` — dashboard (greeting header, ChildFilterPills implicit via section, ProfileCard list, Evlin observation prompt card, notifications/settings entries in header)
- `Views/Calendar/CalendarView.swift` — 24-h timeline; day nav; multi-child rails; focus-person filter; EventDetailSheet
- `Views/Library/LibraryView.swift` — Trending Reels strip / Trending Lessons list / Topic Categories 2×2 grid
- `Views/Insights/InsightsView.swift` — ChildFilterPills, AI-analysis navy hero, Strategic Recommendations list, breakdown section if present in Esen's file
- `Components/EvlinTabBar.swift` — flatten: 5 equal tabs, remove FAB / lifted Evlin button; selection indicator capsule preserved
- `Components/GlassmorphicHeader.swift` — extend API: `title`, `kicker` (small uppercase label above title), `onBack` (if set, render back chevron on the left), `trailing` (view slot for right-side icons)
- `DesignSystem/EvlinColors.swift` — per section 3
- `Models/ChildProfile.swift` — per section 4
- `ContentView.swift` — parentRoot routing: 5-tab; Home push → ProfileView; tab body no longer wraps GlassmorphicHeader (each screen now owns its own header variant)

### New files

- `Views/Home/HomeView.swift` (new `ProfileCard` component inlined or split out — see below)
- `Views/Home/NotificationPanel.swift` — `.fullScreenCover` overlay with mock notifications list, mark-all-read, swipe-to-dismiss
- `Views/Home/HomeSettingsSheet.swift` — iOS-style form for managing the mock family (add / edit / delete children in memory); persistence stubbed
- `Views/Profile/ProfileView.swift` — child detail (summary header, Active Rules, Tasks, Today's Schedule snippet, Device Permissions)
- `Views/Calendar/MonthPickerSheet.swift`
- `Views/Calendar/EventDetailSheet.swift` — read-only first pass (inline edit deferred)
- `Views/Library/CategoryDetailView.swift` — push-navigated detail with featured video hero + 2-col mixed video/article grid
- `Components/ProfileCard.swift` — Home list item; avatar + status pill + progress bar + subtitle + chevron
- `Components/StrategyCard.swift` — dark richly formatted chat artifact (title, category breadcrumb, mini video pill, tip body, action row)
- `Components/ObservationBubble.swift` — agent plain-text bubble; distinct from user bubble
- `Components/ReelCard.swift` — 9:13 vertical portrait card with gradient bg + play glyph + author kicker + title
- `Components/LessonCard.swift` — horizontal card with thumb + title + meta
- `Components/TaskRow.swift` — icon + title + state pill + approve/redo actions
- `Components/RuleRow.swift` — icon + title + detail + Toggle
- `Components/DeviceRow.swift` — icon + name + detail + lock glyph
- `Components/ChildFilterPills.swift` — horizontal scroll of child pills with accent dot; selected = primary fill

Total new files: ~14.

### Unchanged (explicit)

All files listed under section 2 "Preserved" remain untouched. `ProfilePickerView.swift` retained on disk with a top-of-file comment:

```swift
// Retained for reference only. Replaced by HomeView's dashboard, which handles
// child profile selection as part of the main parent flow. Not wired into
// ContentView routing.
```

---

## 6. Screen Specifications

### 6.1 Home

- Header: `GlassmorphicHeader(title: "", kicker: "Good morning, Morgan", trailing: { notifications + settings })`. Greeting uses current-hour branch (morning/afternoon/evening).
- Body (centered vertically for a single-phone viewport):
  - `SectionHead("Children", kicker: "Select a profile")`
  - Vertical `ForEach(children)` → `ProfileCard`. Tap → push `ProfileView(childId:)`.
  - `Evlin observation prompt card` — dark-bordered row with `graph_4`-equivalent SF Symbol, title `"Evlin has 3 observations for you"`, subtitle `"Incl. one late-night gaming pattern · Liam"`, chevron. Tap → switch to Evlin tab (not push).
- Notification bell opens `NotificationPanel` via `.fullScreenCover`.
- Settings gear opens `HomeSettingsSheet` via `.fullScreenCover`.

### 6.2 Profile

- Header: `title: "\(child.name)'s Space"`, `onBack` → pop, `trailing: { more_horiz }`.
- Sections (each preceded by `SectionHead`):
  - Child summary card (avatar + name + status pill with ping animation when unlocked + progress bar + timeLeft label)
  - Active Rules — 3 hardcoded `RuleRow` (screen time / bedtime / chores) with `Toggle` bindings
  - Tasks — 4 hardcoded `TaskRow` (done / review / pending / overdue)
  - Today's Schedule — simple list of 3 events (times + titles), tap → switch to Calendar tab (not deep-linking the specific event; that's deferred)
  - Device Permissions — list of app names + locked glyph
- All state is local `@State`; no persistence.

### 6.3 Calendar

- Header: `title: "Schedule"`, trailing: focus-person filter button + today-jump.
- Day nav bar: left chevron / date button (opens MonthPickerSheet) / right chevron.
- Timeline: `HOUR_H = 56`, total 24h. `ScrollViewReader` auto-scrolls to first event's Y on selected-day change. Events positioned via `absolutePosition`-equivalent (`.overlay` + `.offset` or a custom layout).
- Multi-child columns rendered as vertical rails; `focusPerson` filters to one rail at a time.
- Event tap → `EventDetailSheet` (read-only in this pass).
- Hardcoded `EVENTS[day]` and `ALL_DAY[day]` dictionaries matching Esen's fixtures for a representative week.

### 6.4 Evlin (Chat)

- Header: `title: "Evlin"`, trailing: `{ task_alt-equivalent, more_horiz }`.
- Initial messages seeded in `ChatViewModel.init()` when history is empty: 3 fixed messages aligned to Esen's `screen-evlin.jsx`:
  1. Agent observation: `"I've confirmed the manual lock on Liam's device. Given his recent focus patterns, he may experience a frustration spike."`
  2. Agent strategy artifact: title `"Real-time De-escalation Strategy"`, status `"Locked"`, category `"Active Monitoring › Immediate Action"`, video `{label: "Managing Transition Frustration", duration: "3:00"}`, tip text.
  3. Agent follow-up: `"Would you like to review the suggested de-escalation steps or watch the briefing video now?"`
- Message types map to existing renderers + new `StrategyCard` / `ObservationBubble`.
- Input bar **remains bottom-pinned** per user decision (Esen's floating placement treated as a prototype-era stylistic choice, not adopted).
- On user send: existing Gemini flow unchanged. Returned text renders as `ObservationBubble`. `action` still triggers ScreenTimeManager.

### 6.5 Library

- Header: `title: "Library"`, trailing: `{ search, bookmark }`.
- Sections:
  - `SectionHead("Trending Reels", right: "60-second insights")` + **Apple Music-style snapping horizontal carousel** of `ReelCard`s (see carousel spec below).
  - `SectionHead("Trending Lessons")` + vertical `LessonCard` list (3 items).
  - `SectionHead("Topic Categories")` + 2×2 grid of `CategoryTile`s (Emotional Intelligence / Digital Boundaries / Conflict Resolution / Growth Mindset).
- Tile tap → push `CategoryDetailView(category:)`. Detail screen renders a featured hero video + 2-col grid mixing video cards and article cards, all hardcoded from Esen's `CATEGORY_CONTENT`.

**Reels carousel implementation spec** (pattern lifted from `~/Desktop/Lync/Lync/Views/ProfileView.swift` lines 226–285):

```swift
@State private var scrolledReelId: Int?

ScrollView(.horizontal, showsIndicators: false) {
    HStack(spacing: 15) {
        ForEach(Array(reels.enumerated()), id: \.offset) { idx, reel in
            ReelCard(reel: reel).id(idx)
        }
    }
    .scrollTargetLayout()
}
.scrollTargetBehavior(.viewAligned)
.scrollPosition(id: $scrolledReelId)
.scrollClipDisabled()
.padding(.horizontal, -20)
.padding(.leading, 20)
.padding(.trailing, 20)
.onChange(of: scrolledReelId) { _, _ in
    UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.5)
}
```

- Cards snap per-view. Each card is 9:13 portrait (≈148×214pt) with gradient background, play glyph, author kicker, title — same visual content as Esen's ReelCard.
- Scroll past last / before first still allowed (clip disabled); padding trick lets peek-of-next work.
- Haptic fires on each snap boundary cross: `UIImpactFeedbackGenerator(style: .light)` at intensity 0.5 — subtle, not distracting.
- iOS 17+ APIs only (`scrollTargetBehavior` / `scrollPosition`). App's min-iOS = 17, safe.

### 6.6 Insights

- Header: `title: "Child Insights"`, `kicker: "Past 7 days"`, trailing: `{ notifications, settings }`.
- Top: `ChildFilterPills` row (All + per-child). Selected state switches which copy is shown in the hero. For first pass, all pills show the same Liam content (filter mechanics wired but content not per-child-differentiated).
- `Evlin AI analysis` hero — navy gradient card, white text: `"Liam's late-night gaming is impacting morning focus."` + `"Analysis shows a 45% increase in Roblox activity after 9:00 PM ..."` + action row (`Review strategy` success button, `Dismiss` ghost button).
- `Strategic Recommendations` section — 3 rows with icon + title + sub + `Apply` button:
  - `timer` — "15-min warning for TikTok" / "Help transition away smoothly"
  - `school` — "Educational YouTube mode" / "Prioritize learning content"
  - `bedtime` — "8:30 PM Digital Sunset" / "Lock all non-essential apps"
- `Daily App Usage` card — `4h` + `32m` composed numbers (48pt / 32pt), segmented stacked bar (Entertainment 135 : Social 65 : Games 45 proportions in primary / secondary / tertiary-fixed-dim), three legend rows below with colored dots + times (Entertainment 2h 15m, Social 1h 05m, Games 45m).
- `Detailed Breakdown` list — 3 app rows (YouTube 1h 15m 68%, Roblox 45m 40%, TikTok 42m 38%) with colored icon tile + name + time + accent-colored progress bar. Icons rendered as colored rounded-square tiles with brand letter / SF Symbol (see section 6.5 existing pattern in the current InsightsView for icon tile approach).
- The current `InsightsView.swift` body is overwritten in place; file itself is preserved.

---

## 7. Interaction Fidelity

### Real interactions implemented
- Tab switching, push/pop navigation
- Home → Profile push
- Home bell → NotificationPanel; Home gear → HomeSettingsSheet
- Notification mark-as-read (tap) and dismiss (swipe or X button)
- Rule `Toggle` (local state)
- Task approve/redo buttons (local state)
- Calendar day forward/back, MonthPickerSheet date selection, focus-person filter, event tap opens EventDetailSheet
- Library category tap pushes CategoryDetailView
- Insights child-pill selection
- Chat send flow to Gemini (unchanged)

### Hardcoded per Esen
- Notifications array (5 items)
- Calendar EVENTS / ALL_DAY by day key (use Esen's fixtures; copy verbatim)
- Profile rules / tasks / events / device-permission list per child
- Library Reels (3), Lessons (3), Categories (4), CategoryContent per category
- Insights hero copy + recommendations copy
- Chat initial 3 messages
- HomeSettingsSheet child list operations are in-memory only; app restart resets to the 3-child default

### Deferred / stubbed
- Custom animations (`pushInRight`, `sheetSlideUp`, `modalCardIn`, `evlinPing`) → rendered as SwiftUI defaults (`.fullScreenCover` default transition, `.sheet` default sheet, simple `.animation(.spring)` for ping). Visual approximation, not pixel-timed replicas.
- EventDetailSheet inline edit mode — read-only first pass
- HomeSettingsSheet child add/edit/delete — UI rendered; no write-back to backend or shared storage
- Custom fonts — system font stack until `.ttf` files land under `Resources/Fonts/`; `.custom("Manrope", ...)` calls unchanged so swapping in real fonts is drop-in
- Per-child content differentiation on Insights — pill toggles selection state but content text is shared in this pass

---

## 8. Risks

- **Main branch unfinished periods.** One-shot rewrite means commits land in rapid succession; any mid-rebuild commit may render the app in a partially broken state. Mitigation: the user will demo from the last clean commit if needed; full rebuild completion signaled by an explicit "rebuild-complete" commit message.
- **AsyncImage failures for Google-hosted avatars.** Mitigation: on load failure, fall back to a circled initial letter on the child's accent color, matching existing `Avatar` component behavior.
- **Animation parity gaps.** SwiftUI defaults for `fullScreenCover` / `sheet` differ from the prototype's CSS cubic-béziers. Accepted deviation.
- **SwiftUI version floors.** `Layout` protocol requires iOS 16+; `@Observable` macros iOS 17+. Memory confirms target min-iOS is 17, so safe.
- **Onboarding / SetupView visual drift.** The new token palette is slightly softer; on these preserved screens, secondary text and dividers shift. Accepted.

---

## 9. Success Criteria

The rebuild is considered complete when:

1. `git grep -l "TODO(esen-parity)"` returns empty (no leftover stub markers in committed code).
2. Running the app on a real device post-onboarding lands on HomeView matching the Home screenshot from Esen's prototype in structure and data (3 children, greeting, Evlin prompt card).
3. Tapping each bottom tab renders the corresponding new screen (no "Coming Soon" placeholders remaining).
4. Tapping a child card on Home pushes a ProfileView that shows rules / tasks / schedule / device sections with the hardcoded data per child.
5. Sending a message in the Evlin tab still reaches Gemini and renders the response (live wiring intact).
6. `xcodebuild -scheme "Evlin iOS" build` succeeds on a clean derived data cache.

---

## 10. Open Questions Resolved

- **Scope fidelity:** core interactions real + non-core hardcoded per Esen.
- **Branching:** main branch, direct replace.
- **Deletions:** none — files retained wherever possible, including `ProfilePickerView.swift`.
- **Chat artifact cards:** reuse existing card-message pattern; add `StrategyCard` + `ObservationBubble` as new variants.
- **Tab bar FAB:** removed. All 5 tabs flat and equal weight.
- **Chat input bar:** bottom-pinned (reject Esen's floating prototype placement).
- **Backend schema:** unchanged. Agent messages rendered via existing `ChatMessage` fields + new artifact types encoded in metadata.
- **Fonts:** system fallback until bundled.

---

## 11. Out of Scope (for this spec)

- Self-reschedule DeviceActivity flows
- Child-device UI changes (ChildModeView unchanged)
- Backend / adaptive-engine schema changes
- FamilyControls extension changes
- Real Apple Distribution sign-off (pending Apple follow-up)
- Supabase / APNs wiring
- Multi-device per child, web dashboard
