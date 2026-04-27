# Parent-end redesign — alignment with Esen's HTML prototype

**Date**: 2026-04-27
**Source of truth**: `frontend_for_app_evlin/Evlin_Parent_view/Evlin Parent Dashboard (1).html`
**Audience**: iOS team (this repo) + Android team (separate repo) — both ship from the same prototype.
**Goal**: Bring iOS Parent app to visual + interaction parity with Esen's React HTML prototype. Android will follow the same spec.

---

## Why this exists

Esen embedded the latest design as inline JSX inside the HTML file. The standalone `screen-*.jsx` files in the repo are stale (older versions). All comparisons in this spec reference the **HTML** as the source of truth.

The iOS app currently implements ~60% of what the HTML defines. The remaining ~40% includes the most product-distinctive flows (Task review with photos and bypass, Profile add-everything flow, Calendar multi-column). This spec catalogs all gaps for systematic implementation.

## Visual fidelity standard

Match looks-and-feel — same as the level already achieved on Phases done previously. Concretely:

- Match layout, spacing, color, font sizing
- iOS uses **SF Symbols** for icons (Material Symbols → SF Symbol equivalents). Already proven acceptable.
- iOS uses native primitives (Form, NavigationStack, sheet) where they don't conflict visually
- 1-2 px differences are fine; cross-platform behavioral parity is the bar

## Out of scope (this redesign)

- Student-end (big kid + small kid views) — separate later phase per Esen
- Backend changes (tasks/rules/devices remain client-side mock for now)
- New chat / shield / block functionality (Phase 1-11 already shipped)

---

## Tab-by-tab gap inventory

### Shared UI primitives — already aligned

`GlassmorphicHeader`, `HeaderIconButton`, `EvlinTabBar`, `EvlinCard`, `Toggle`, `EvlinPill`, `EvlinAvatarView`, `EvlinButton`, `SectionHead` all exist on iOS and match the HTML's `GlassHeader` / `BottomNav` / etc. No work needed.

### Tab 1: Home — small gap

The iOS HomeView matches the HTML's ScreenHome closely. Two real gaps:

1. **Notification → task routing** (HTML 240-246): tapping a notification with `kind: 'task'` and `taskId` opens the corresponding child's profile and auto-expands the TaskDetailSheet for that task. iOS NotificationPanel currently only marks-as-read; HomeNotification model has no `kind` / `taskId` fields.

2. **Stale "Evlin observation prompt" card** (iOS HomeView lines 47-82): the HTML removed this card. iOS still has it. Either remove or keep as iOS-specific addition; design sources says remove.

ChildEditSheet (HTML 307) and ScreenSettings (HTML 336) are functionally equivalent on iOS via HomeSettingsSheet. iOS uses native `Form` instead of HTML's custom SGroup/SRow — this is fine, native Form looks correct on iOS.

### Tab 2: Calendar — large structural gap

The iOS CalendarView has the right per-person filter state (`focusPerson`) and supports event detail viewing, but the **default view is fundamentally different**:

| Default state | HTML | iOS |
|---|---|---|
| Timeline columns | **4 columns** (Family, Liam, Maya, Emma each own a column) | 1 column showing all events stacked |
| Tap empty space | Creates new event at that time/person | Nothing |
| `+` FAB | Opens new EventDetailSheet | Empty `Button {} label:` |
| Event detail edit mode | Full edit form (title/time/category/repeat/notes/location/reminder) | Read-only with empty `onEdit` callback |
| Recurring events | `repeat` field per event + `expandedEventsForDay` recurrence engine | No support |
| Custom category creation | "+" button inline in category picker | N/A |

These are all required for parity. Big visual change.

### Tab 3: Profile — largest gap

This is the dominant work. iOS ProfileView shows summary + rules + tasks (with Approve/Redo) + schedule + devices. HTML has all that **plus**:

