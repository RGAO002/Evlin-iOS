# iOS UI — Revision Pass Design

**Date:** 2026-04-21
**Repo:** `Evlin iOS/`
**Baseline:** commit `37dd077` (post full rebuild)
**Reference:** `frontend_for_app_evlin/` React prototype + user-provided screenshots
**Branch:** main (direct)
**Preservation rule:** Never delete existing files.

---

## 1. Goal

Fix 17 specific issues observed after the initial rebuild. Surgical edits to existing files; no new architectural layers.

---

## 2. Issue List & Fixes

### 2.1 App icon has a thin white border
**Current:** `appIcon.png` (646×636) padded to 646×646 with white fill, then scaled to 1024. The 10px vertical pad introduces a visible white band.
**Fix:** Regenerate `AppIcon-1024.png` **without padding** — scale directly from 646×636 → 1024×1024 (1.6% vertical stretch, imperceptible). Flatten alpha via JPEG roundtrip as before. Overwrite existing file.

### 2.2 Tab bar and page background swapped
**Current:** pages use `evSurface` (#FCFCFD, near-white) and tab bar same → flat visual.
**Fix:** Change every screen's root `.background()` to `Color.evSurfaceContainerLow` (`#F7F8FA`, soft gray). Tab bar stays white (`evSurfaceContainerLowest`). Affected files: `HomeView`, `ProfileView`, `CalendarView`, `ChatView`, `LibraryView`, `InsightsView`, `CategoryDetailView`, `NotificationPanel`.

### 2.3 Notifications panel: push from right, not bottom sheet
**Current:** `HomeView` uses `.fullScreenCover(isPresented: $showNotifications)` — default bottom slide-up transition.
**Fix:** Route the Home tab's NavigationStack through a new `HomeRoute` enum with two cases — `.profile(ChildProfile)` and `.notifications`. Bell button appends `.notifications`. `NotificationPanel` uses `GlassmorphicHeader(title: "Notifications", onBack: pop)` and renders inside the NavigationStack push flow (right-to-left slide).

### 2.4 Old Settings content lost; consolidate into HomeSettingsSheet
**Current:** `HomeSettingsSheet` only manages children. The legacy `SettingsView.swift` (299 lines, 7 sections: Connection / Screen Time / Device Status / Chat / Mode / Sign out / App) is no longer reachable.
**Fix:**
- Port every section from `SettingsView.swift` into `HomeSettingsSheet` — in order: **Children** (new, top) → Connection → Screen Time → Device Status → Chat → Mode → About. Section label reads **"Children"** (not "Family").
- Apply `.preferredColorScheme(.light)` to both `HomeSettingsSheet` and the inner `ChildEditSheet`. This eliminates the dark-mode invisible-text bug without changing tokens globally.
- `SettingsView.swift` remains on disk with a top-of-file deprecation comment; unwire it from anywhere still referencing it (if anywhere).

### 2.5a Active Rules: retain Verified pill + per-row edit glyph
**Current:** Each `RuleRow` has `iconTile + title/detail + Toggle`.
**Fix:** Keep "Verified" pill on section head. Each `RuleRow` gets a small **edit glyph** between the text block and the Toggle — `Image(systemName: "square.and.pencil")`, 14pt, `Color.evOnSurfaceVariant`, tap = no-op.

### 2.5b TaskRow redesign (per user screenshot)
Each task is now its **own independent rounded card** with subtle state-tinted backgrounds. Two visually distinct icon styles depending on state:

| State | Icon | Background tint | Text style |
|---|---|---|---|
| done | Filled rounded-10 square (green) + white `checkmark` | white | strikethrough, gray |
| review | Filled rounded-10 square (amber) + white `camera.fill` | amber tint `#FFF9ED` | bold, primary |
| pending | Outlined circle (28pt, gray) — no fill, no icon inside | white | bold, primary |
| overdue | Outlined circle (28pt, red) + red `exclamationmark` inside | rose tint `#FFF5F3` | bold, primary |

Right side:
- done / review / pending: `EvlinPill` (success / warn / neutral) + chevron
- overdue: red **text** "OVERDUE" (no pill bg) + chevron

Review state additionally shows two buttons **below** the main row, within the same card:
- `APPROVE` — green filled (`EvlinButton.success`)
- `REQUEST REDO` — amber outlined (white bg, tertiary border, tertiary text)

Section head: title "Current Tasks" + right slot = green success pill showing `"\(done)/\(total)"` (e.g. `1/4`).

### 2.5c Enrolled Devices renamed + status pills
- Section head title: **"Enrolled Devices"** (was "Device Permissions")
- `DeviceRow` right side: replace the plain lock icon with an `EvlinPill`:
  - unlocked → `EvlinPill(text: "Active", tone: .success, size: .xs)`
  - locked → `EvlinPill(text: "Locked", tone: .danger, size: .xs)`

### 2.5d ProfileCard: 4-line stacked layout
Current layout packs name + UNLOCKED pill on one row. Change to **4 distinct rows**:

```
Line 1:  Liam · age 12              (name heavy, then " · age 12" regular gray)
Line 2:  ● UNLOCKED · 1h 30m left   (green ping dot + green uppercase label)
Line 3:  ━━━━━━━━━━━━━━━━━━━━━━    (progress bar, 5pt)
Line 4:  Focused today · 3 of 5 tasks done   (subtitle, gray)
```

Avatar unchanged on left; chevron unchanged on right.

### 2.6 Calendar & Chat: remove GlassmorphicHeader
- `CalendarView.body` first child is currently `GlassmorphicHeader(title: "Schedule", ...)`. Delete the GlassHeader block. The dayNav bar becomes the first element.
- `ChatView.body` first child is `GlassmorphicHeader(title: "Evlin", ...)`. Delete the block. The ScrollViewReader becomes the first element.

### 2.7 Calendar: today's-events avatar strip + outer card wrap
Reshape CalendarView into Esen's "big white card" pattern:

Page:
- Gray page background (`evSurfaceContainerLow`)
- One big **rounded-24 white card** with `evShadow(.ambient)` filling the screen inside safe area
- Inside that card:
  1. **Top bar** (padding 16): "Today's Events" heavy title + right side three small icon buttons (`chevron.left` / `calendar.badge.clock` / `chevron.right`)
  2. **Avatar row**: grid `TIME_W + 4 equal cols`; left col empty (or "group" button when focus active); the 4 avatar buttons are:
     - **Family events** (purple `#7C6FF7` filled circle with `house.fill` icon) — the "family" bucket
     - **Liam** (real avatar, blue ring)
     - **Maya** (real avatar, green ring)
     - **Emma** (real avatar, amber ring)
     Clicking any avatar toggles that focus (filter timeline to only that person); clicking again clears. Avatar grows +8pt when focused.
  3. **Divider**
  4. **24h timeline** (existing logic, inside the same card's bottom region)

### 2.8 Event tap: custom centered modal (not bottom sheet)
Replace `.sheet(item: $activeEvent)` with an `.overlay` containing:
- Dim backdrop: `Color.black.opacity(0.4).background(.ultraThinMaterial).ignoresSafeArea()` — tap dismisses
- Card: white, `RoundedRectangle 24`, shadow(radius 30 y 10), horizontal inset 16, centered vertically

Card content structure (per user screenshot):

| Row | Left | Center | Right |
|---|---|---|---|
| Header | 44pt dark-navy filled circle + white `checkmark` | `Piano Practice` title + `Today, 10:00 AM – 11:30 AM` subtitle | × close button (32pt gray circle) |
| (divider) | | | |
| Row | `person.crop.circle` icon | child avatar (24pt, accent ring) + name | — |
| Row | `tag` icon | `EvlinPill` with category name (neutral) | — |
| Row | `list.bullet` icon | note text (multi-line) | — |
| Row | `mappin.and.ellipse` icon | location text | — |
| Row | `alarm` icon | "30 minutes before" | **green Toggle** (@State local) |
| Footer | `Close` plain text button (left) | | `✎ Edit` — dark rounded rect filled, white text + pencil icon (right) |

All rows separated by light dividers. Card stays light-mode (no dark-mode variant needed; already on custom overlay).

### 2.9 Calendar FAB — floating "+" button
In `CalendarView`, add `.overlay(alignment: .bottomTrailing)` containing:
```swift
Button {} label: {
    Image(systemName: "plus").font(.system(size: 22, weight: .bold))
        .foregroundStyle(.white)
        .frame(width: 56, height: 56)
        .background(Circle().fill(Color.evPrimary))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
}
.padding(.trailing, 20)
.padding(.bottom, 24)
```
No-op action for now.

### 2.10 Calendar: current-time red indicator
Inside the timeline ZStack, when `Calendar.current.isDateInToday(selectedDate)` is true:
- Compute `y = (hour * 60 + minute) / 60.0 * HOUR_H` from `Date()`
- Render:
  - `Circle().fill(.red).frame(width: 10, height: 10)` on left gutter
  - `Rectangle().fill(.red).frame(height: 1.5)` spanning timeline width
- Use `Timer.publish(every: 60, on: .main, in: .common).autoconnect()` to refresh `@State private var now: Date` every minute

### 2.11 Chat: remove "Strategic Context" reasoning block
In `ChatView.body`'s `ForEach(viewModel.messages)`, delete the entire block:
```swift
if let reasoning = message.reasoning, message.role == .agent {
    AgentReasoningCard(label: "Strategic Context", content: reasoning)
}
```
Keep `AgentReasoningCard.swift` file (preservation rule) — just remove the render.

### 2.12 StrategyCard: full redesign matching screenshot
Rewrite `Components/StrategyCard.swift`. Visual spec:

```
┌─────────────────────────────────────────────┐
│ Real-time De-escalation         ┌ 🔒 LOCKED ┐│   ← title (Manrope 22 heavy)
│ Strategy                        └───────────┘│     + red danger pill with lock icon
│                                              │
│ ACTIVE MONITORING › IMMEDIATE ACTION         │   ← uppercase, tracking 1.6, gray
│                                              │
│ ┌──────────────────────────────────────────┐ │
│ │                                          │ │
│ │              ◯ ▶                         │ │   ← dark navy bg, 160pt tall
│ │                                          │ │     white translucent play circle
│ │    Managing Transition Frustration       │ │     title + "3:00 duration" white
│ │    3:00 duration                         │ │     bottom-left
│ └──────────────────────────────────────────┘ │
│                                              │
│ ┌──────────────────────────────────────────┐ │
│ │ ╋ Proactive Tip                          │ │   ← green filled circle + lightbulb
│ │   If a tantrum occurs, use "Planned      │ │   green heavy header
│ │   Ignoring". I've prepared a 30-second   │ │   body in darker green/onSurface
│ │   refresher for you.                     │ │   pale green bg, rounded-12
│ └──────────────────────────────────────────┘ │
│                                              │
│ ┌──────────────┐  ┌──────────────────────┐  │
│ │ ▶ WATCH VIDEO│  │ ⤴ REVIEW STRATEGY    │  │   ← navy filled | white outlined
│ └──────────────┘  └──────────────────────┘  │     both rounded-14, equal weight
└─────────────────────────────────────────────┘
   card: white bg, rounded-20, outlineVariant border, evShadow.premium
```

Data structure `StrategyCardData` unchanged; styling fully rewritten. Both buttons are no-op.

### 2.13 ChatInputBar: new lightning + send button
Modify `Components/ChatInputBar.swift`:
- Left icon: `Image(systemName: "bolt")` — unfilled (no `.fill` suffix) — `.foregroundStyle(Color.evSecondary)` — size 16pt regular
- Placeholder: `"Ask about the strategy..."` (was some variant; unify)
- Right **send button**: replace existing circle with **rounded-12 square** (40×40), dark navy fill, white `arrow.up` icon
  ```swift
  Button { onSend() } label: {
      Image(systemName: "arrow.up")
          .font(.system(size: 16, weight: .bold))
          .foregroundStyle(.white)
          .frame(width: 40, height: 40)
          .background(RoundedRectangle(cornerRadius: 12).fill(Color.evPrimary))
  }
  ```

### 2.14 LessonCard redesign (editorial + press-state shadow)
Rewrite `Components/LessonCard.swift` + `LessonItem` struct:

New `LessonItem`:
```swift
struct LessonItem: Identifiable, Hashable {
    let id = UUID()
    let author: String
    let role: String
    let title: String
    let excerpt: String
    let hearts: String
    let comments: Int
}
```

New layout (top to bottom):
1. **Author row**: 28pt circle with author initials (primaryContainer bg) + `name` (Inter 12 bold) + `role` (Inter 10 gray) stacked
2. **Title**: Manrope 17 heavy, primary color, tracking -0.01
3. **Excerpt**: Inter 12, gray, lineSpacing 3
4. **Meta row** (bottom): `♥ 2.4k` · `💬 184` · (spacer) · `READ LESSON →` (uppercase tracking 1.4, primary color)

Card: white bg rounded-20, outline, `evShadow(.premium)` default. On **press** (via `DragGesture(minimumDistance: 0)`), animate to `evShadow(.premiumHover)` + scale 1.01. Release returns to normal.

Mock data (hardcoded per Esen, exactly two entries):
```swift
static let lessons: [LessonItem] = [
    .init(author: "Dr. Julian Vance", role: "Pediatric Neuropsychologist",
          title: "The \"Three-Second\" Pause Method",
          excerpt: "A neuro-scientific approach to de-escalating toddler tantrums before they peak.",
          hearts: "2.4k", comments: 184),
    .init(author: "Elena Rodriguez", role: "Digital Wellness Strategist",
          title: "Digital Sovereignty Protocols",
          excerpt: "Building a child's internal moral compass for digital spaces. Frameworks for the AI era.",
          hearts: "1.1k", comments: 56),
]
```

### 2.15 Topic Categories: push navigation + CategoryDetailView rebuild
- Wrap `LibraryView` body in `NavigationStack`. Use `.navigationDestination(for: CategoryTileInfo.self)`.
- CategoryTile tap: `path.append(category)` instead of setting `selectedCategory` for a sheet.
- Replace `.fullScreenCover(item: $selectedCategory)` with the NavigationStack destination.
- **CategoryDetailView rebuild** per Esen's screen-library.jsx structure:
  - `GlassmorphicHeader(title: category.label, kicker: category.count, onBack: pop)`
  - **FEATURED** kicker (Inter 10 heavy tracking 1.4 gray)
  - Featured video card: 180pt tall, gradient bg matching category, decorative blur circles, central 60pt translucent play button, bottom-right duration pill (black 60% + blur), bottom overlay band (black 25%) with title (Manrope 16 heavy white) + author (Inter 11 white 65%)
  - **ALL CONTENT** kicker
  - 2-col LazyVGrid mixing:
    - **GridVideoCard** — vertical card with gradient thumb + play icon + duration pill + title
    - **GridArticleCard** — vertical card with soft paper texture bg + `doc.text` icon + title + read-minutes
  - Content data from `LibraryMockData.detail(for:)` (existing).

### 2.16 Insights — Daily Usage legend text wraps
Legend items like "Entertainment" wrap inside HStack when squeezed. Fix: wrap the `ForEach` in `ScrollView(.horizontal, showsIndicators: false)` and apply `.fixedSize(horizontal: true, vertical: false)` on each item, so they scroll horizontally instead of wrapping.

### 2.17 Calendar uses real `Date` / `Calendar` (was: hardcoded "Sep 12 = Thu")
Replace hardcoded day-int state with `selectedDate: Date = Date()`.
- Header: `DateFormatter` with format `"EEE, MMM d"` → `"Thu, Sep 25"` (locale-aware)
- Month name for MonthPicker kicker: `DateFormatter("LLLL")` → `"September"`
- Day count for MonthPicker: `Calendar.current.range(of: .day, in: .month, for: selectedDate).count`
- First-weekday offset: use `Calendar.current.component(.weekday, from: firstOfMonth) - firstWeekdayOffset`
- Left/right chevrons: `calendar.date(byAdding: .day, value: ±1, to: selectedDate)`
- Today detection: `Calendar.current.isDateInToday(selectedDate)` — drives red-line visibility
- Event lookup: refactor `CalendarMockData.events` from `[Int: [CalendarEvent]]` (day-int keyed) → `[Int: [CalendarEvent]]` still, but keyed by **days-from-today offset** (`0`, `+7`, etc.). Helper: `static func eventsFor(date: Date) -> [CalendarEvent]` computes the offset from today and looks up.
- MonthPicker selects via `selectedDate` binding; shows current day dot highlight using `isDateInToday`.

---

## 3. Files Affected

**Modify (rewrites or significant edits):**
- `Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` (regenerate)
- `ContentView.swift` (HomeRoute enum, NavigationStack changes)
- `Views/Home/HomeView.swift` (remove .fullScreenCover for notifications; add bell→path append)
- `Views/Home/HomeSettingsSheet.swift` (rewrite with all ported sections + .preferredColorScheme)
- `Views/Home/NotificationPanel.swift` (use GlassmorphicHeader with onBack; adjust signature)
- `Views/Profile/ProfileView.swift` (Enrolled Devices rename, layouts)
- `Views/Calendar/CalendarView.swift` (card wrap, today's events avatars, FAB, red line, real dates, remove GlassHeader)
- `Views/Calendar/EventDetailSheet.swift` → rename to `EventDetailCard.swift` (centered overlay)
- `Views/Calendar/MonthPickerSheet.swift` (real calendar grid)
- `Views/Library/LibraryView.swift` (wrap NavigationStack, replace fullScreenCover with navigationDestination, card background fix)
- `Views/Library/CategoryDetailView.swift` (full rebuild)
- `Views/Insights/InsightsView.swift` (legend scroll fix, root bg)
- `Views/Chat/ChatView.swift` (remove GlassHeader, remove AgentReasoningCard render)
- `Components/TaskRow.swift` (full rewrite per new spec)
- `Components/RuleRow.swift` (add edit glyph)
- `Components/DeviceRow.swift` (add EvlinPill slot)
- `Components/ProfileCard.swift` (4-line stacked layout)
- `Components/StrategyCard.swift` (full rewrite)
- `Components/LessonCard.swift` (full rewrite + new LessonItem shape)
- `Components/ChatInputBar.swift` (lightning icon + square send)
- `Models/LibraryMockData.swift` (new LessonItem shape, update `lessons` to Esen's 2 entries)
- `Models/CalendarMockData.swift` (offset-keyed events; date-based helpers)
- `Models/ProfileMockData.swift` (no change to TaskItem data, but verify tasks array still hits all 4 states — yes)

**Preserve / retain on disk:**
- `Views/SettingsView.swift` (add deprecation comment, contents preserved for reference)
- `Views/ProfilePicker/ProfilePickerView.swift` (already deprecated)
- `Components/AgentReasoningCard.swift` (unused after 2.11, retained)

**Unchanged:**
- All design tokens
- All onboarding / setup / child-mode views
- Service layer
- EvlinTabBar (already per spec)
- GlassmorphicHeader (already per spec)

---

## 4. Success Criteria

1. `xcodebuild` succeeds on clean derived-data.
2. `App-Prefs:` deep links continue to resolve (no accidental breakage).
3. Dark mode applied to OS doesn't break Settings (forced light inside sheet).
4. App icon on home screen shows no visible border.
5. Tab bar is white; screens are gray.
6. Home notifications slide from the right.
7. Calendar header shows today's real date and weekday.
8. Event card is a centered modal with dim backdrop, not a bottom sheet.
9. Floating `+` visible bottom-right on Calendar.
10. Red current-time line visible when viewing today.
11. Chat has no top white header; no "Strategic Context" card; StrategyCard matches screenshot.
12. Lesson cards editorial style; topic category detail pushes in.
13. Insights legend doesn't wrap.

---

## 5. Out of Scope

- Any new features beyond the 17 items.
- FamilyControls entitlement work.
- Font file bundling.
- Backend schema changes.
- Re-architecting routing beyond what's required for items 3 and 15.