**Task system upgrade**:
- 6 task states (vs iOS 4): adds `bypass` (parent must allow/deny child's request to skip) and `bypassed` (allowed and crossed out)
- Bypass purple visual identity (`#7C3AED`)
- Tasks gain rich data: `description`, `photo` or `photos[]` (multi), `note`, `submittedAt`, `dueLabel`, `category`
- Tap any task row → opens **TaskDetailSheet** (full screen):
  - Header with child kicker
  - Status banner (5 colors: review orange / bypass purple / overdue red / done green / bypassed grey)
  - "What to do" description block
  - "{child}'s submission" section: photo gallery (1/3 thumbnails, lightbox-style nav) OR "Waiting for photo" / "No photo submitted" empty state
  - "{child}'s note" or "Why {child} can't do it" block (different framing for bypass)
  - Action buttons depend on state:
    - review → Approve submission / Request redo
    - bypass → Allow bypass (purple) / Deny — keep as task
    - pending/overdue → Mark as complete
    - done → "You approved this task" status
    - bypassed → Block icon + struck-through title
  - Edit task (... menu top-right) opens EditTaskForm

**Profile layout**:
- Header right "..." menu → Edit Profile / Delete Profile (with confirm dialog)
- Big Lock/Unlock button under summary card (red lock / green lock-open, toggles child status)
- Devices section is **collapsible** with chevron
- Rules section is **collapsible** with chevron + per-rule edit pencil
- Floating "+" FAB → AddBottomSheet
- AddBottomSheet → AddMenu (4 options: Add Task / Calendar / Rule / Device)

**Add forms** (each fires from AddBottomSheet):
- AddTaskForm: title / category pills (Chore/Homework/Reading/Routine) / description textarea / due
- EditTaskForm: same + Delete button
- AddRuleForm: title / detail / icon picker (7 SF symbols) / tone (Primary/Calm/Neutral)
- EditRuleForm: same + Delete
- AddCalendarForm: title / time range / category / repeat
- AddDeviceForm: device type 6-grid / name / notes

**Device tap → DeviceAppsSheet** (per-app management):
- Per-app row: app icon + name + Toggle + limit pill (e.g. "1h") + progress bar of used/limit
- Tap limit pill → expand inline limit picker (15/20/30/45/60/90/120 min)
- Color of progress bar: green normal / orange >75% / red over-limit
- "Limit off" state when toggle is off
- APP_DATA pre-filled per child (4-5 apps each)

This is approximately **10 new SwiftUI views/sheets/forms** just for Profile.

### Tab 4: Chat (Evlin) — already exceeds prototype

iOS ChatViewModel + 17 confirmation cards + receipt loop is far beyond the HTML's static mock. No work needed in this tab.

### Tab 5: Library — small gap

Structure is aligned (Trending Reels / Trending Lessons / Topic Categories / CategoryDetail). Real gaps:

1. Tap Reel / Lesson / Article → currently no destination on either side; both stub. Design says cursor:pointer everywhere → user expects video player + article reader. **Do**: add modal video player view + article reader view; for MVP can be stubbed with "Coming soon" message.
2. Header search / bookmark buttons stub on both sides.
3. CATEGORY_CONTENT depth: HTML has 6 items per category × 4 categories = 24. iOS LibraryMockData has 17. Fill in the gap.

### Tab 6: Insights — small gap

Structure aligned. Real gaps:

1. "Review strategy" hero button — stub
2. "Apply" button on each Recommendation — stub
3. Daily app usage 3 brand SVG logos (YouTube/Roblox/TikTok) — iOS uses SF Symbols. Acceptable substitution.

### App-level

- HTML has a NotificationBanner (top of screen, auto-dismisses in 5s, fired by dev button "Liam finished homework"). iOS doesn't have this banner system. Should add for product completeness — when a notification arrives in foreground, show banner.
- Profile route accepts `taskId` for deep-linking from notifications. iOS routing doesn't currently support this. Add.

---

## Implementation phases (high-level)

The plan that follows this spec is organized as 12 phases:

1. **Models foundation** — TaskItem upgrade, BypassPurple, ProfileMockData rich tasks
2. **TaskDetailSheet** — the central new view, the 2 screenshots Liam showed
3. **TaskRow upgrade + Notification routing** — the Profile-side rendering and the deep-link
4. **Profile layout** — Lock/Unlock button, collapsible sections, ... menu, FAB hookup
5. **AddBottomSheet + AddMenu + form primitives** — the foundation for all 6 forms
6. **AddTaskForm + EditTaskForm**
7. **AddRuleForm + EditRuleForm**
8. **AddCalendarForm**
9. **AddDeviceForm + DeviceAppsSheet**
10. **Calendar multi-column timeline** (visual major change)
11. **Calendar FAB + EventDetailSheet edit/new mode + repeat field**
12. **P1 polish** — Library taps, Insights buttons, NotificationBanner

Each phase produces working, testable software. Phases can be executed sequentially or some in parallel (e.g. 6/7/8/9 are independent forms once 5 is done).

## Decision: visual standard

Match Esen's HTML pixel-near. iOS-native idioms (sheet presentation, navigation gestures, native Toggle, native context menus where applicable) are preferred over JS-style imitations when behaviorally equivalent. SF Symbols substitute for Material Symbols. EvlinTokens already match the HTML's color palette.

## Open questions (none blocking)

These can be resolved during implementation without delaying the plan:

- iOS Settings: keep native Form (current) or rebuild as SGroup/SRow custom? Recommend keep native.
- Library video/article taps: full player or stub for now? Recommend stub with "Coming soon" agent message until content pipeline exists.
- Multi-child task selection in D4 of chat (separate concern, not Parent UI).
