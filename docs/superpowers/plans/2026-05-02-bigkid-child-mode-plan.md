# Big-Kid Child Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the complete child-side iOS UI ("big kid" mode, ages ~8–12) — eleven screens, pixel-perfect to Esen's React/JSX prototype — backed by real FastAPI endpoints, real time-consumption tracking, and Gemini-generated reflection content.

**Architecture:** SwiftUI views under `Views/Child/BigKid/` driven by a single `@Observable BigKidState` that mirrors `GET /child/state`. Routing lives in `BigKidRootView`. All persistent state (task progress, reflection step progress, time pool, bypass status) is server-authoritative; iOS just renders. Bypass and task evidence interact server-side (evidence auto-withdraws pending bypass). Reflection flow is hub-based via `LockedScreen`; after the kid finishes the three sub-steps the kid lands on a new "waiting for parent approval" home variant (HomeReflection State B), and only after the parent approves does CompleteScreen surface.

**Tech Stack:**
- iOS: SwiftUI (iOS 17+), `@Observable`, async/await URLSession, AVKit/WKWebView for YouTube embed, AVFoundation for camera
- Backend: FastAPI + Pydantic + SQLAlchemy async + existing project conventions (`/api/v1/...`)
- AI: Gemini for reflection content generation; YouTube Data API for video lookup
- Storage: Supabase Storage for task evidence photos (existing project convention per `MEMORY.md`)
- Source of truth for visual design: `/Users/fred/Desktop/Evlin/frontend_for_app_evlin/Evlin_Student_View/Evlin_student_view/`

**Reference docs:**
- Spec: `docs/superpowers/specs/2026-05-02-bigkid-child-mode-design.md`
- JSX truth source: `frontend_for_app_evlin/Evlin_Student_View/Evlin_student_view/` (DO NOT MODIFY)
- Existing iOS patterns: `Evlin iOS/Services/APIClient.swift`, `Evlin iOS/DesignSystem/EvlinColors.swift`
- Existing backend patterns: `adaptive-engine/backend/app/api/routes/child_device.py`, `parent_chat.py`

**Key implementation rule:** When porting any screen, open the corresponding JSX file in a side window and copy values verbatim — colors, padding, border radius, font size, font weight, letter spacing, line height, shadow offsets, gradient stops. Do not eyeball, do not interpret, do not "improve". The bar is pixel-level diff.

---

## Phase 0: Resolve Open Questions

Three blockers must be resolved before any implementation begins. These are decision tasks, not coding tasks.

### Task 0.1: Lock Home variant choice (A vs B)

**Files:**
- Modify: `docs/superpowers/specs/2026-05-02-bigkid-child-mode-design.md` (§13 Q1)

- [ ] **Step 1: Render both Home variants in a browser**

```bash
cd "/Users/fred/Desktop/Evlin/frontend_for_app_evlin/Evlin_Student_View/Evlin_student_view"
python3 -m http.server 8001
```

Open `http://localhost:8001/Evlin Student.html`. Compare HomeScreenA (clean) vs HomeScreenB (circular dial).

- [ ] **Step 2: Record decision in spec**

Default per spec is A. If user confirms A, edit §13 Q1 to:

```markdown
1. **Resolved**: Home variant = A (clean, engaging layout). HomeScreenB (circular dial) is built in the JSX prototype but will not be ported in v1; tracked in §12.
```

If user picks B, swap the resolution accordingly.

- [ ] **Step 3: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add docs/superpowers/specs/2026-05-02-bigkid-child-mode-design.md
git commit -m "spec: lock Home variant for big-kid child mode"
```

### Task 0.2: Lock photo evidence storage backend

**Files:**
- Modify: `docs/superpowers/specs/2026-05-02-bigkid-child-mode-design.md` (§13 Q4)

- [ ] **Step 1: Confirm Supabase Storage availability**

```bash
grep -i "supabase" "/Users/fred/Desktop/Evlin/adaptive-engine/backend/requirements.txt" || echo "supabase not yet in backend"
```

If absent, the decision is still "use Supabase Storage" (matches `MEMORY.md` convention) but a backend dependency add is required in Phase 2.

- [ ] **Step 2: Record decision in spec**

Edit §13 Q4 to:

```markdown
4. **Resolved**: Task evidence photos stored in Supabase Storage bucket `evlin-task-evidence`, keyed `{childId}/{taskId}/{timestamp}.jpg`. Public URL persisted on `Task.evidencePhotoURL`. Matches existing project storage convention per MEMORY.md.
```

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-05-02-bigkid-child-mode-design.md
git commit -m "spec: pick Supabase Storage for task evidence photos"
```

### Task 0.3: Source placeholder reflection content for fixtures

**Files:**
- Create: `adaptive-engine/backend/app/fixtures/bigkid_reflection_seed.json`

- [ ] **Step 1: Create fixture file with one realistic reflection**

```json
{
  "id": "00000000-0000-0000-0000-000000000001",
  "reason": "You kept scrolling after time was up today.",
  "videoId": "dQw4w9WgXcQ",
  "videoTitle": "Why rest time matters for your brain (placeholder)",
  "writingPrompt": "What were you feeling when time ran out, and what could you do differently tomorrow?",
  "quiz": [
    {
      "q": "Why does your body need rest time away from screens?",
      "options": [
        "So your eyes and brain can recover and focus better",
        "Because screens run out of battery",
        "So adults can use the TV",
        "It doesn't really matter"
      ],
      "correctIndex": 0
    },
    {
      "q": "What is a healthy thing to do when your screen time ends?",
      "options": [
        "Hide another device under the bed",
        "Find something fun offline — draw, read, go outside",
        "Argue until you get more time",
        "Wait quietly doing nothing"
      ],
      "correctIndex": 1
    },
    {
      "q": "How does not sticking to limits make others feel?",
      "options": [
        "Proud of you",
        "Nothing at all",
        "Worried, because agreements matter",
        "Happy you broke the rule"
      ],
      "correctIndex": 2
    },
    {
      "q": "What is the best way to earn trust back?",
      "options": [
        "Pretend it didn't happen",
        "Keep to the limit and be honest next time",
        "Complain",
        "Change the password"
      ],
      "correctIndex": 1
    },
    {
      "q": "If you feel an urge to keep scrolling, a good move is to...",
      "options": [
        "Just do it anyway",
        "Pause, take three breaths, and pick an offline thing",
        "Hide from a parent",
        "Start a new game"
      ],
      "correctIndex": 1
    }
  ]
}
```

(Content lifted from the JSX prototype `consequence-b.jsx` `QUIZ` array, used as a deterministic fixture before Gemini integration in Phase 9.)

- [ ] **Step 2: Verify the file is valid JSON**

```bash
python3 -m json.tool "/Users/fred/Desktop/Evlin/adaptive-engine/backend/app/fixtures/bigkid_reflection_seed.json" > /dev/null && echo OK
```

Expected: `OK`

- [ ] **Step 3: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/adaptive-engine"
git add backend/app/fixtures/bigkid_reflection_seed.json
git commit -m "feat(backend): add big-kid reflection seed fixture"
```

---

## Phase 1: Design Tokens — `EvlinKidColors`

The kid palette is independent from the parent palette. We add it alongside, not replacing.

### Task 1.1: Create `EvlinKidColors.swift`

**Source of truth:** `frontend_for_app_evlin/Evlin_Student_View/Evlin_student_view/theme.jsx` lines 31–69 (the `EVLIN` const).

**Files:**
- Create: `Evlin iOS/Evlin iOS/DesignSystem/EvlinKidColors.swift`

- [ ] **Step 1: Create the file with the green scale, neutrals, and aliases**

```swift
import SwiftUI

/// Kid-mode palette. Independent from `EvlinColors` (the parent navy palette).
/// Values mirror `Evlin_student_view/theme.jsx` const `EVLIN` exactly.
///
/// Status is encoded by **brightness** within a single green family — three tiers
/// of the same green = three tiers of urgency. Do not introduce new hues.
enum EvlinKidColors {
    // Green scale — 8 steps, light → dark
    static let green50  = Color(hex: 0xF0FAF3)
    static let green100 = Color(hex: 0xDDF3E3)
    static let green200 = Color(hex: 0xBEE6C9)
    static let green300 = Color(hex: 0x93D4A8)
    static let green400 = Color(hex: 0x5FBD7F)
    static let green500 = Color(hex: 0x2AA854)   // PRIMARY
    static let green600 = Color(hex: 0x1F8D43)
    static let green700 = Color(hex: 0x0F5E2B)
    static let green800 = Color(hex: 0x08401C)

    // Brand aliases
    static let primary     = green500
    static let primaryDark = green600
    static let primarySoft = green100
    static let primaryInk  = green700

    // Status aliases (legacy chip API tones — all map back into the green scale)
    static let amber     = green600
    static let amberSoft = green50
    static let red       = green700
    static let redSoft   = green100

    // Neutrals — green-tinted so white + greens read as one family
    static let ink     = Color(hex: 0x0E2417)
    static let ink2    = Color(hex: 0x44584D)
    static let ink3    = Color(hex: 0x7A8A81)
    static let ink4    = Color(hex: 0xC0CEC6)
    static let line    = Color(hex: 0xE4EEE8)
    static let surface  = Color.white
    static let surface2 = Color(hex: 0xF5FAF7)

    // Reflection-active palette (HomeReflection — brown/tan; theme.jsx does not export
    // these as tokens but home-reflection.jsx hardcodes them. Centralize here.)
    enum Reflection {
        static let bgSurface     = Color(hex: 0xF4E8D6)  // background
        static let cardBg        = Color(hex: 0xE4CBA1)  // hero card
        static let cardBorder    = Color(hex: 0xB7935E)  // hero card border
        static let cardAccent    = Color(hex: 0xD4B584)  // decorative dot
        static let iconBg        = Color(hex: 0xB7935E)  // lock icon container
        static let labelText     = Color(hex: 0x4A3215)  // "SCREEN TIME LOCKED"
        static let bodyText      = Color(hex: 0x6E4F26)  // body copy
        static let titleText     = Color(hex: 0x2E1F08)  // hero title
        static let buttonBg      = Color(hex: 0x2E1F08)  // primary CTA
        static let rowBorder     = Color(hex: 0xDDC59B)  // task row border
        static let rowBorderDone = Color(hex: 0xB7935E)
        static let rowBgSubmitted = Color(hex: 0xF4E8D6)
        static let rowBgDone     = Color(hex: 0xF4E8D6)
        static let chipBg        = Color(hex: 0xEAD7B4)
        static let chipFg        = Color(hex: 0x4A3215)
        static let pipDone       = Color(hex: 0x9A7340)
        static let pipSubmitted  = Color(hex: 0xB7935E)
        static let pipTodo       = Color(hex: 0xDDC59B)
        static let checkBg       = Color(hex: 0x9A7340)
    }
}

private extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >>  8) & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
```

- [ ] **Step 2: Verify it compiles**

Open the file in Xcode and build (`Cmd+B`). Expected: build succeeds.

If `Color(hex:)` collides with an existing extension in the project, rename the local one to `init(kidHex:)` and update call sites in this file.

- [ ] **Step 3: Add an Xcode preview swatch grid**

Append to the same file:

```swift
#Preview("Kid colors") {
    ScrollView {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                swatch("green50",  EvlinKidColors.green50)
                swatch("green100", EvlinKidColors.green100)
                swatch("green200", EvlinKidColors.green200)
                swatch("green300", EvlinKidColors.green300)
                swatch("green400", EvlinKidColors.green400)
                swatch("green500 (primary)", EvlinKidColors.green500)
                swatch("green600", EvlinKidColors.green600)
                swatch("green700", EvlinKidColors.green700)
                swatch("green800", EvlinKidColors.green800)
            }
            Divider()
            Group {
                swatch("ink",      EvlinKidColors.ink)
                swatch("ink2",     EvlinKidColors.ink2)
                swatch("ink3",     EvlinKidColors.ink3)
                swatch("ink4",     EvlinKidColors.ink4)
                swatch("line",     EvlinKidColors.line)
                swatch("surface2", EvlinKidColors.surface2)
            }
            Divider()
            Group {
                swatch("Reflection.bgSurface",  EvlinKidColors.Reflection.bgSurface)
                swatch("Reflection.cardBg",     EvlinKidColors.Reflection.cardBg)
                swatch("Reflection.cardBorder", EvlinKidColors.Reflection.cardBorder)
                swatch("Reflection.buttonBg",   EvlinKidColors.Reflection.buttonBg)
            }
        }
        .padding()
    }
}

@ViewBuilder
private func swatch(_ name: String, _ color: Color) -> some View {
    HStack(spacing: 12) {
        RoundedRectangle(cornerRadius: 6)
            .fill(color)
            .frame(width: 48, height: 32)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.black.opacity(0.1), lineWidth: 0.5)
            )
        Text(name).font(.system(size: 13, design: .monospaced))
        Spacer()
    }
}
```

- [ ] **Step 4: Verify swatch colors match the prototype visually**

Open the rendered prototype at `http://localhost:8001/Evlin Student.html` (started in Task 0.1). Open the Xcode preview for `EvlinKidColors`. Cross-check `green500` and `Reflection.cardBg` against any rendered screen. Use Digital Color Meter (built into macOS) to confirm exact hex values on both.

- [ ] **Step 5: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add "Evlin iOS/DesignSystem/EvlinKidColors.swift"
git commit -m "feat(child): add EvlinKidColors design tokens (theme.jsx port)"
```

### Task 1.2: Add the kid `EvSpacing` / radius constants

The JSX prototype uses a small set of recurring values. Centralize them so views don't repeat magic numbers.

**Source of truth:** Recurring values across `home.jsx`, `task-detail.jsx`, `consequence-a.jsx`, `consequence-b.jsx`, `bypass.jsx`, `primitives.jsx`.

**Files:**
- Create: `Evlin iOS/Evlin iOS/DesignSystem/EvlinKidMetrics.swift`

- [ ] **Step 1: Create the file with the canonical values**

```swift
import CoreGraphics

/// Recurring layout values from the JSX prototype. Sourced by inspection of
/// `home.jsx`, `task-detail.jsx`, `bypass.jsx`, `consequence-a.jsx`,
/// `consequence-b.jsx`, `home-reflection.jsx`, `primitives.jsx`.
enum EvlinKidMetrics {
    enum Padding {
        static let screenH: CGFloat = 20      // every screen is 0/20px horizontal
        static let screenTop: CGFloat = 8     // most screens
        static let screenBottom: CGFloat = 30 // most screens
        static let cardInner: CGFloat = 22    // EvCard default in primitives.jsx is 20; hero cards use 22
        static let listGap: CGFloat = 10      // task row gap
    }

    enum Radius {
        static let card: CGFloat = 20         // EvCard
        static let cardLarge: CGFloat = 22    // task evidence camera button
        static let row: CGFloat = 18          // TaskRow
        static let chip: CGFloat = 999        // pill chip
        static let button: CGFloat = 18       // EvBigButton
        static let progressBar: CGFloat = 999
    }

    enum Size {
        static let buttonHeight: CGFloat = 58 // EvBigButton
        static let buttonHeightLg: CGFloat = 60 // reflection-flow buttons
        static let progressBarThick: CGFloat = 14 // home time hero
        static let progressBarThin: CGFloat = 4   // reflection step bar
        static let segPip: CGFloat = 5            // home quest pips
        static let taskCheckCircle: CGFloat = 30  // task row check circle
    }

    enum Letter {
        static let tightTitle: CGFloat = -0.8     // h1 hero
        static let mediumTitle: CGFloat = -0.6    // h2
        static let body: CGFloat = -0.2           // body
        static let upperLabel: CGFloat = 0.8      // ALL-CAPS labels
    }
}
```

- [ ] **Step 2: Verify compile**

Build the project. Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/DesignSystem/EvlinKidMetrics.swift"
git commit -m "feat(child): add EvlinKidMetrics — canonical sizes/radii from JSX"
```

### Task 1.3: Add kid-side primitives — `EvKidBigButton`, `EvKidBackButton`, `EvKidChip`, `EvKidProgressBar`, `EvKidCard`

The JSX prototype's `primitives.jsx` defines five reusable components. Port each as a SwiftUI view; every screen below uses these.

**Source of truth:** `primitives.jsx` lines 1–135.

**Files:**
- Create: `Evlin iOS/Evlin iOS/Components/Kid/EvKidBigButton.swift`
- Create: `Evlin iOS/Evlin iOS/Components/Kid/EvKidBackButton.swift`
- Create: `Evlin iOS/Evlin iOS/Components/Kid/EvKidChip.swift`
- Create: `Evlin iOS/Evlin iOS/Components/Kid/EvKidProgressBar.swift`
- Create: `Evlin iOS/Evlin iOS/Components/Kid/EvKidCard.swift`

- [ ] **Step 1: `EvKidBigButton`**

```swift
import SwiftUI

/// Mirrors `primitives.jsx :: EvBigButton`.
/// 58pt tall, 18pt radius, 17pt SemiBold, soft shadow tinted with the button bg.
struct EvKidBigButton<Label: View>: View {
    enum Tone { case primary, ghost }
    let tone: Tone
    let isDisabled: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    init(tone: Tone = .primary,
         isDisabled: Bool = false,
         action: @escaping () -> Void,
         @ViewBuilder label: @escaping () -> Label) {
        self.tone = tone
        self.isDisabled = isDisabled
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: { if !isDisabled { action() } }) {
            label()
                .font(.system(size: 17, weight: .semibold))
                .tracking(EvlinKidMetrics.Letter.body)
                .frame(maxWidth: .infinity)
                .frame(height: EvlinKidMetrics.Size.buttonHeight)
                .foregroundStyle(foreground)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.button))
                .overlay(borderOverlay)
                .shadow(color: shadowColor, radius: 8, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    private var foreground: Color {
        if isDisabled { return .white }
        switch tone {
        case .primary: return .white
        case .ghost:   return EvlinKidColors.ink
        }
    }
    private var background: Color {
        if isDisabled { return EvlinKidColors.ink4 }
        switch tone {
        case .primary: return EvlinKidColors.green500
        case .ghost:   return EvlinKidColors.surface
        }
    }
    @ViewBuilder
    private var borderOverlay: some View {
        if tone == .ghost {
            RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.button)
                .stroke(EvlinKidColors.line, lineWidth: 1.5)
        } else {
            EmptyView()
        }
    }
    private var shadowColor: Color {
        if isDisabled || tone == .ghost { return .clear }
        return EvlinKidColors.green500.opacity(0.25)
    }
}

#Preview {
    VStack(spacing: 16) {
        EvKidBigButton(action: {}) { Text("Continue") }
        EvKidBigButton(tone: .ghost, action: {}) { Text("Back to today") }
        EvKidBigButton(isDisabled: true, action: {}) { Text("Disabled") }
    }
    .padding()
}
```

- [ ] **Step 2: `EvKidBackButton`**

```swift
import SwiftUI

/// Mirrors `primitives.jsx :: EvBackButton`. Chevron + label, primary green tint.
struct EvKidBackButton: View {
    let label: String?
    let action: () -> Void

    init(label: String? = nil, action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                if let label {
                    Text(label)
                        .font(.system(size: 17, weight: .medium))
                }
            }
            .foregroundStyle(EvlinKidColors.primary)
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .offset(x: -4)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    EvKidBackButton(label: "Today", action: {})
        .padding()
}
```

- [ ] **Step 3: `EvKidChip`**

```swift
import SwiftUI

/// Mirrors `primitives.jsx :: EvChip`.
/// Pill chip in 5 tones — all map into the green palette.
struct EvKidChip: View {
    enum Tone { case neutral, violet, green, amber, red }
    enum Size { case sm, md }

    let tone: Tone
    let size: Size
    let text: String

    init(_ text: String, tone: Tone = .neutral, size: Size = .sm) {
        self.text = text
        self.tone = tone
        self.size = size
    }

    var body: some View {
        Text(text)
            .font(.system(size: size == .sm ? 12 : 13, weight: .semibold))
            .tracking(0.1)
            .foregroundStyle(fg)
            .padding(.horizontal, size == .sm ? 10 : 12)
            .padding(.vertical, size == .sm ? 4 : 6)
            .background(bg, in: Capsule())
    }

    private var fg: Color {
        switch tone {
        case .neutral: return EvlinKidColors.ink2
        case .violet:  return EvlinKidColors.green700
        case .green:   return EvlinKidColors.green700
        case .amber:   return EvlinKidColors.green600
        case .red:     return EvlinKidColors.green800
        }
    }
    private var bg: Color {
        switch tone {
        case .neutral: return EvlinKidColors.surface2
        case .violet:  return EvlinKidColors.green100
        case .green:   return EvlinKidColors.green100
        case .amber:   return EvlinKidColors.green50
        case .red:     return EvlinKidColors.green200
        }
    }
}

#Preview {
    HStack {
        EvKidChip("Chores", tone: .violet)
        EvKidChip("Done", tone: .green)
        EvKidChip("Submitted", tone: .amber)
        EvKidChip("Overdue", tone: .red)
    }
    .padding()
}
```

- [ ] **Step 4: `EvKidProgressBar`**

```swift
import SwiftUI

/// Mirrors `primitives.jsx :: EvProgressBar`.
/// Pill-clipped track + fill, animated width.
struct EvKidProgressBar: View {
    enum Tone { case primary, amber, red }
    let value: Double
    let max: Double
    let tone: Tone
    let height: CGFloat

    init(value: Double, max: Double = 100, tone: Tone = .primary, height: CGFloat = 14) {
        self.value = value
        self.max = max
        self.tone = tone
        self.height = height
    }

    private var pct: Double {
        Swift.max(0, Swift.min(1, value / max))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(trackColor)
                Capsule().fill(fillColor)
                    .frame(width: geo.size.width * pct)
                    .animation(.easeOut(duration: 0.4), value: pct)
            }
        }
        .frame(height: height)
    }

    private var fillColor: Color {
        switch tone {
        case .primary, .amber: return EvlinKidColors.green500
        case .red:             return EvlinKidColors.green700
        }
    }
    private var trackColor: Color {
        switch tone {
        case .primary, .amber: return EvlinKidColors.green100
        case .red:             return EvlinKidColors.green200
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        EvKidProgressBar(value: 70, max: 120, tone: .primary)
        EvKidProgressBar(value: 30, max: 120, tone: .amber)
        EvKidProgressBar(value: 10, max: 120, tone: .red)
    }
    .padding()
}
```

- [ ] **Step 5: `EvKidCard`**

```swift
import SwiftUI

/// Mirrors `primitives.jsx :: EvCard`. 6 tones, 20pt radius, 1px border.
struct EvKidCard<Content: View>: View {
    enum Tone { case plain, amber, green, red, violet, tinted }
    let tone: Tone
    let padding: CGFloat
    @ViewBuilder let content: () -> Content

    init(tone: Tone = .plain,
         padding: CGFloat = 20,
         @ViewBuilder content: @escaping () -> Content) {
        self.tone = tone
        self.padding = padding
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.card)
                    .stroke(border, lineWidth: 1)
            )
    }

    private var bg: Color {
        switch tone {
        case .plain:  return EvlinKidColors.surface
        case .amber:  return EvlinKidColors.green50
        case .green:  return EvlinKidColors.green100
        case .red:    return EvlinKidColors.green200
        case .violet: return EvlinKidColors.green50
        case .tinted: return EvlinKidColors.surface2
        }
    }
    private var border: Color {
        switch tone {
        case .plain, .tinted: return EvlinKidColors.line
        case .amber, .violet: return EvlinKidColors.green200
        case .green:          return EvlinKidColors.green200
        case .red:            return EvlinKidColors.green300
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        EvKidCard { Text("Plain card") }
        EvKidCard(tone: .green) { Text("Green card") }
        EvKidCard(tone: .amber) { Text("Amber card") }
        EvKidCard(tone: .tinted) { Text("Tinted card") }
    }
    .padding()
}
```

- [ ] **Step 6: Build the project**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
xcodebuild -project "Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination 'generic/platform=iOS' build 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`

If a preview reference fails, rendering #Preview blocks via Xcode's canvas catches it; fix any value typos.

- [ ] **Step 7: Commit**

```bash
git add "Evlin iOS/Components/Kid/"
git commit -m "feat(child): port primitives.jsx — kid Big/Back buttons, Chip, ProgressBar, Card"
```

---

## Phase 2: Backend — Models, Endpoints, In-Memory Fixture

Goal: stand up `/child/state` + the action endpoints with mock state, so iOS can integrate against a working server before the real DB schema lands. We persist to a per-process in-memory dict keyed by `child_id`, seeded from the fixture in Task 0.3. Real DB persistence is deferred — the endpoints' shapes are stable, internals can be swapped later.

**Convention check:** The project's existing FastAPI routes use `from __future__ import annotations`, Pydantic `BaseModel`, async SQLAlchemy via `Depends(get_async_session)`. New routes mirror this pattern but use an in-memory store (no DB session) for v1 of this plan. See `adaptive-engine/backend/app/api/routes/child_device.py` for reference.

### Task 2.1: Pydantic schemas

**Files:**
- Create: `adaptive-engine/backend/app/schemas/bigkid.py`

- [ ] **Step 1: Write the schema file**

```python
"""Pydantic schemas for big-kid child mode (spec §4 + §8.1)."""
from __future__ import annotations

from datetime import datetime
from enum import Enum
from typing import Optional
from uuid import UUID

from pydantic import BaseModel, Field


class TaskCategory(str, Enum):
    chores = "Chores"
    homework = "Homework"
    self_care = "Self-care"


class TaskStatus(str, Enum):
    todo = "todo"
    submitted = "submitted"
    done = "done"
    overdue = "overdue"


class TaskPhase(str, Enum):
    input = "input"
    submitted = "submitted"
    redo = "redo"


class BypassStatus(str, Enum):
    pending = "pending"
    approved = "approved"
    denied = "denied"
    withdrawn = "withdrawn"


class ReflectionStatus(str, Enum):
    pending = "pending"
    submitted = "submitted"
    approved = "approved"


class ReflectionStep(str, Enum):
    video = "video"
    quiz = "quiz"
    writing = "writing"


class BypassRequest(BaseModel):
    id: UUID
    task_id: UUID
    reason: str
    status: BypassStatus
    parent_response: Optional[str] = None
    created_at: datetime
    responded_at: Optional[datetime] = None


class Task(BaseModel):
    id: UUID
    title: str
    description: str
    category: TaskCategory
    due: Optional[str] = None         # human-readable, e.g. "8:00 AM"
    status: TaskStatus
    phase: TaskPhase
    redo_reason: Optional[str] = None
    evidence_photo_url: Optional[str] = None
    bypass: Optional[BypassRequest] = None


class QuizQuestionPublic(BaseModel):
    """Quiz question without correctIndex — for child consumption."""
    q: str
    options: list[str]


class ReflectionRequest(BaseModel):
    id: UUID
    reason: str
    video_id: str
    video_title: str
    writing_prompt: str
    quiz: list[QuizQuestionPublic]

    # progress
    steps_completed: list[ReflectionStep] = Field(default_factory=list)
    quiz_score: Optional[int] = None
    essay_text: Optional[str] = None

    # lifecycle
    status: ReflectionStatus
    parent_note: Optional[str] = None
    submitted_at: Optional[datetime] = None
    approved_at: Optional[datetime] = None


class ChildStateResponse(BaseModel):
    """GET /child/state — full snapshot for routing layer (spec §8.1)."""
    child_name: str
    minutes_left: int
    minutes_max: int
    tasks: list[Task]
    reflection_request: Optional[ReflectionRequest] = None
    notify_parent_cooldown_ends_at: Optional[datetime] = None
    daily_complete_acknowledged: bool
    screen_time_finished_acknowledged: bool


class BypassCreateBody(BaseModel):
    task_id: UUID
    reason: str


class QuizAnswerBody(BaseModel):
    question_index: int
    selected_index: int


class QuizAnswerResponse(BaseModel):
    correct: bool
    all_correct: bool
    score: int


class EssaySubmitBody(BaseModel):
    text: str


class TimeConsumptionBody(BaseModel):
    minutes_used: int


class ParentReflectionTriggerBody(BaseModel):
    child_id: UUID
    reason: str


class ParentReflectionApproveBody(BaseModel):
    parent_note: Optional[str] = None


class ParentBypassRespondBody(BaseModel):
    decision: str   # "approve" | "deny"
    message: Optional[str] = None


class ParentTaskReviewBody(BaseModel):
    decision: str   # "approve" | "redo"
    redo_reason: Optional[str] = None
```

- [ ] **Step 2: Verify the file imports cleanly**

```bash
cd /Users/fred/Desktop/Evlin/adaptive-engine
python3 -c "from backend.app.schemas.bigkid import ChildStateResponse, Task, ReflectionRequest, BypassRequest; print('OK')"
```

Expected: `OK`

- [ ] **Step 3: Commit**

```bash
cd /Users/fred/Desktop/Evlin/adaptive-engine
git add backend/app/schemas/bigkid.py
git commit -m "feat(backend): add big-kid child mode Pydantic schemas"
```

### Task 2.2: In-memory store with fixture seed

**Files:**
- Create: `adaptive-engine/backend/app/services/bigkid_store.py`

- [ ] **Step 1: Write the failing test**

Create: `adaptive-engine/backend/tests/test_bigkid_store.py`

```python
"""Tests for in-memory big-kid store."""
from __future__ import annotations

from uuid import UUID, uuid4

import pytest

from backend.app.services.bigkid_store import BigKidStore
from backend.app.schemas.bigkid import (
    BypassStatus, ReflectionStatus, ReflectionStep, TaskStatus,
)


CHILD = UUID("11111111-1111-1111-1111-111111111111")


def test_seed_creates_three_tasks_and_no_reflection() -> None:
    store = BigKidStore()
    state = store.get_state(CHILD)
    assert state.child_name == "Liam"
    assert state.minutes_max == 120
    assert state.minutes_left == 0  # tasks not done → no time pool yet
    assert len(state.tasks) == 3
    assert state.reflection_request is None
    assert state.daily_complete_acknowledged is False


def test_submit_evidence_flips_task_to_submitted_and_withdraws_pending_bypass() -> None:
    store = BigKidStore()
    state = store.get_state(CHILD)
    task = state.tasks[0]
    bypass = store.create_bypass(CHILD, task.id, "I forgot my notebook")
    assert bypass.status == BypassStatus.pending
    store.submit_evidence(CHILD, task.id, photo_url="https://example.test/p.jpg", note=None)
    refreshed = store.get_state(CHILD)
    refreshed_task = next(t for t in refreshed.tasks if t.id == task.id)
    assert refreshed_task.status == TaskStatus.submitted
    assert refreshed_task.bypass is not None
    assert refreshed_task.bypass.status == BypassStatus.withdrawn


def test_parent_approves_task_marks_done_and_unlocks_pool_when_all_done() -> None:
    store = BigKidStore()
    state = store.get_state(CHILD)
    for t in state.tasks:
        store.submit_evidence(CHILD, t.id, photo_url="https://example.test/p.jpg", note=None)
        store.parent_review_task(CHILD, t.id, decision="approve", redo_reason=None)
    refreshed = store.get_state(CHILD)
    assert all(t.status == TaskStatus.done for t in refreshed.tasks)
    assert refreshed.minutes_left == 120


def test_reflection_lifecycle_pending_to_submitted_to_approved() -> None:
    store = BigKidStore()
    store.trigger_reflection(CHILD, reason="kept scrolling")
    state = store.get_state(CHILD)
    assert state.reflection_request is not None
    rid = state.reflection_request.id
    assert state.reflection_request.status == ReflectionStatus.pending
    # video done
    store.complete_reflection_step(CHILD, rid, ReflectionStep.video)
    # quiz: answer all correctly
    for i in range(5):
        store.answer_quiz_question(CHILD, rid, question_index=i, selected_index=_correct_index(store, CHILD, rid, i))
    # writing
    store.submit_essay(CHILD, rid, text="I was tired and bored. I will read instead. Sorry.")
    after_submit = store.get_state(CHILD).reflection_request
    assert after_submit is not None
    assert after_submit.status == ReflectionStatus.submitted
    # parent approves
    store.parent_approve_reflection(CHILD, rid, parent_note="thanks for being honest")
    after_approve = store.get_state(CHILD).reflection_request
    assert after_approve is not None
    assert after_approve.status == ReflectionStatus.approved
    # ack drops it
    store.ack_reflection(CHILD, rid)
    assert store.get_state(CHILD).reflection_request is None


def _correct_index(store: BigKidStore, child: UUID, rid: UUID, q_idx: int) -> int:
    return store._reflection_correct_indices(child, rid)[q_idx]
```

- [ ] **Step 2: Run the test — expect failure**

```bash
cd /Users/fred/Desktop/Evlin/adaptive-engine
python3 -m pytest backend/tests/test_bigkid_store.py -v
```

Expected: `ModuleNotFoundError: No module named 'backend.app.services.bigkid_store'`

- [ ] **Step 3: Implement the store**

Create `adaptive-engine/backend/app/services/bigkid_store.py`:

```python
"""In-memory big-kid state store. Seeded once per process from fixture JSON.

This is the v1 backend — keeps the API surface stable while a real DB schema
is decided. Replace with SQLAlchemy persistence in a follow-up plan.
"""
from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import UUID, uuid4

from backend.app.schemas.bigkid import (
    BypassRequest, BypassStatus, ChildStateResponse, QuizQuestionPublic,
    ReflectionRequest, ReflectionStatus, ReflectionStep, Task, TaskCategory,
    TaskPhase, TaskStatus,
)


_FIXTURE_PATH = Path(__file__).resolve().parents[1] / "fixtures" / "bigkid_reflection_seed.json"


class BigKidStore:
    """Process-local store. Not multi-worker safe; suitable for dev/staging."""

    def __init__(self) -> None:
        self._states: dict[UUID, _ChildState] = {}
        self._reflection_correct: dict[tuple[UUID, UUID], list[int]] = {}

    # ---------- read ----------

    def get_state(self, child_id: UUID) -> ChildStateResponse:
        s = self._ensure_seeded(child_id)
        return s.snapshot()

    # ---------- task evidence ----------

    def submit_evidence(
        self, child_id: UUID, task_id: UUID, *, photo_url: str, note: str | None
    ) -> Task:
        s = self._ensure_seeded(child_id)
        task = s.task(task_id)
        task.evidence_photo_url = photo_url
        task.status = TaskStatus.submitted
        task.phase = TaskPhase.submitted
        if task.bypass and task.bypass.status == BypassStatus.pending:
            task.bypass.status = BypassStatus.withdrawn
            task.bypass.responded_at = datetime.now(timezone.utc)
        return task

    # ---------- bypass ----------

    def create_bypass(self, child_id: UUID, task_id: UUID, reason: str) -> BypassRequest:
        s = self._ensure_seeded(child_id)
        task = s.task(task_id)
        bypass = BypassRequest(
            id=uuid4(), task_id=task_id, reason=reason,
            status=BypassStatus.pending, created_at=datetime.now(timezone.utc),
        )
        task.bypass = bypass
        return bypass

    # ---------- parent task review ----------

    def parent_review_task(
        self, child_id: UUID, task_id: UUID, *, decision: str, redo_reason: str | None
    ) -> Task:
        s = self._ensure_seeded(child_id)
        task = s.task(task_id)
        if decision == "approve":
            task.status = TaskStatus.done
            task.phase = TaskPhase.submitted  # phase is irrelevant once done
        elif decision == "redo":
            task.status = TaskStatus.todo
            task.phase = TaskPhase.redo
            task.redo_reason = redo_reason
        else:
            raise ValueError(f"unknown decision: {decision}")
        s.recompute_time_pool()
        return task

    # ---------- reflection ----------

    def trigger_reflection(self, child_id: UUID, reason: str) -> ReflectionRequest:
        s = self._ensure_seeded(child_id)
        seed = _load_fixture()
        rid = uuid4()
        public_quiz = [QuizQuestionPublic(q=q["q"], options=q["options"]) for q in seed["quiz"]]
        correct = [int(q["correctIndex"]) for q in seed["quiz"]]
        req = ReflectionRequest(
            id=rid, reason=reason,
            video_id=seed["videoId"], video_title=seed["videoTitle"],
            writing_prompt=seed["writingPrompt"],
            quiz=public_quiz, status=ReflectionStatus.pending,
        )
        s.reflection = req
        self._reflection_correct[(child_id, rid)] = correct
        return req

    def complete_reflection_step(
        self, child_id: UUID, rid: UUID, step: ReflectionStep
    ) -> ReflectionRequest:
        req = self._require_reflection(child_id, rid)
        if step not in req.steps_completed:
            req.steps_completed.append(step)
        return req

    def answer_quiz_question(
        self, child_id: UUID, rid: UUID, *, question_index: int, selected_index: int
    ) -> tuple[bool, bool, int]:
        req = self._require_reflection(child_id, rid)
        correct = self._reflection_correct[(child_id, rid)]
        is_correct = selected_index == correct[question_index]
        # store running answers on the model (not exposed to child) — recompute score on each call
        score_attr = "_answers"
        answers: dict[int, int] = getattr(req, score_attr, {})
        answers[question_index] = selected_index
        setattr(req, score_attr, answers)
        score = sum(1 for i, sel in answers.items() if sel == correct[i])
        all_correct = len(answers) == len(correct) and score == len(correct)
        if len(answers) == len(correct):
            req.quiz_score = score
            if score >= 4:
                if ReflectionStep.quiz not in req.steps_completed:
                    req.steps_completed.append(ReflectionStep.quiz)
        return is_correct, all_correct, score

    def submit_essay(self, child_id: UUID, rid: UUID, *, text: str) -> ReflectionRequest:
        req = self._require_reflection(child_id, rid)
        req.essay_text = text
        if ReflectionStep.writing not in req.steps_completed:
            req.steps_completed.append(ReflectionStep.writing)
        if {ReflectionStep.video, ReflectionStep.quiz, ReflectionStep.writing}.issubset(set(req.steps_completed)):
            req.status = ReflectionStatus.submitted
            req.submitted_at = datetime.now(timezone.utc)
        return req

    def nudge_parent(self, child_id: UUID, rid: UUID) -> datetime:
        s = self._ensure_seeded(child_id)
        if s.notify_cooldown_ends_at and s.notify_cooldown_ends_at > datetime.now(timezone.utc):
            return s.notify_cooldown_ends_at  # idempotent within window
        ends = datetime.now(timezone.utc) + timedelta(minutes=5)
        s.notify_cooldown_ends_at = ends
        return ends

    def parent_approve_reflection(
        self, child_id: UUID, rid: UUID, *, parent_note: str | None
    ) -> ReflectionRequest:
        req = self._require_reflection(child_id, rid)
        if req.status != ReflectionStatus.submitted:
            raise ValueError("can only approve a submitted reflection")
        req.status = ReflectionStatus.approved
        req.parent_note = parent_note
        req.approved_at = datetime.now(timezone.utc)
        return req

    def ack_reflection(self, child_id: UUID, rid: UUID) -> None:
        s = self._ensure_seeded(child_id)
        if s.reflection and s.reflection.id == rid:
            s.reflection = None
            s.notify_cooldown_ends_at = None

    # ---------- end-of-day acks ----------

    def ack_daily_complete(self, child_id: UUID) -> None:
        s = self._ensure_seeded(child_id)
        s.daily_complete_acknowledged = True

    def ack_screen_time_finished(self, child_id: UUID) -> None:
        s = self._ensure_seeded(child_id)
        s.screen_time_finished_acknowledged = True

    # ---------- time consumption ----------

    def record_time_use(self, child_id: UUID, *, minutes_used: int) -> int:
        s = self._ensure_seeded(child_id)
        s.minutes_left = max(0, s.minutes_left - minutes_used)
        return s.minutes_left

    # ---------- internal ----------

    def _reflection_correct_indices(self, child_id: UUID, rid: UUID) -> list[int]:
        return self._reflection_correct[(child_id, rid)]

    def _ensure_seeded(self, child_id: UUID) -> "_ChildState":
        if child_id not in self._states:
            self._states[child_id] = _ChildState.seed_default()
        return self._states[child_id]

    def _require_reflection(self, child_id: UUID, rid: UUID) -> ReflectionRequest:
        s = self._ensure_seeded(child_id)
        if not s.reflection or s.reflection.id != rid:
            raise ValueError(f"no active reflection {rid} for child {child_id}")
        return s.reflection


class _ChildState:
    """Internal representation; converts to ChildStateResponse on demand."""

    def __init__(
        self, *, child_name: str, minutes_max: int, tasks: list[Task],
    ) -> None:
        self.child_name = child_name
        self.minutes_max = minutes_max
        self.minutes_left = 0
        self.tasks = tasks
        self.reflection: ReflectionRequest | None = None
        self.notify_cooldown_ends_at: datetime | None = None
        self.daily_complete_acknowledged = False
        self.screen_time_finished_acknowledged = False

    @classmethod
    def seed_default(cls) -> "_ChildState":
        tasks = [
            Task(
                id=uuid4(), title="Make bed", description="Smooth the covers and fluff the pillow.",
                category=TaskCategory.chores, due="8:00 AM",
                status=TaskStatus.todo, phase=TaskPhase.input,
            ),
            Task(
                id=uuid4(), title="Math homework",
                description="Page 42, problems 1–10. Show your work.",
                category=TaskCategory.homework, due="6:00 PM",
                status=TaskStatus.todo, phase=TaskPhase.input,
            ),
            Task(
                id=uuid4(), title="Brush teeth",
                description="Two minutes, top and bottom.",
                category=TaskCategory.self_care, due="9:00 PM",
                status=TaskStatus.todo, phase=TaskPhase.input,
            ),
        ]
        return cls(child_name="Liam", minutes_max=120, tasks=tasks)

    def task(self, task_id: UUID) -> Task:
        for t in self.tasks:
            if t.id == task_id:
                return t
        raise ValueError(f"task {task_id} not found")

    def all_tasks_done(self) -> bool:
        return all(
            t.status == TaskStatus.done or
            (t.bypass is not None and t.bypass.status == BypassStatus.approved)
            for t in self.tasks
        )

    def recompute_time_pool(self) -> None:
        if self.all_tasks_done() and self.minutes_left == 0:
            self.minutes_left = self.minutes_max

    def snapshot(self) -> ChildStateResponse:
        return ChildStateResponse(
            child_name=self.child_name,
            minutes_left=self.minutes_left,
            minutes_max=self.minutes_max,
            tasks=[t.model_copy(deep=True) for t in self.tasks],
            reflection_request=self.reflection.model_copy(deep=True) if self.reflection else None,
            notify_parent_cooldown_ends_at=self.notify_cooldown_ends_at,
            daily_complete_acknowledged=self.daily_complete_acknowledged,
            screen_time_finished_acknowledged=self.screen_time_finished_acknowledged,
        )


def _load_fixture() -> dict:
    with _FIXTURE_PATH.open() as f:
        return json.load(f)


_singleton: BigKidStore | None = None


def get_store() -> BigKidStore:
    """FastAPI dependency injector."""
    global _singleton
    if _singleton is None:
        _singleton = BigKidStore()
    return _singleton
```

- [ ] **Step 4: Run tests — expect pass**

```bash
cd /Users/fred/Desktop/Evlin/adaptive-engine
python3 -m pytest backend/tests/test_bigkid_store.py -v
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add backend/app/services/bigkid_store.py backend/tests/test_bigkid_store.py
git commit -m "feat(backend): in-memory big-kid store with bypass auto-withdraw + reflection lifecycle"
```

### Task 2.3: `/child/state` endpoint + child auth dependency

**Files:**
- Create: `adaptive-engine/backend/app/api/routes/bigkid_child.py`
- Modify: `adaptive-engine/backend/app/main.py` (register router)

- [ ] **Step 1: Write failing endpoint test**

Create `adaptive-engine/backend/tests/test_bigkid_endpoints.py`:

```python
"""End-to-end tests for big-kid /child and /parent endpoints."""
from __future__ import annotations

from uuid import UUID

import pytest
from fastapi.testclient import TestClient

from backend.app.main import app

CHILD = "11111111-1111-1111-1111-111111111111"
HEADERS = {"X-Child-Id": CHILD}


@pytest.fixture
def client() -> TestClient:
    # Reset the in-memory store between tests.
    from backend.app.services import bigkid_store
    bigkid_store._singleton = None
    return TestClient(app)


def test_get_state_returns_seeded_response(client: TestClient) -> None:
    r = client.get("/api/v1/child/state", headers=HEADERS)
    assert r.status_code == 200
    body = r.json()
    assert body["child_name"] == "Liam"
    assert body["minutes_left"] == 0
    assert body["minutes_max"] == 120
    assert len(body["tasks"]) == 3
    assert body["reflection_request"] is None
```

- [ ] **Step 2: Run — expect 404**

```bash
python3 -m pytest backend/tests/test_bigkid_endpoints.py::test_get_state_returns_seeded_response -v
```

Expected: AssertionError on `r.status_code == 200` (route not registered → 404).

- [ ] **Step 3: Create the route file**

Create `adaptive-engine/backend/app/api/routes/bigkid_child.py`:

```python
"""Big-kid child mode — `/child/*` endpoints (spec §8.1–§8.10)."""
from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, Header, HTTPException

from backend.app.schemas.bigkid import (
    BypassCreateBody, BypassRequest, ChildStateResponse, EssaySubmitBody,
    QuizAnswerBody, QuizAnswerResponse, ReflectionStep, Task,
    TimeConsumptionBody,
)
from backend.app.services.bigkid_store import BigKidStore, get_store


router = APIRouter(tags=["Big-Kid Child"])


def child_id_dep(x_child_id: str = Header(...)) -> UUID:
    """Auth shim: child identity comes from `X-Child-Id` header.
    v1 placeholder — real auth (paired token verification) lands in a follow-up plan.
    """
    try:
        return UUID(x_child_id)
    except ValueError as e:
        raise HTTPException(status_code=401, detail="invalid X-Child-Id") from e


@router.get("/child/state", response_model=ChildStateResponse)
def get_state(
    child: UUID = Depends(child_id_dep),
    store: BigKidStore = Depends(get_store),
) -> ChildStateResponse:
    return store.get_state(child)
```

- [ ] **Step 4: Register router in `main.py`**

Open `adaptive-engine/backend/app/main.py`. Locate the section where existing routers are included (search for `child_device`). Add:

```python
from backend.app.api.routes import bigkid_child  # noqa: E402

app.include_router(bigkid_child.router, prefix="/api/v1")
```

- [ ] **Step 5: Run test — expect pass**

```bash
python3 -m pytest backend/tests/test_bigkid_endpoints.py::test_get_state_returns_seeded_response -v
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add backend/app/api/routes/bigkid_child.py backend/app/main.py backend/tests/test_bigkid_endpoints.py
git commit -m "feat(backend): GET /child/state endpoint with X-Child-Id header auth"
```

### Task 2.4: `/child/task/{id}/evidence` endpoint (multipart upload)

**Files:**
- Modify: `adaptive-engine/backend/app/api/routes/bigkid_child.py`
- Modify: `adaptive-engine/backend/app/services/bigkid_store.py` (add storage hook)
- Modify: `adaptive-engine/backend/tests/test_bigkid_endpoints.py`

- [ ] **Step 1: Write failing test**

Append to `test_bigkid_endpoints.py`:

```python
def test_post_evidence_marks_task_submitted(client: TestClient) -> None:
    state = client.get("/api/v1/child/state", headers=HEADERS).json()
    task_id = state["tasks"][0]["id"]
    files = {"photo": ("evidence.jpg", b"\xff\xd8\xff\xe0fakejpg", "image/jpeg")}
    r = client.post(
        f"/api/v1/child/task/{task_id}/evidence",
        headers=HEADERS, files=files, data={"note": "All done!"},
    )
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "submitted"
    assert body["phase"] == "submitted"
    assert body["evidence_photo_url"].startswith("https://")
```

- [ ] **Step 2: Run — expect 404 / 422**

```bash
python3 -m pytest backend/tests/test_bigkid_endpoints.py::test_post_evidence_marks_task_submitted -v
```

Expected: failure (route undefined).

- [ ] **Step 3: Add storage stub + endpoint**

Append to `backend/app/services/bigkid_store.py`:

```python
def stub_upload_evidence(child_id: UUID, task_id: UUID, content: bytes) -> str:
    """Placeholder upload — returns a fake stable URL.
    Replace with Supabase Storage upload in a follow-up task (per spec §13 Q4).
    """
    return f"https://storage.evlin.local/evidence/{child_id}/{task_id}/photo.jpg"
```

Append to `bigkid_child.py`:

```python
from fastapi import File, Form, UploadFile

from backend.app.services.bigkid_store import stub_upload_evidence


@router.post("/child/task/{task_id}/evidence", response_model=Task)
async def submit_evidence(
    task_id: UUID,
    photo: UploadFile = File(...),
    note: str | None = Form(default=None),
    child: UUID = Depends(child_id_dep),
    store: BigKidStore = Depends(get_store),
) -> Task:
    content = await photo.read()
    if len(content) > 5 * 1024 * 1024:
        raise HTTPException(status_code=413, detail="photo too large")
    url = stub_upload_evidence(child, task_id, content)
    return store.submit_evidence(child, task_id, photo_url=url, note=note)
```

- [ ] **Step 4: Run test — expect pass**

```bash
python3 -m pytest backend/tests/test_bigkid_endpoints.py::test_post_evidence_marks_task_submitted -v
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/app/api/routes/bigkid_child.py backend/app/services/bigkid_store.py backend/tests/test_bigkid_endpoints.py
git commit -m "feat(backend): POST /child/task/{id}/evidence with stub storage"
```

### Task 2.5: Bypass endpoint + auto-withdraw test

**Files:**
- Modify: `adaptive-engine/backend/app/api/routes/bigkid_child.py`
- Modify: `adaptive-engine/backend/tests/test_bigkid_endpoints.py`

- [ ] **Step 1: Write failing test for bypass-then-evidence-cancels-bypass**

Append to `test_bigkid_endpoints.py`:

```python
def test_bypass_then_evidence_withdraws_bypass(client: TestClient) -> None:
    state = client.get("/api/v1/child/state", headers=HEADERS).json()
    task_id = state["tasks"][0]["id"]
    # Submit bypass
    r = client.post(
        "/api/v1/child/bypass", headers=HEADERS,
        json={"task_id": task_id, "reason": "I had a fever"},
    )
    assert r.status_code == 200
    assert r.json()["status"] == "pending"
    # Submit evidence on same task → bypass auto-withdraws
    files = {"photo": ("e.jpg", b"\xff\xd8\xff", "image/jpeg")}
    client.post(f"/api/v1/child/task/{task_id}/evidence", headers=HEADERS, files=files)
    after = client.get("/api/v1/child/state", headers=HEADERS).json()
    after_task = next(t for t in after["tasks"] if t["id"] == task_id)
    assert after_task["bypass"]["status"] == "withdrawn"
```

- [ ] **Step 2: Run — expect failure**

```bash
python3 -m pytest backend/tests/test_bigkid_endpoints.py::test_bypass_then_evidence_withdraws_bypass -v
```

- [ ] **Step 3: Add the bypass endpoint**

Append to `bigkid_child.py`:

```python
@router.post("/child/bypass", response_model=BypassRequest)
def create_bypass(
    body: BypassCreateBody,
    child: UUID = Depends(child_id_dep),
    store: BigKidStore = Depends(get_store),
) -> BypassRequest:
    return store.create_bypass(child, body.task_id, body.reason)
```

- [ ] **Step 4: Run test — expect pass**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/app/api/routes/bigkid_child.py backend/tests/test_bigkid_endpoints.py
git commit -m "feat(backend): POST /child/bypass with auto-withdraw on evidence submit"
```

### Task 2.6: Reflection lifecycle endpoints

Five endpoints: `quiz-answer`, `essay`, `nudge`, `ack`, plus a parent-side `/parent/reflection/trigger` so we can drive the test flow.

**Files:**
- Modify: `adaptive-engine/backend/app/api/routes/bigkid_child.py`
- Create: `adaptive-engine/backend/app/api/routes/bigkid_parent.py`
- Modify: `adaptive-engine/backend/app/main.py`
- Modify: `adaptive-engine/backend/tests/test_bigkid_endpoints.py`

- [ ] **Step 1: Write failing test for full reflection flow**

Append to `test_bigkid_endpoints.py`:

```python
def test_reflection_full_flow(client: TestClient) -> None:
    # Parent triggers
    r = client.post(
        "/api/v1/parent/reflection/trigger",
        json={"child_id": CHILD, "reason": "stayed up too late"},
    )
    assert r.status_code == 200
    rid = r.json()["id"]

    # Child sees it
    state = client.get("/api/v1/child/state", headers=HEADERS).json()
    assert state["reflection_request"]["id"] == rid
    assert state["reflection_request"]["status"] == "pending"

    # Video step
    r = client.post(
        f"/api/v1/child/reflection/{rid}/step-complete",
        headers=HEADERS, json={"step": "video"},
    )
    assert r.status_code == 200

    # Quiz: answer 5 questions correctly
    quiz = state["reflection_request"]["quiz"]
    fixture_correct = [0, 1, 2, 1, 1]  # from seed
    for i, correct_idx in enumerate(fixture_correct):
        r = client.post(
            f"/api/v1/child/reflection/{rid}/quiz-answer",
            headers=HEADERS,
            json={"question_index": i, "selected_index": correct_idx},
        )
        assert r.status_code == 200
        body = r.json()
        assert body["correct"] is True
    assert body["all_correct"] is True
    assert body["score"] == 5

    # Essay
    r = client.post(
        f"/api/v1/child/reflection/{rid}/essay",
        headers=HEADERS,
        json={"text": "I felt tired and grumpy. Next time I will go to bed when asked. I'm sorry."},
    )
    assert r.status_code == 200
    after = client.get("/api/v1/child/state", headers=HEADERS).json()
    assert after["reflection_request"]["status"] == "submitted"

    # Nudge starts cooldown
    r = client.post(f"/api/v1/child/reflection/{rid}/nudge", headers=HEADERS)
    assert r.status_code == 200
    assert "ends_at" in r.json()

    # Parent approves
    r = client.post(
        f"/api/v1/parent/reflection/{rid}/approve",
        json={"parent_note": "Thanks for being honest."},
    )
    assert r.status_code == 200

    after = client.get("/api/v1/child/state", headers=HEADERS).json()
    assert after["reflection_request"]["status"] == "approved"
    assert after["reflection_request"]["parent_note"] == "Thanks for being honest."

    # Ack drops it
    r = client.post(f"/api/v1/child/reflection/{rid}/ack", headers=HEADERS)
    assert r.status_code == 204
    after = client.get("/api/v1/child/state", headers=HEADERS).json()
    assert after["reflection_request"] is None
```

- [ ] **Step 2: Add child-side reflection endpoints**

Append to `bigkid_child.py`:

```python
from datetime import datetime
from pydantic import BaseModel
from fastapi import status

from backend.app.schemas.bigkid import ReflectionRequest


class StepCompleteBody(BaseModel):
    step: ReflectionStep


class NudgeResponse(BaseModel):
    ends_at: datetime


@router.post("/child/reflection/{rid}/step-complete", response_model=ReflectionRequest)
def reflection_step_complete(
    rid: UUID, body: StepCompleteBody,
    child: UUID = Depends(child_id_dep),
    store: BigKidStore = Depends(get_store),
) -> ReflectionRequest:
    return store.complete_reflection_step(child, rid, body.step)


@router.post("/child/reflection/{rid}/quiz-answer", response_model=QuizAnswerResponse)
def reflection_quiz_answer(
    rid: UUID, body: QuizAnswerBody,
    child: UUID = Depends(child_id_dep),
    store: BigKidStore = Depends(get_store),
) -> QuizAnswerResponse:
    is_correct, all_correct, score = store.answer_quiz_question(
        child, rid, question_index=body.question_index, selected_index=body.selected_index,
    )
    return QuizAnswerResponse(correct=is_correct, all_correct=all_correct, score=score)


@router.post("/child/reflection/{rid}/essay", response_model=ReflectionRequest)
def reflection_essay(
    rid: UUID, body: EssaySubmitBody,
    child: UUID = Depends(child_id_dep),
    store: BigKidStore = Depends(get_store),
) -> ReflectionRequest:
    return store.submit_essay(child, rid, text=body.text)


@router.post("/child/reflection/{rid}/nudge", response_model=NudgeResponse)
def reflection_nudge(
    rid: UUID,
    child: UUID = Depends(child_id_dep),
    store: BigKidStore = Depends(get_store),
) -> NudgeResponse:
    return NudgeResponse(ends_at=store.nudge_parent(child, rid))


@router.post("/child/reflection/{rid}/ack", status_code=status.HTTP_204_NO_CONTENT)
def reflection_ack(
    rid: UUID,
    child: UUID = Depends(child_id_dep),
    store: BigKidStore = Depends(get_store),
) -> None:
    store.ack_reflection(child, rid)


@router.post("/child/daily-complete/ack", status_code=status.HTTP_204_NO_CONTENT)
def daily_complete_ack(
    child: UUID = Depends(child_id_dep),
    store: BigKidStore = Depends(get_store),
) -> None:
    store.ack_daily_complete(child)


@router.post("/child/screen-time-finished/ack", status_code=status.HTTP_204_NO_CONTENT)
def screen_time_finished_ack(
    child: UUID = Depends(child_id_dep),
    store: BigKidStore = Depends(get_store),
) -> None:
    store.ack_screen_time_finished(child)


@router.post("/child/time-consumption")
def time_consumption(
    body: TimeConsumptionBody,
    child: UUID = Depends(child_id_dep),
    store: BigKidStore = Depends(get_store),
) -> dict:
    minutes_left = store.record_time_use(child, minutes_used=body.minutes_used)
    return {"minutes_left": minutes_left}
```

- [ ] **Step 3: Create parent-side router**

Create `adaptive-engine/backend/app/api/routes/bigkid_parent.py`:

```python
"""Big-kid parent endpoints used by the parent app + tests.
Full Gemini-driven reflection content is wired in Phase 9; this scaffold
uses fixture content so the v1 child flow is testable end-to-end.
"""
from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException

from backend.app.schemas.bigkid import (
    ParentBypassRespondBody, ParentReflectionApproveBody,
    ParentReflectionTriggerBody, ParentTaskReviewBody,
    ReflectionRequest, Task,
)
from backend.app.services.bigkid_store import BigKidStore, get_store


router = APIRouter(tags=["Big-Kid Parent"])


@router.post("/parent/reflection/trigger", response_model=ReflectionRequest)
def trigger_reflection(
    body: ParentReflectionTriggerBody,
    store: BigKidStore = Depends(get_store),
) -> ReflectionRequest:
    return store.trigger_reflection(body.child_id, body.reason)


@router.post("/parent/reflection/{rid}/approve", response_model=ReflectionRequest)
def approve_reflection(
    rid: UUID, body: ParentReflectionApproveBody,
    store: BigKidStore = Depends(get_store),
) -> ReflectionRequest:
    # NOTE: child_id derivation from rid is left to the real auth implementation.
    # For v1 in-memory store we scan all states.
    for cid, s in store._states.items():  # noqa: SLF001
        if s.reflection and s.reflection.id == rid:
            return store.parent_approve_reflection(cid, rid, parent_note=body.parent_note)
    raise HTTPException(status_code=404, detail="reflection not found")


@router.post("/parent/task/{task_id}/review", response_model=Task)
def review_task(
    task_id: UUID, body: ParentTaskReviewBody,
    store: BigKidStore = Depends(get_store),
) -> Task:
    for cid, s in store._states.items():  # noqa: SLF001
        for t in s.tasks:
            if t.id == task_id:
                return store.parent_review_task(
                    cid, task_id, decision=body.decision, redo_reason=body.redo_reason,
                )
    raise HTTPException(status_code=404, detail="task not found")
```

- [ ] **Step 4: Register parent router**

In `main.py`:

```python
from backend.app.api.routes import bigkid_parent  # noqa: E402

app.include_router(bigkid_parent.router, prefix="/api/v1")
```

- [ ] **Step 5: Run all big-kid tests**

```bash
python3 -m pytest backend/tests/test_bigkid_endpoints.py -v
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add backend/app/api/routes/bigkid_child.py backend/app/api/routes/bigkid_parent.py backend/app/main.py backend/tests/test_bigkid_endpoints.py
git commit -m "feat(backend): full big-kid reflection + bypass + ack endpoints with E2E test"
```

### Task 2.7: Run the backend locally and smoke-test from curl

- [ ] **Step 1: Start the server**

```bash
cd /Users/fred/Desktop/Evlin/adaptive-engine/backend
uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

(Leave it running in a separate terminal; return when iOS work begins in Phase 3.)

- [ ] **Step 2: Curl the state**

```bash
curl -s -H "X-Child-Id: 11111111-1111-1111-1111-111111111111" \
     http://localhost:8000/api/v1/child/state | python3 -m json.tool
```

Expected: JSON body with 3 tasks, no reflection.

- [ ] **Step 3: Trigger reflection and re-fetch state**

```bash
curl -s -X POST http://localhost:8000/api/v1/parent/reflection/trigger \
     -H "Content-Type: application/json" \
     -d '{"child_id":"11111111-1111-1111-1111-111111111111","reason":"smoke test"}' \
     | python3 -m json.tool

curl -s -H "X-Child-Id: 11111111-1111-1111-1111-111111111111" \
     http://localhost:8000/api/v1/child/state \
     | python3 -m json.tool | head -40
```

Expected: `reflection_request` populated.

- [ ] **Step 4: No commit (smoke test only). Document the curl recipes**

Create `adaptive-engine/backend/docs/bigkid-smoke.md`:

```markdown
# Big-Kid Backend — Local Smoke Recipes

Start: `uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload`

State: `curl -H "X-Child-Id: 11111111-1111-1111-1111-111111111111" http://localhost:8000/api/v1/child/state`

Trigger reflection: `curl -X POST http://localhost:8000/api/v1/parent/reflection/trigger -H "Content-Type: application/json" -d '{"child_id":"11111111-1111-1111-1111-111111111111","reason":"smoke test"}'`

Reset state: kill and restart uvicorn (in-memory store).
```

```bash
git add backend/docs/bigkid-smoke.md
git commit -m "docs(backend): big-kid local smoke recipes"
```

---

## Phase 3: iOS Models + APIClient + Poller

Goal: Codable Swift models matching the Pydantic schemas exactly, an APIClient covering all `/child/*` endpoints, and a `BigKidStatePoller` driving `BigKidState`. By the end of this phase, an Xcode preview can hit a running local backend and render real data.

### Task 3.1: Swift models — `BigKidTask`, `BypassRequest`, `ReflectionRequest`, etc.

**Files:**
- Create: `Evlin iOS/Evlin iOS/Models/BigKid/BigKidModels.swift`

- [ ] **Step 1: Write failing decode test**

Create test target if missing. Most projects have `Evlin iOSTests/`. Inspect:

```bash
ls "/Users/fred/Desktop/Evlin/Evlin iOS/Evlin iOSTests/" 2>/dev/null
```

If a tests target exists, create `Evlin iOSTests/BigKidModelsTests.swift`:

```swift
import XCTest
@testable import Evlin_iOS

final class BigKidModelsTests: XCTestCase {
    func testDecodesChildStateResponse() throws {
        let json = """
        {
          "child_name": "Liam",
          "minutes_left": 45,
          "minutes_max": 120,
          "tasks": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "title": "Make bed",
              "description": "Smooth covers",
              "category": "Chores",
              "due": "8:00 AM",
              "status": "todo",
              "phase": "input",
              "redo_reason": null,
              "evidence_photo_url": null,
              "bypass": null
            }
          ],
          "reflection_request": null,
          "notify_parent_cooldown_ends_at": null,
          "daily_complete_acknowledged": false,
          "screen_time_finished_acknowledged": false
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder.bigKid
        let resp = try decoder.decode(ChildStateResponse.self, from: json)
        XCTAssertEqual(resp.childName, "Liam")
        XCTAssertEqual(resp.minutesLeft, 45)
        XCTAssertEqual(resp.tasks.count, 1)
        XCTAssertEqual(resp.tasks[0].title, "Make bed")
        XCTAssertEqual(resp.tasks[0].status, .todo)
    }

    func testAllTasksDoneWithApprovedBypass() throws {
        let task = BigKidTask.fixture(status: .todo, bypass: .fixture(status: .approved))
        let state = BigKidState(snapshot: ChildStateResponse.fixture(tasks: [task]))
        XCTAssertTrue(state.allTasksDone)
    }

    func testAllTasksDoneFalseWithPendingBypass() throws {
        let task = BigKidTask.fixture(status: .todo, bypass: .fixture(status: .pending))
        let state = BigKidState(snapshot: ChildStateResponse.fixture(tasks: [task]))
        XCTAssertFalse(state.allTasksDone)
    }
}
```

- [ ] **Step 2: Run — expect failure**

In Xcode: `Cmd+U`. Or:

```bash
xcodebuild test -project "Evlin iOS/Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 | grep -E "(BigKidModels|error)" | head -20
```

Expected: build fails — types undefined.

- [ ] **Step 3: Create the models file**

Create `Evlin iOS/Evlin iOS/Models/BigKid/BigKidModels.swift`:

```swift
import Foundation

// MARK: - Enums

enum BigKidTaskCategory: String, Codable, Equatable, Sendable {
    case chores = "Chores"
    case homework = "Homework"
    case selfCare = "Self-care"
}

enum BigKidTaskStatus: String, Codable, Equatable, Sendable {
    case todo, submitted, done, overdue
}

enum BigKidTaskPhase: String, Codable, Equatable, Sendable {
    case input, submitted, redo
}

enum BigKidBypassStatus: String, Codable, Equatable, Sendable {
    case pending, approved, denied, withdrawn
}

enum BigKidReflectionStatus: String, Codable, Equatable, Sendable {
    case pending, submitted, approved
}

enum BigKidReflectionStep: String, Codable, Equatable, Sendable {
    case video, quiz, writing
}

// MARK: - DTOs (snake_case <-> camelCase via JSONDecoder.bigKid)

struct BypassRequest: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let taskId: UUID
    let reason: String
    let status: BigKidBypassStatus
    let parentResponse: String?
    let createdAt: Date
    let respondedAt: Date?
}

struct BigKidTask: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let title: String
    let description: String
    let category: BigKidTaskCategory
    let due: String?
    let status: BigKidTaskStatus
    let phase: BigKidTaskPhase
    let redoReason: String?
    let evidencePhotoURL: URL?
    let bypass: BypassRequest?
}

struct QuizQuestion: Codable, Equatable, Sendable {
    let q: String
    let options: [String]
}

struct ReflectionRequest: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let reason: String
    let videoId: String
    let videoTitle: String
    let writingPrompt: String
    let quiz: [QuizQuestion]
    let stepsCompleted: [BigKidReflectionStep]
    let quizScore: Int?
    let essayText: String?
    let status: BigKidReflectionStatus
    let parentNote: String?
    let submittedAt: Date?
    let approvedAt: Date?
}

struct ChildStateResponse: Codable, Equatable, Sendable {
    let childName: String
    let minutesLeft: Int
    let minutesMax: Int
    let tasks: [BigKidTask]
    let reflectionRequest: ReflectionRequest?
    let notifyParentCooldownEndsAt: Date?
    let dailyCompleteAcknowledged: Bool
    let screenTimeFinishedAcknowledged: Bool
}

// MARK: - Decoder configuration

extension JSONDecoder {
    static let bigKid: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

extension JSONEncoder {
    static let bigKid: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

// MARK: - Fixtures (DEBUG only — used by previews + tests)

#if DEBUG
extension BypassRequest {
    static func fixture(
        id: UUID = UUID(),
        taskId: UUID = UUID(),
        reason: String = "I had football practice",
        status: BigKidBypassStatus = .pending
    ) -> BypassRequest {
        BypassRequest(
            id: id, taskId: taskId, reason: reason, status: status,
            parentResponse: nil, createdAt: Date(), respondedAt: nil,
        )
    }
}

extension BigKidTask {
    static func fixture(
        id: UUID = UUID(),
        title: String = "Make bed",
        description: String = "Smooth the covers and fluff the pillow.",
        category: BigKidTaskCategory = .chores,
        due: String? = "8:00 AM",
        status: BigKidTaskStatus = .todo,
        phase: BigKidTaskPhase = .input,
        bypass: BypassRequest? = nil
    ) -> BigKidTask {
        BigKidTask(
            id: id, title: title, description: description, category: category,
            due: due, status: status, phase: phase, redoReason: nil,
            evidencePhotoURL: nil, bypass: bypass,
        )
    }
}

extension ReflectionRequest {
    static func fixture(
        status: BigKidReflectionStatus = .pending,
        stepsCompleted: [BigKidReflectionStep] = []
    ) -> ReflectionRequest {
        ReflectionRequest(
            id: UUID(), reason: "stayed up too late",
            videoId: "dQw4w9WgXcQ",
            videoTitle: "Why rest time matters",
            writingPrompt: "What were you feeling, and what could you do differently tomorrow?",
            quiz: (0..<5).map { i in
                QuizQuestion(q: "Q\(i+1)?", options: ["A", "B", "C", "D"])
            },
            stepsCompleted: stepsCompleted, quizScore: nil, essayText: nil,
            status: status, parentNote: nil, submittedAt: nil, approvedAt: nil,
        )
    }
}

extension ChildStateResponse {
    static func fixture(
        tasks: [BigKidTask] = [.fixture()],
        reflection: ReflectionRequest? = nil,
        minutesLeft: Int = 0,
        minutesMax: Int = 120,
        dailyAck: Bool = false,
        timeAck: Bool = false
    ) -> ChildStateResponse {
        ChildStateResponse(
            childName: "Liam",
            minutesLeft: minutesLeft, minutesMax: minutesMax,
            tasks: tasks, reflectionRequest: reflection,
            notifyParentCooldownEndsAt: nil,
            dailyCompleteAcknowledged: dailyAck,
            screenTimeFinishedAcknowledged: timeAck,
        )
    }
}
#endif
```

- [ ] **Step 4: Create the `BigKidState` observable model**

Create `Evlin iOS/Evlin iOS/Models/BigKid/BigKidState.swift`:

```swift
import Foundation
import Observation

/// Mirrors `GET /child/state` (spec §4 + §8.1). Routing reads from this
/// (spec §5). Swap an instance whenever a new snapshot arrives from the poller.
@Observable
final class BigKidState {
    // Server-mirrored
    var childName: String
    var minutesLeft: Int
    var minutesMax: Int
    var tasks: [BigKidTask]
    var reflectionRequest: ReflectionRequest?
    var notifyParentCooldownEndsAt: Date?
    var dailyCompleteAcknowledged: Bool
    var screenTimeFinishedAcknowledged: Bool

    // Local-only (UI navigation)
    var currentTaskId: UUID?

    init(snapshot: ChildStateResponse) {
        self.childName = snapshot.childName
        self.minutesLeft = snapshot.minutesLeft
        self.minutesMax = snapshot.minutesMax
        self.tasks = snapshot.tasks
        self.reflectionRequest = snapshot.reflectionRequest
        self.notifyParentCooldownEndsAt = snapshot.notifyParentCooldownEndsAt
        self.dailyCompleteAcknowledged = snapshot.dailyCompleteAcknowledged
        self.screenTimeFinishedAcknowledged = snapshot.screenTimeFinishedAcknowledged
    }

    /// Refresh from a new server snapshot. Preserves local-only UI nav fields.
    func apply(_ snapshot: ChildStateResponse) {
        childName = snapshot.childName
        minutesLeft = snapshot.minutesLeft
        minutesMax = snapshot.minutesMax
        tasks = snapshot.tasks
        reflectionRequest = snapshot.reflectionRequest
        notifyParentCooldownEndsAt = snapshot.notifyParentCooldownEndsAt
        dailyCompleteAcknowledged = snapshot.dailyCompleteAcknowledged
        screenTimeFinishedAcknowledged = snapshot.screenTimeFinishedAcknowledged
    }

    var allTasksDone: Bool {
        tasks.allSatisfy {
            $0.status == .done || $0.bypass?.status == .approved
        }
    }

    func task(id: UUID) -> BigKidTask? {
        tasks.first(where: { $0.id == id })
    }
}
```

- [ ] **Step 5: Run tests — expect pass**

In Xcode: `Cmd+U`. Or:

```bash
xcodebuild test -project "Evlin iOS/Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:Evlin_iOSTests/BigKidModelsTests 2>&1 | tail -20
```

Expected: 3 tests pass.

- [ ] **Step 6: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add "Evlin iOS/Models/BigKid/" "Evlin iOSTests/BigKidModelsTests.swift"
git commit -m "feat(child): big-kid Codable models + BigKidState observable"
```

### Task 3.2: `BigKidAPIClient`

**Files:**
- Create: `Evlin iOS/Evlin iOS/Services/BigKidAPIClient.swift`

- [ ] **Step 1: Write failing test**

Create `Evlin iOSTests/BigKidAPIClientTests.swift`:

```swift
import XCTest
@testable import Evlin_iOS

final class BigKidAPIClientTests: XCTestCase {
    func testGetStateBuildsCorrectRequest() throws {
        let client = BigKidAPIClient(
            baseURL: URL(string: "http://localhost:8000/api/v1")!,
            childId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            session: .stub(),
        )
        let req = try client.makeRequest(path: "/child/state", method: "GET")
        XCTAssertEqual(req.url?.absoluteString, "http://localhost:8000/api/v1/child/state")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Child-Id"),
                       "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(req.httpMethod, "GET")
    }
}

extension URLSession {
    static func stub() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        return URLSession(configuration: config)
    }
}
```

- [ ] **Step 2: Run — expect failure**

```bash
xcodebuild test -project "Evlin iOS/Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:Evlin_iOSTests/BigKidAPIClientTests 2>&1 | tail -10
```

Expected: build fails (`BigKidAPIClient` undefined).

- [ ] **Step 3: Implement the client**

Create `Evlin iOS/Evlin iOS/Services/BigKidAPIClient.swift`:

```swift
import Foundation

/// All `/api/v1/child/*` endpoints from spec §8.
/// Uses `X-Child-Id` header (spec §9) — auth shim for v1.
final class BigKidAPIClient: ObservableObject {
    @Published var baseURL: URL
    let childId: UUID
    private let session: URLSession

    init(baseURL: URL, childId: UUID, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.childId = childId
        self.session = session
    }

    // MARK: - State

    func fetchState() async throws -> ChildStateResponse {
        try await get("/child/state")
    }

    // MARK: - Tasks

    func submitEvidence(taskId: UUID, photoData: Data, note: String?) async throws -> BigKidTask {
        var req = try makeRequest(path: "/child/task/\(taskId)/evidence", method: "POST")
        let boundary = UUID().uuidString
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.multipartBody(boundary: boundary, photoData: photoData, note: note)
        return try await perform(req)
    }

    // MARK: - Bypass

    func submitBypass(taskId: UUID, reason: String) async throws -> BypassRequest {
        let body: [String: Any] = ["task_id": taskId.uuidString, "reason": reason]
        return try await postJSON("/child/bypass", body: body)
    }

    // MARK: - Reflection

    func reflectionStepComplete(rid: UUID, step: BigKidReflectionStep) async throws -> ReflectionRequest {
        try await postJSON("/child/reflection/\(rid)/step-complete", body: ["step": step.rawValue])
    }

    func reflectionQuizAnswer(rid: UUID, questionIndex: Int, selectedIndex: Int) async throws -> QuizAnswerOutcome {
        try await postJSON("/child/reflection/\(rid)/quiz-answer",
                           body: ["question_index": questionIndex, "selected_index": selectedIndex])
    }

    func reflectionEssay(rid: UUID, text: String) async throws -> ReflectionRequest {
        try await postJSON("/child/reflection/\(rid)/essay", body: ["text": text])
    }

    func reflectionNudge(rid: UUID) async throws -> NudgeOutcome {
        try await postJSON("/child/reflection/\(rid)/nudge", body: [:])
    }

    func reflectionAck(rid: UUID) async throws {
        let req = try makeRequest(path: "/child/reflection/\(rid)/ack", method: "POST")
        _ = try await sendVoid(req)
    }

    // MARK: - Day-end acks

    func ackDailyComplete() async throws {
        let req = try makeRequest(path: "/child/daily-complete/ack", method: "POST")
        _ = try await sendVoid(req)
    }

    func ackScreenTimeFinished() async throws {
        let req = try makeRequest(path: "/child/screen-time-finished/ack", method: "POST")
        _ = try await sendVoid(req)
    }

    // MARK: - Time consumption

    func reportTimeUse(minutesUsed: Int) async throws {
        let req = try makeJSONRequest(path: "/child/time-consumption",
                                       method: "POST", body: ["minutes_used": minutesUsed])
        _ = try await sendVoid(req)
    }

    // MARK: - Internal

    func makeRequest(path: String, method: String) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(childId.uuidString, forHTTPHeaderField: "X-Child-Id")
        req.timeoutInterval = 20
        return req
    }

    private func makeJSONRequest(path: String, method: String, body: [String: Any]) throws -> URLRequest {
        var req = try makeRequest(path: path, method: method)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let req = try makeRequest(path: path, method: "GET")
        return try await perform(req)
    }

    private func postJSON<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        let req = try makeJSONRequest(path: path, method: "POST", body: body)
        return try await perform(req)
    }

    private func perform<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, resp) = try await session.data(for: req)
        try Self.validate(resp, data: data)
        return try JSONDecoder.bigKid.decode(T.self, from: data)
    }

    private func sendVoid(_ req: URLRequest) async throws -> Void {
        let (data, resp) = try await session.data(for: req)
        try Self.validate(resp, data: data)
    }

    private static func validate(_ resp: URLResponse, data: Data) throws {
        guard let http = resp as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard 200..<300 ~= http.statusCode else {
            let detail = String(data: data, encoding: .utf8) ?? "<no body>"
            throw BigKidAPIError(status: http.statusCode, detail: detail)
        }
    }

    private static func multipartBody(boundary: String, photoData: Data, note: String?) -> Data {
        var body = Data()
        let crlf = "\r\n"
        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"evidence.jpg\"\(crlf)".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\(crlf)\(crlf)".data(using: .utf8)!)
        body.append(photoData)
        body.append(crlf.data(using: .utf8)!)
        if let note, !note.isEmpty {
            body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"note\"\(crlf)\(crlf)".data(using: .utf8)!)
            body.append(note.data(using: .utf8)!)
            body.append(crlf.data(using: .utf8)!)
        }
        body.append("--\(boundary)--\(crlf)".data(using: .utf8)!)
        return body
    }
}

struct BigKidAPIError: Error, CustomStringConvertible {
    let status: Int
    let detail: String
    var description: String { "BigKidAPIError(\(status)): \(detail)" }
}

struct QuizAnswerOutcome: Codable, Equatable, Sendable {
    let correct: Bool
    let allCorrect: Bool
    let score: Int
}

struct NudgeOutcome: Codable, Equatable, Sendable {
    let endsAt: Date
}
```

- [ ] **Step 4: Run test — expect pass**

```bash
xcodebuild test -project "Evlin iOS/Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:Evlin_iOSTests/BigKidAPIClientTests 2>&1 | tail -10
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add "Evlin iOS/Services/BigKidAPIClient.swift" "Evlin iOSTests/BigKidAPIClientTests.swift"
git commit -m "feat(child): BigKidAPIClient covering all /child endpoints"
```

### Task 3.3: `BigKidStatePoller`

**Files:**
- Create: `Evlin iOS/Evlin iOS/Services/BigKidStatePoller.swift`

- [ ] **Step 1: Implement poller**

Polling cadence per spec §8: 60s while foregrounded, immediate on resume.

```swift
import Foundation
import SwiftUI

/// Polls `/child/state` every 60s while app is foregrounded; refreshes
/// immediately on `scenePhase == .active` transitions. Hands snapshots
/// to `BigKidState` via the `apply(_:)` method.
@MainActor
final class BigKidStatePoller: ObservableObject {
    @Published var lastError: String?
    @Published var lastFetchedAt: Date?

    private let client: BigKidAPIClient
    private let state: BigKidState
    private var task: Task<Void, Never>?

    init(client: BigKidAPIClient, state: BigKidState) {
        self.client = client
        self.state = state
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Force an immediate refresh (e.g. on scenePhase change or after a write).
    func refreshNow() async {
        await fetchOnce()
    }

    private func runLoop() async {
        while !Task.isCancelled {
            await fetchOnce()
            try? await Task.sleep(nanoseconds: 60_000_000_000)  // 60s
        }
    }

    private func fetchOnce() async {
        do {
            let snapshot = try await client.fetchState()
            state.apply(snapshot)
            lastFetchedAt = Date()
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }
}
```

- [ ] **Step 2: Build the project**

```bash
xcodebuild -project "Evlin iOS/Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination 'generic/platform=iOS' build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Services/BigKidStatePoller.swift"
git commit -m "feat(child): BigKidStatePoller — 60s loop + manual refresh"
```

### Task 3.4: Wire a developer harness — render real state

**Files:**
- Create: `Evlin iOS/Evlin iOS/Views/Child/BigKid/BigKidDevHarnessView.swift`

- [ ] **Step 1: Render JSON snapshot in a debug view**

```swift
import SwiftUI

#if DEBUG
struct BigKidDevHarnessView: View {
    @StateObject private var client = BigKidAPIClient(
        baseURL: URL(string: "http://localhost:8000/api/v1")!,
        childId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
    )
    @State private var state = BigKidState(snapshot: .fixture())
    @State private var poller: BigKidStatePoller?
    @State private var raw: String = "(loading…)"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("BigKid dev harness").font(.title2).bold()
                Text("Tasks: \(state.tasks.count)")
                Text("Minutes left: \(state.minutesLeft) / \(state.minutesMax)")
                Text("All tasks done: \(state.allTasksDone ? "YES" : "no")")
                Text("Reflection: \(state.reflectionRequest?.status.rawValue ?? "none")")
                Divider()
                Text(raw).font(.system(size: 11, design: .monospaced))
            }
            .padding()
        }
        .task {
            let p = BigKidStatePoller(client: client, state: state)
            poller = p
            p.start()
        }
        .task {
            // also fetch once and dump JSON for visibility
            do {
                let snapshot = try await client.fetchState()
                let data = try JSONEncoder.bigKid.encode(snapshot)
                raw = String(data: data, encoding: .utf8) ?? "<decode failed>"
            } catch {
                raw = "ERROR: \(error)"
            }
        }
    }
}

#Preview { BigKidDevHarnessView() }
#endif
```

- [ ] **Step 2: Run the backend (Phase 2 Task 2.7) + open this preview**

In Xcode, open the file, click the preview canvas, hit refresh. With backend on `localhost:8000`, the preview should show "Tasks: 3", "Minutes left: 0 / 120", "All tasks done: no", "Reflection: none". The raw JSON dump should appear at the bottom.

- [ ] **Step 3: Trigger a reflection from terminal and re-run preview**

```bash
curl -s -X POST http://localhost:8000/api/v1/parent/reflection/trigger \
     -H "Content-Type: application/json" \
     -d '{"child_id":"11111111-1111-1111-1111-111111111111","reason":"dev test"}'
```

Refresh the preview. Expected: "Reflection: pending" + JSON now contains `reflection_request`.

- [ ] **Step 4: Commit**

```bash
git add "Evlin iOS/Views/Child/BigKid/BigKidDevHarnessView.swift"
git commit -m "feat(child): dev harness preview hitting local backend"
```

---

## Phase 4: Routing — `BigKidRootView`

Goal: implement the routing rules from spec §5 in a single switch, with a deterministic test for every branch. Do this before any screens exist — use placeholder views so the routing logic gets exercised first.

### Task 4.1: Routing decision pure function + tests

**Files:**
- Create: `Evlin iOS/Evlin iOS/Views/Child/BigKid/BigKidRoute.swift`

- [ ] **Step 1: Define the route enum + pure decision function**

```swift
import Foundation

enum BigKidRoute: Equatable {
    case home
    case homeReflectionA       // reflection in progress (stepsCompleted < 3)
    case homeReflectionB       // reflection 3/3 done, awaiting parent
    case complete              // reflection approved by parent, awaiting kid ack
    case dailyComplete
    case screenTimeFinished
}

enum BigKidRouter {
    /// Pure routing decision per spec §5. Inputs are server-mirrored fields
    /// from `BigKidState`; nothing local.
    static func route(_ s: BigKidState) -> BigKidRoute {
        if let req = s.reflectionRequest, req.status == .approved {
            return .complete
        }
        if let req = s.reflectionRequest {
            return req.stepsCompleted.count >= 3 ? .homeReflectionB : .homeReflectionA
        }
        if s.allTasksDone, s.minutesLeft <= 0, !s.screenTimeFinishedAcknowledged {
            return .screenTimeFinished
        }
        if s.allTasksDone, !s.dailyCompleteAcknowledged {
            return .dailyComplete
        }
        return .home
    }
}
```

- [ ] **Step 2: Write tests for every branch**

Create `Evlin iOSTests/BigKidRouterTests.swift`:

```swift
import XCTest
@testable import Evlin_iOS

final class BigKidRouterTests: XCTestCase {
    func testHomeWhenNothingActive() {
        let s = BigKidState(snapshot: .fixture(tasks: [.fixture(status: .todo)]))
        XCTAssertEqual(BigKidRouter.route(s), .home)
    }

    func testHomeReflectionAWhileInProgress() {
        let r = ReflectionRequest.fixture(status: .pending,
                                          stepsCompleted: [.video])
        let s = BigKidState(snapshot: .fixture(reflection: r))
        XCTAssertEqual(BigKidRouter.route(s), .homeReflectionA)
    }

    func testHomeReflectionBWhenAllStepsDone() {
        let r = ReflectionRequest.fixture(status: .submitted,
                                          stepsCompleted: [.video, .quiz, .writing])
        let s = BigKidState(snapshot: .fixture(reflection: r))
        XCTAssertEqual(BigKidRouter.route(s), .homeReflectionB)
    }

    func testCompleteWhenApprovedNotAcked() {
        let r = ReflectionRequest.fixture(status: .approved,
                                          stepsCompleted: [.video, .quiz, .writing])
        let s = BigKidState(snapshot: .fixture(reflection: r))
        XCTAssertEqual(BigKidRouter.route(s), .complete)
    }

    func testDailyCompleteWhenAllTasksDoneNotAcked() {
        let s = BigKidState(snapshot: .fixture(
            tasks: [.fixture(status: .done)],
            minutesLeft: 120, dailyAck: false,
        ))
        XCTAssertEqual(BigKidRouter.route(s), .dailyComplete)
    }

    func testHomeOnceDailyCompleteAcked() {
        let s = BigKidState(snapshot: .fixture(
            tasks: [.fixture(status: .done)],
            minutesLeft: 120, dailyAck: true,
        ))
        XCTAssertEqual(BigKidRouter.route(s), .home)
    }

    func testScreenTimeFinishedWhenZeroMinutes() {
        let s = BigKidState(snapshot: .fixture(
            tasks: [.fixture(status: .done)],
            minutesLeft: 0, dailyAck: true, timeAck: false,
        ))
        XCTAssertEqual(BigKidRouter.route(s), .screenTimeFinished)
    }

    func testHomeOnceScreenTimeFinishedAcked() {
        let s = BigKidState(snapshot: .fixture(
            tasks: [.fixture(status: .done)],
            minutesLeft: 0, dailyAck: true, timeAck: true,
        ))
        XCTAssertEqual(BigKidRouter.route(s), .home)
    }

    func testApprovedBypassCountsTowardAllDone() {
        let s = BigKidState(snapshot: .fixture(
            tasks: [.fixture(status: .todo, bypass: .fixture(status: .approved))],
            minutesLeft: 120, dailyAck: false,
        ))
        XCTAssertEqual(BigKidRouter.route(s), .dailyComplete)
    }

    func testReflectionApprovedTakesPriorityOverDailyComplete() {
        let r = ReflectionRequest.fixture(status: .approved,
                                          stepsCompleted: [.video, .quiz, .writing])
        let s = BigKidState(snapshot: .fixture(
            tasks: [.fixture(status: .done)],
            reflection: r, minutesLeft: 120, dailyAck: false,
        ))
        XCTAssertEqual(BigKidRouter.route(s), .complete)
    }
}
```

- [ ] **Step 3: Run tests — expect pass**

```bash
xcodebuild test -project "Evlin iOS/Evlin iOS.xcodeproj" -scheme "Evlin iOS" -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:Evlin_iOSTests/BigKidRouterTests 2>&1 | tail -10
```

Expected: 10 tests pass.

- [ ] **Step 4: Commit**

```bash
git add "Evlin iOS/Views/Child/BigKid/BigKidRoute.swift" "Evlin iOSTests/BigKidRouterTests.swift"
git commit -m "feat(child): BigKidRouter pure routing function with full branch coverage"
```

### Task 4.2: `BigKidRootView` with placeholder destinations

**Files:**
- Create: `Evlin iOS/Evlin iOS/Views/Child/BigKid/BigKidRootView.swift`

- [ ] **Step 1: Create root view that switches on route**

```swift
import SwiftUI

/// Top-level view for big-kid mode. Picks one of the eleven screens based on
/// the current `BigKidState` per spec §5.
struct BigKidRootView: View {
    @State private var state: BigKidState
    @StateObject private var client: BigKidAPIClient
    @StateObject private var poller: BigKidStatePoller
    @Environment(\.scenePhase) private var scenePhase

    init(baseURL: URL, childId: UUID) {
        let client = BigKidAPIClient(baseURL: baseURL, childId: childId)
        let initialState = BigKidState(snapshot: .fixture())
        let poller = BigKidStatePoller(client: client, state: initialState)
        _client = StateObject(wrappedValue: client)
        _state = State(initialValue: initialState)
        _poller = StateObject(wrappedValue: poller)
    }

    var body: some View {
        Group {
            switch BigKidRouter.route(state) {
            case .home:
                BigKidHomePlaceholderView()
            case .homeReflectionA:
                Text("HomeReflection A").bold()
            case .homeReflectionB:
                Text("HomeReflection B").bold()
            case .complete:
                Text("CompleteScreen").bold()
            case .dailyComplete:
                Text("DailyComplete").bold()
            case .screenTimeFinished:
                Text("ScreenTimeFinished").bold()
            }
        }
        .environment(state)
        .environmentObject(client)
        .environmentObject(poller)
        .onAppear { poller.start() }
        .onDisappear { poller.stop() }
        .onChange(of: scenePhase) { _, new in
            if new == .active {
                Task { await poller.refreshNow() }
            }
        }
    }
}

private struct BigKidHomePlaceholderView: View {
    @Environment(BigKidState.self) private var state

    var body: some View {
        VStack(spacing: 12) {
            Text("Hi, \(state.childName)").font(.title)
            Text("\(state.tasks.count) tasks, \(state.minutesLeft)/\(state.minutesMax) min")
        }
    }
}

#if DEBUG
#Preview("Local backend") {
    BigKidRootView(
        baseURL: URL(string: "http://localhost:8000/api/v1")!,
        childId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
    )
}
#endif
```

- [ ] **Step 2: Build + open the preview**

Expected: with backend running, the placeholder home shows "Hi, Liam" + "3 tasks, 0/120 min". Trigger a reflection via curl; the preview should switch to "HomeReflection A".

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Views/Child/BigKid/BigKidRootView.swift"
git commit -m "feat(child): BigKidRootView with route switch and placeholder destinations"
```

---

## Phase 5: Home + HomeReflection

The visual port begins. Each task references the JSX file + section. **Open the JSX file in a side window when implementing.**

### Task 5.1: `TaskRow` reusable view

**Source of truth:** `home.jsx` lines 71–174 (`TaskRow`) + `home-reflection.jsx` lines 5–95 (`TaskRowReflection` — brown variant).

**Files:**
- Create: `Evlin iOS/Evlin iOS/Components/Kid/EvKidTaskRow.swift`

- [ ] **Step 1: Build the row in green palette**

```swift
import SwiftUI

struct EvKidTaskRow: View {
    enum Palette { case green, brown }

    let task: BigKidTask
    let palette: Palette
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                checkCircle
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.title)
                        .font(.system(size: 16, weight: .bold))
                        .tracking(EvlinKidMetrics.Letter.body)
                        .foregroundStyle(titleColor)
                        .strikethrough(task.status == .done, color: titleStrikeColor)
                        .opacity(task.status == .done ? 0.55 : 1)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        categoryChip
                        if task.status == .submitted {
                            Label("evidence", systemImage: "camera.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(submittedColor)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    if let due = task.due, task.status != .done {
                        Text("Due \(due)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(dueColor)
                    }
                }
                Spacer(minLength: 0)
                statusChip
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(rowBg)
            .clipShape(RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.row))
            .overlay(
                RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.row)
                    .stroke(rowBorderColor, lineWidth: rowBorderWidth)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var checkCircle: some View {
        if task.status == .done {
            ZStack {
                Circle().fill(palette == .green ? EvlinKidColors.green500 : EvlinKidColors.Reflection.checkBg)
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: EvlinKidMetrics.Size.taskCheckCircle,
                   height: EvlinKidMetrics.Size.taskCheckCircle)
        } else {
            Circle()
                .stroke(checkStrokeColor, lineWidth: 2)
                .background(Circle().fill(.white))
                .frame(width: EvlinKidMetrics.Size.taskCheckCircle,
                       height: EvlinKidMetrics.Size.taskCheckCircle)
        }
    }

    @ViewBuilder
    private var categoryChip: some View {
        let (bg, fg) = categoryColors
        let emoji = categoryEmoji
        Text("\(emoji) \(task.category.rawValue)")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(fg)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(bg, in: Capsule())
    }

    @ViewBuilder
    private var statusChip: some View {
        switch task.status {
        case .done:
            chip(text: "Done", bg: doneChipBg, fg: doneChipFg)
        case .submitted:
            chip(text: "Submitted", bg: submittedChipBg, fg: submittedChipFg)
        case .overdue:
            chip(text: "!", bg: overdueChipBg, fg: overdueChipFg)
        case .todo:
            chip(text: "To do", bg: todoChipBg, fg: todoChipFg)
        }
    }

    private func chip(text: String, bg: Color, fg: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .tracking(0.1)
            .foregroundStyle(fg)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(bg, in: Capsule())
    }

    // MARK: - Per-palette colors (mirrors home.jsx vs home-reflection.jsx)

    private var titleColor: Color {
        palette == .green ? EvlinKidColors.ink : Color(red: 46/255, green: 31/255, blue: 8/255)
    }
    private var titleStrikeColor: Color {
        palette == .green ? EvlinKidColors.ink4 : Color(red: 183/255, green: 147/255, blue: 94/255)
    }
    private var submittedColor: Color {
        palette == .green ? EvlinKidColors.green600 : Color(red: 110/255, green: 79/255, blue: 38/255)
    }
    private var dueColor: Color {
        // home.jsx line 138: overdue = '#C8324A', else ink3
        if task.status == .overdue { return Color(red: 200/255, green: 50/255, blue: 74/255) }
        return palette == .green ? EvlinKidColors.ink3 : Color(red: 110/255, green: 79/255, blue: 38/255)
    }
    private var checkStrokeColor: Color {
        if task.status == .overdue {
            return palette == .green ? EvlinKidColors.green500 : Color(red: 110/255, green: 79/255, blue: 38/255)
        }
        return palette == .green ? EvlinKidColors.ink4 : EvlinKidColors.Reflection.cardBorder
    }
    private var rowBg: Color {
        if task.status == .done {
            return palette == .green ? EvlinKidColors.surface2 : EvlinKidColors.Reflection.rowBgDone
        }
        if task.status == .submitted {
            return palette == .green ? EvlinKidColors.green50 : EvlinKidColors.Reflection.rowBgSubmitted
        }
        return .white
    }
    private var rowBorderColor: Color {
        if task.status == .submitted {
            return palette == .green ? EvlinKidColors.green200 : EvlinKidColors.Reflection.cardBorder
        }
        if task.status == .overdue {
            return palette == .green ? EvlinKidColors.green400 : Color(red: 154/255, green: 115/255, blue: 64/255)
        }
        return palette == .green ? EvlinKidColors.line : EvlinKidColors.Reflection.rowBorder
    }
    private var rowBorderWidth: CGFloat {
        task.status == .overdue ? 1.5 : 1
    }
    private var categoryColors: (bg: Color, fg: Color) {
        // home.jsx CAT_STYLE lines 7–11
        switch (task.category, palette) {
        case (.chores, .green):    return (EvlinKidColors.green100, EvlinKidColors.green700)
        case (.homework, .green):  return (Color(red: 228/255, green: 236/255, blue: 251/255),
                                          Color(red:  46/255, green:  78/255, blue: 147/255))
        case (.selfCare, .green):  return (Color(red: 253/255, green: 231/255, blue: 238/255),
                                          Color(red: 177/255, green:  58/255, blue: 100/255))
        case (_, .brown):          return (EvlinKidColors.Reflection.chipBg, EvlinKidColors.Reflection.chipFg)
        }
    }
    private var categoryEmoji: String {
        switch task.category { case .chores: "🧹"; case .homework: "📚"; case .selfCare: "💗" }
    }
    private var doneChipBg: Color { palette == .green ? EvlinKidColors.green100 : EvlinKidColors.Reflection.chipBg }
    private var doneChipFg: Color { palette == .green ? EvlinKidColors.green700 : EvlinKidColors.Reflection.chipFg }
    private var submittedChipBg: Color { palette == .green ? EvlinKidColors.green50 : Color(red: 244/255, green: 232/255, blue: 214/255) }
    private var submittedChipFg: Color { palette == .green ? EvlinKidColors.green600 : Color(red: 110/255, green: 79/255, blue: 38/255) }
    private var overdueChipBg: Color { palette == .green ? EvlinKidColors.green200 : Color(red: 212/255, green: 181/255, blue: 132/255) }
    private var overdueChipFg: Color { palette == .green ? EvlinKidColors.green800 : Color(red: 46/255, green: 31/255, blue: 8/255) }
    private var todoChipBg: Color { palette == .green ? EvlinKidColors.surface2 : Color(red: 244/255, green: 232/255, blue: 214/255) }
    private var todoChipFg: Color { palette == .green ? EvlinKidColors.ink3 : Color(red: 110/255, green: 79/255, blue: 38/255) }
}

#if DEBUG
#Preview("Green") {
    VStack(spacing: 10) {
        EvKidTaskRow(task: .fixture(status: .todo), palette: .green) {}
        EvKidTaskRow(task: .fixture(status: .submitted), palette: .green) {}
        EvKidTaskRow(task: .fixture(status: .done), palette: .green) {}
        EvKidTaskRow(task: .fixture(status: .overdue), palette: .green) {}
    }
    .padding()
}
#Preview("Brown") {
    VStack(spacing: 10) {
        EvKidTaskRow(task: .fixture(status: .todo), palette: .brown) {}
        EvKidTaskRow(task: .fixture(status: .submitted), palette: .brown) {}
        EvKidTaskRow(task: .fixture(status: .done), palette: .brown) {}
    }
    .padding()
    .background(EvlinKidColors.Reflection.bgSurface)
}
#endif
```

- [ ] **Step 2: Visual diff against JSX**

Open `home.jsx` in a side window. Render the SwiftUI preview. Spot-check: padding 14×16, radius 18, chip pill, check circle 30×30. Any deviation = adjust the SwiftUI to match. Repeat for the brown variant against `home-reflection.jsx`.

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Components/Kid/EvKidTaskRow.swift"
git commit -m "feat(child): EvKidTaskRow with green + brown palettes (home.jsx + home-reflection.jsx port)"
```

### Task 5.2: `BigKidHomeView` (variant A)

**Source of truth:** `home.jsx` lines 176–343 (`HomeScreenA`).

**Files:**
- Create: `Evlin iOS/Evlin iOS/Views/Child/BigKid/BigKidHomeView.swift`

- [ ] **Step 1: Greeting + tasks header + quest pips + task list**

```swift
import SwiftUI

struct BigKidHomeView: View {
    @Environment(BigKidState.self) private var state
    var onTaskTap: (BigKidTask) -> Void

    private var doneCount: Int {
        state.tasks.filter { $0.status == .done || $0.bypass?.status == .approved }.count
    }
    private var allDone: Bool { state.allTasksDone }
    private var outOfTime: Bool { allDone && state.minutesLeft <= 0 }
    private var showTimeHero: Bool { allDone }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                greeting
                heroCard.padding(.bottom, 22)
                tasksHeader.padding(.bottom, 10)
                questPips.padding(.bottom, 14)
                taskList
            }
            .padding(.horizontal, EvlinKidMetrics.Padding.screenH)
            .padding(.top, EvlinKidMetrics.Padding.screenTop)
            .padding(.bottom, 40)
        }
        .background(EvlinKidColors.surface2.ignoresSafeArea())
    }

    private var greeting: some View {
        Text("Hi, \(state.childName.split(separator: " ").first ?? "there")")
            .font(.system(size: 22, weight: .heavy))
            .tracking(EvlinKidMetrics.Letter.mediumTitle)
            .foregroundStyle(EvlinKidColors.ink)
            .padding(.vertical, 8)
            .padding(.bottom, 10)
    }

    @ViewBuilder
    private var heroCard: some View {
        if outOfTime {
            outOfTimeCard
        } else if showTimeHero {
            timeLeftCard
        } else {
            lockedCard
        }
    }

    private var lockedCard: some View {
        EvKidCard(tone: .tinted, padding: 22) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(EvlinKidColors.green100)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(EvlinKidColors.green700)
                }
                .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("SCREEN TIME LOCKED")
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(1)
                        .foregroundStyle(EvlinKidColors.green700)
                    Text("Finish today's tasks to unlock")
                        .font(.system(size: 16, weight: .bold))
                        .tracking(EvlinKidMetrics.Letter.body)
                        .foregroundStyle(EvlinKidColors.ink)
                    Text("\(state.tasks.count - doneCount) \(state.tasks.count - doneCount == 1 ? "task" : "tasks") left")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(EvlinKidColors.ink3)
                }
                Spacer(minLength: 0)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.card)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                .foregroundStyle(EvlinKidColors.green300)
        )
    }

    private var timeLeftCard: some View {
        // home.jsx lines 204–245
        let mode = TimeMode(minutesLeft: state.minutesLeft, max: state.minutesMax)
        return EvKidCard(padding: 22) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("SCREEN TIME LEFT")
                        .font(.system(size: 13, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(EvlinKidColors.ink3)
                    Spacer()
                    EvKidChip(mode.label, tone: mode.chipTone)
                }
                .padding(.bottom, 6)
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text("\(mode.bigNumber)")
                        .font(.system(size: 76, weight: .heavy))
                        .tracking(-3)
                        .foregroundStyle(mode.fg)
                        .monospacedDigit()
                    Text(mode.smallText)
                        .font(.system(size: 28, weight: .bold))
                        .tracking(-0.8)
                        .foregroundStyle(EvlinKidColors.ink2)
                }
                .padding(.vertical, 10)
                EvKidProgressBar(value: Double(state.minutesLeft),
                                 max: Double(state.minutesMax),
                                 tone: mode.barTone, height: 14)
                HStack {
                    Text("\(state.minutesMax - state.minutesLeft) min used")
                    Spacer()
                    Text("\(state.minutesMax) min today")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(EvlinKidColors.ink3)
                .padding(.top, 8)
            }
        }
    }

    private var outOfTimeCard: some View {
        // home.jsx lines 278–301
        EvKidCard(padding: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ALL USED UP")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.75))
                Text("That's it for today")
                    .font(.system(size: 24, weight: .heavy))
                    .tracking(-0.6)
                    .foregroundStyle(.white)
                Text("Devices come back tomorrow at 7:00 AM →")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .background(
            LinearGradient(
                colors: [EvlinKidColors.green700, EvlinKidColors.green800],
                startPoint: .topLeading, endPoint: .bottomTrailing,
            )
            .clipShape(RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.card))
        )
    }

    private var tasksHeader: some View {
        HStack {
            Text("Today's tasks")
                .font(.system(size: 20, weight: .heavy))
                .tracking(-0.4)
                .foregroundStyle(EvlinKidColors.ink)
            Spacer()
            HStack(spacing: 5) {
                if allDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(EvlinKidColors.green600)
                }
                Text("\(doneCount) of \(state.tasks.count) done")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(allDone ? EvlinKidColors.green600 : EvlinKidColors.ink2)
            }
        }
        .padding(.horizontal, 4)
    }

    private var questPips: some View {
        HStack(spacing: 5) {
            ForEach(state.tasks) { t in
                Capsule().fill(pipColor(for: t)).frame(height: EvlinKidMetrics.Size.segPip)
            }
        }
        .padding(.horizontal, 4)
    }

    private func pipColor(for t: BigKidTask) -> Color {
        if t.status == .done || t.bypass?.status == .approved { return EvlinKidColors.green500 }
        if t.status == .submitted { return EvlinKidColors.green300 }
        return EvlinKidColors.line
    }

    private var taskList: some View {
        VStack(spacing: EvlinKidMetrics.Padding.listGap) {
            ForEach(state.tasks) { t in
                EvKidTaskRow(task: t, palette: .green) { onTaskTap(t) }
            }
        }
    }
}

private struct TimeMode {
    let bigNumber: Int
    let smallText: String
    let label: String
    let chipTone: EvKidChip.Tone
    let barTone: EvKidProgressBar.Tone
    let fg: Color

    init(minutesLeft m: Int, max: Int) {
        let ratio = Double(m) / Double(max)
        if m >= 60 {
            bigNumber = m / 60
            let r = m % 60
            smallText = r == 0 ? "h" : "h \(r)m"
        } else {
            bigNumber = m; smallText = "min"
        }
        if ratio > 0.5 {
            label = "Plenty left"; chipTone = .green; barTone = .primary; fg = EvlinKidColors.green500
        } else if ratio > 0.2 {
            label = "Going down"; chipTone = .amber; barTone = .amber;   fg = EvlinKidColors.green600
        } else {
            label = "Almost out"; chipTone = .red;   barTone = .red;     fg = EvlinKidColors.green700
        }
    }
}

#if DEBUG
#Preview("Locked") {
    BigKidHomeView { _ in }
        .environment(BigKidState(snapshot: .fixture()))
}
#Preview("All done, plenty left") {
    BigKidHomeView { _ in }
        .environment(BigKidState(snapshot: .fixture(
            tasks: [.fixture(status: .done), .fixture(status: .done), .fixture(status: .done)],
            minutesLeft: 95, minutesMax: 120,
        )))
}
#Preview("Out of time") {
    BigKidHomeView { _ in }
        .environment(BigKidState(snapshot: .fixture(
            tasks: [.fixture(status: .done)], minutesLeft: 0, minutesMax: 120,
        )))
}
#endif
```

- [ ] **Step 2: Visual parity against `home.jsx` HomeScreenA**

Run the prototype at `http://localhost:8001/Evlin Student.html`, walk through each of the three states (locked / time-left / out-of-time). Compare to the SwiftUI previews. Adjust spacing/typography until indistinguishable.

- [ ] **Step 3: Wire into root view**

Replace the `BigKidHomePlaceholderView` in `BigKidRootView.swift` with `BigKidHomeView { task in /* TODO Phase 6 task detail nav */ }`. Build.

- [ ] **Step 4: Commit**

```bash
git add "Evlin iOS/Views/Child/BigKid/BigKidHomeView.swift" "Evlin iOS/Views/Child/BigKid/BigKidRootView.swift"
git commit -m "feat(child): BigKidHomeView (variant A) — full home.jsx port"
```

### Task 5.3: `BigKidHomeReflectionView` — State A and State B

**Source of truth:** `home-reflection.jsx` lines 97–204 (`HomeReflectionScreen`) for State A. State B is a divergence per spec §6.2.

**Files:**
- Create: `Evlin iOS/Evlin iOS/Views/Child/BigKid/BigKidHomeReflectionView.swift`

- [ ] **Step 1: State A — port HomeReflectionScreen**

```swift
import SwiftUI

struct BigKidHomeReflectionView: View {
    enum SubState { case a, b }

    @Environment(BigKidState.self) private var state
    let subState: SubState
    var onStartReflection: () -> Void
    var onTaskTap: (BigKidTask) -> Void
    var onNudgeParent: () -> Void

    private var doneCount: Int {
        state.tasks.filter { $0.status == .done || $0.bypass?.status == .approved }.count
    }
    private var allDone: Bool { state.allTasksDone }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                greeting
                heroCard.padding(.bottom, 22)
                tasksHeader.padding(.bottom, 10)
                questPips.padding(.bottom, 14)
                taskList
            }
            .padding(.horizontal, EvlinKidMetrics.Padding.screenH)
            .padding(.top, EvlinKidMetrics.Padding.screenTop)
            .padding(.bottom, 40)
        }
        .background(EvlinKidColors.Reflection.bgSurface.ignoresSafeArea())
    }

    private var greeting: some View {
        Text("Hi, \(state.childName.split(separator: " ").first ?? "there")")
            .font(.system(size: 22, weight: .heavy))
            .tracking(EvlinKidMetrics.Letter.mediumTitle)
            .foregroundStyle(EvlinKidColors.Reflection.titleText)
            .padding(.vertical, 8)
            .padding(.bottom, 10)
    }

    private var heroCard: some View {
        // home-reflection.jsx lines 117–163
        ZStack(alignment: .topLeading) {
            EvlinKidColors.Reflection.cardBg
            // decorative dot
            Circle().fill(EvlinKidColors.Reflection.cardAccent)
                .frame(width: 120, height: 120)
                .offset(x: 220, y: -30)
                .clipped()
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(EvlinKidColors.Reflection.iconBg)
                        Image(systemName: "lock.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(EvlinKidColors.Reflection.labelText)
                    }
                    .frame(width: 38, height: 38)
                    Text("SCREEN TIME LOCKED")
                        .font(.system(size: 13, weight: .heavy))
                        .tracking(0.8)
                        .foregroundStyle(EvlinKidColors.Reflection.labelText)
                }
                .padding(.bottom, 10)
                Text(headline)
                    .font(.system(size: 22, weight: .heavy))
                    .tracking(-0.5)
                    .foregroundStyle(EvlinKidColors.Reflection.titleText)
                    .padding(.bottom, 6)
                Text(body)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(EvlinKidColors.Reflection.bodyText)
                    .padding(.bottom, 16)
                ctaButton
            }
            .padding(22)
        }
        .clipShape(RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.card)
                .stroke(EvlinKidColors.Reflection.cardBorder, lineWidth: 1)
        )
    }

    private var headline: String {
        switch subState {
        case .a: "Finish Reflection to unlock phone"
        case .b: "You finished — nice work."
        }
    }

    private var body: String {
        switch subState {
        case .a: "Your screen time is paused until you complete a quick reflection."
        case .b: "Your parent will take a look soon. Once they're happy with it, you'll get your screen time back."
        }
    }

    @ViewBuilder
    private var ctaButton: some View {
        switch subState {
        case .a:
            startButton(title: "Start Reflection", action: onStartReflection)
        case .b:
            nudgeButton
        }
    }

    private func startButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 15, weight: .heavy))
                    .tracking(0.2)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .heavy))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(EvlinKidColors.Reflection.buttonBg, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var nudgeButton: some View {
        let endsAt = state.notifyParentCooldownEndsAt
        let now = Date()
        if let endsAt, endsAt > now {
            CooldownLabel(endsAt: endsAt)
        } else {
            startButton(title: "Give them a nudge", action: onNudgeParent)
        }
    }

    private var tasksHeader: some View {
        HStack {
            Text("Today's tasks")
                .font(.system(size: 20, weight: .heavy))
                .tracking(-0.4)
                .foregroundStyle(EvlinKidColors.Reflection.titleText)
            Spacer()
            HStack(spacing: 5) {
                if allDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(EvlinKidColors.Reflection.labelText)
                }
                Text("\(doneCount) of \(state.tasks.count) done")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(allDone ? EvlinKidColors.Reflection.labelText : EvlinKidColors.Reflection.bodyText)
            }
        }
        .padding(.horizontal, 4)
    }

    private var questPips: some View {
        HStack(spacing: 5) {
            ForEach(state.tasks) { t in
                Capsule().fill(pipColor(for: t)).frame(height: EvlinKidMetrics.Size.segPip)
            }
        }
        .padding(.horizontal, 4)
    }

    private func pipColor(for t: BigKidTask) -> Color {
        if t.status == .done || t.bypass?.status == .approved { return EvlinKidColors.Reflection.pipDone }
        if t.status == .submitted { return EvlinKidColors.Reflection.pipSubmitted }
        return EvlinKidColors.Reflection.pipTodo
    }

    private var taskList: some View {
        VStack(spacing: EvlinKidMetrics.Padding.listGap) {
            ForEach(state.tasks) { t in
                EvKidTaskRow(task: t, palette: .brown) { onTaskTap(t) }
            }
        }
    }
}

private struct CooldownLabel: View {
    let endsAt: Date
    @State private var remaining: TimeInterval = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack {
            Text("Just sent — try again in \(format(remaining))")
                .font(.system(size: 15, weight: .heavy))
                .tracking(0.2)
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .background(EvlinKidColors.Reflection.buttonBg.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 14))
        .onAppear { remaining = max(0, endsAt.timeIntervalSinceNow) }
        .onReceive(timer) { _ in remaining = max(0, endsAt.timeIntervalSinceNow) }
    }

    private func format(_ s: TimeInterval) -> String {
        let total = Int(s)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

#if DEBUG
#Preview("State A") {
    BigKidHomeReflectionView(
        subState: .a,
        onStartReflection: {}, onTaskTap: { _ in }, onNudgeParent: {},
    )
    .environment(BigKidState(snapshot: .fixture(
        reflection: .fixture(stepsCompleted: []),
    )))
}
#Preview("State B (idle)") {
    BigKidHomeReflectionView(
        subState: .b,
        onStartReflection: {}, onTaskTap: { _ in }, onNudgeParent: {},
    )
    .environment(BigKidState(snapshot: .fixture(
        reflection: .fixture(status: .submitted, stepsCompleted: [.video, .quiz, .writing]),
    )))
}
#Preview("State B (cooldown)") {
    let snap = ChildStateResponse(
        childName: "Liam", minutesLeft: 0, minutesMax: 120,
        tasks: [.fixture(status: .todo)],
        reflectionRequest: .fixture(status: .submitted, stepsCompleted: [.video, .quiz, .writing]),
        notifyParentCooldownEndsAt: Date().addingTimeInterval(3 * 60 + 14),
        dailyCompleteAcknowledged: false, screenTimeFinishedAcknowledged: false,
    )
    return BigKidHomeReflectionView(
        subState: .b,
        onStartReflection: {}, onTaskTap: { _ in }, onNudgeParent: {},
    )
    .environment(BigKidState(snapshot: snap))
}
#endif
```

- [ ] **Step 2: Visual parity for State A against `home-reflection.jsx`**

Render the brown prototype, compare against the State A preview. Verify hero card brown values (`#E4CBA1` bg, `#B7935E` border), button tone (`#2E1F08`), task row brown variants.

- [ ] **Step 3: Wire to root view**

In `BigKidRootView.swift`, replace the State A and State B placeholders:

```swift
case .homeReflectionA:
    BigKidHomeReflectionView(
        subState: .a,
        onStartReflection: { /* TODO Phase 7 nav to LockedScreen */ },
        onTaskTap: { _ in /* TODO Phase 6 */ },
        onNudgeParent: { /* not used in State A */ },
    )
case .homeReflectionB:
    BigKidHomeReflectionView(
        subState: .b,
        onStartReflection: {},
        onTaskTap: { _ in },
        onNudgeParent: {
            Task {
                guard let rid = state.reflectionRequest?.id else { return }
                _ = try? await client.reflectionNudge(rid: rid)
                await poller.refreshNow()
            }
        },
    )
```

- [ ] **Step 4: Commit**

```bash
git add "Evlin iOS/Views/Child/BigKid/BigKidHomeReflectionView.swift" "Evlin iOS/Views/Child/BigKid/BigKidRootView.swift"
git commit -m "feat(child): BigKidHomeReflectionView with State A + State B + cooldown countdown"
```

---

## Phase 6: TaskDetail + Photo Capture + Bypass

### Task 6.1: Photo capture wrapper

**Files:**
- Create: `Evlin iOS/Evlin iOS/Components/Kid/EvKidPhotoPicker.swift`

- [ ] **Step 1: Wrap `UIImagePickerController` for camera capture**

```swift
import SwiftUI
import UIKit

/// Minimal UIImagePickerController wrapper. Camera-only (no library) to match
/// the prototype's "Take a photo" UX. Returns JPEG data via the `onCapture`
/// callback; closes the sheet on success or cancel.
struct EvKidPhotoPicker: UIViewControllerRepresentable {
    let onCapture: (Data?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (Data?) -> Void
        init(onCapture: @escaping (Data?) -> Void) { self.onCapture = onCapture }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            let img = info[.originalImage] as? UIImage
            onCapture(img?.jpegData(compressionQuality: 0.8))
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCapture(nil)
        }
    }
}
```

- [ ] **Step 2: Add `NSCameraUsageDescription` to Info.plist if missing**

```bash
grep -A1 "NSCameraUsageDescription" "/Users/fred/Desktop/Evlin/Evlin iOS/Evlin iOS/Info.plist" || echo "MISSING"
```

If `MISSING`, edit Info.plist (or via Xcode project settings → Info tab) to add:
- Key: `NSCameraUsageDescription`
- Value: `Evlin lets you take a photo to show your parent you finished a task.`

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Components/Kid/EvKidPhotoPicker.swift" "Evlin iOS/Evlin iOS/Info.plist"
git commit -m "feat(child): EvKidPhotoPicker camera wrapper + Info.plist usage description"
```

### Task 6.2: `BigKidTaskDetailView` (input phase)

**Source of truth:** `task-detail.jsx` lines 4–171 (input phase).

**Files:**
- Create: `Evlin iOS/Evlin iOS/Views/Child/BigKid/BigKidTaskDetailView.swift`

- [ ] **Step 1: Build the view with all three phases**

```swift
import SwiftUI

struct BigKidTaskDetailView: View {
    let task: BigKidTask
    var onBack: () -> Void
    var onBypass: () -> Void
    var onSubmit: (Data, String?) async -> Void

    @State private var note: String = ""
    @State private var photoData: Data?
    @State private var showCamera = false
    @State private var submitting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                topBar.padding(.top, 8)
                titleBlock.padding(.top, 12).padding(.bottom, 24)
                if let due = task.due { dueRow(due).padding(.bottom, 24) }
                whatToDoBlock.padding(.bottom, 24)
                phaseContent
            }
            .padding(.horizontal, EvlinKidMetrics.Padding.screenH)
            .padding(.bottom, 40)
        }
        .background(EvlinKidColors.surface.ignoresSafeArea())
        .sheet(isPresented: $showCamera) {
            EvKidPhotoPicker { data in
                showCamera = false
                if let data { photoData = data }
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch task.phase {
        case .input: inputPhase
        case .submitted: submittedPhase
        case .redo: redoPhase
        }
    }

    // MARK: - Top bar
    private var topBar: some View {
        HStack {
            EvKidBackButton(label: "Today", action: onBack)
            Spacer()
            if task.phase == .input {
                Button(action: onBypass) {
                    Text("I couldn't do this")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(EvlinKidColors.ink3)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .overlay(Capsule().stroke(EvlinKidColors.ink4, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Title
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            EvKidChip(task.category.rawValue, tone: chipTone)
            Text(task.title)
                .font(.system(size: 30, weight: .heavy))
                .tracking(EvlinKidMetrics.Letter.tightTitle)
                .foregroundStyle(EvlinKidColors.ink)
        }
    }

    private var chipTone: EvKidChip.Tone {
        switch task.category { case .chores: .violet; case .homework: .green; case .selfCare: .amber }
    }

    // MARK: - Due
    private func dueRow(_ due: String) -> some View {
        HStack {
            Text("DUE").font(.system(size: 13, weight: .bold))
                .tracking(0.8).foregroundStyle(EvlinKidColors.ink3)
            Spacer()
            Text("Today, \(due)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(task.status == .overdue ? Color(red: 200/255, green: 50/255, blue: 74/255) : EvlinKidColors.ink3)
        }
    }

    private var whatToDoBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WHAT TO DO")
                .font(.system(size: 13, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(EvlinKidColors.ink3)
            Text(task.description)
                .font(.system(size: 17))
                .foregroundStyle(EvlinKidColors.ink)
                .lineSpacing(4)
        }
    }

    // MARK: - Input phase
    private var inputPhase: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SHOW US")
                .font(.system(size: 13, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(EvlinKidColors.ink3)
            cameraButton
            noteField
            EvKidBigButton(isDisabled: photoData == nil || submitting,
                           action: submitAction) {
                Text(submitting ? "Submitting…" : "Submit for approval")
            }
        }
    }

    private var cameraButton: some View {
        Button { showCamera = true } label: {
            VStack(spacing: 10) {
                ZStack {
                    Circle().fill(EvlinKidColors.green500)
                        .frame(width: 60, height: 60)
                    Image(systemName: photoData == nil ? "camera.fill" : "checkmark")
                        .font(.system(size: photoData == nil ? 24 : 28, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text(photoData == nil ? "Take a photo" : "Photo ready")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(photoData == nil ? EvlinKidColors.ink2 : EvlinKidColors.green500)
                Text(photoData == nil ? "Show us what you did" : "Tap to retake")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(EvlinKidColors.ink3)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .background(photoData != nil ? EvlinKidColors.primarySoft : EvlinKidColors.surface2)
            .clipShape(RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.cardLarge))
            .overlay(
                RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.cardLarge)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2,
                                                     dash: photoData == nil ? [6] : []))
                    .foregroundStyle(photoData != nil ? EvlinKidColors.primary : EvlinKidColors.ink4)
            )
        }
        .buttonStyle(.plain)
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a note")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(EvlinKidColors.ink3)
            TextField("e.g. It took longer than I thought!", text: $note, axis: .vertical)
                .lineLimit(3...5)
                .font(.system(size: 16))
                .foregroundStyle(EvlinKidColors.ink)
                .padding(14)
                .background(EvlinKidColors.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(EvlinKidColors.line, lineWidth: 1.5)
                )
        }
    }

    private func submitAction() {
        guard let data = photoData else { return }
        submitting = true
        Task {
            await onSubmit(data, note.isEmpty ? nil : note)
            submitting = false
        }
    }

    // MARK: - Submitted phase
    private var submittedPhase: some View {
        VStack(alignment: .leading, spacing: 18) {
            EvKidCard(tone: .amber, padding: 22) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Evidence submitted")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(EvlinKidColors.primaryInk)
                    Text("Waiting for a parent to approve. You'll get a little ping when they do.")
                        .font(.system(size: 14))
                        .foregroundStyle(EvlinKidColors.amber)
                        .lineSpacing(2)
                    HStack(spacing: 10) {
                        ProgressView().tint(EvlinKidColors.amber)
                        Text("Sent just now")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(EvlinKidColors.amber)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(.white.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            evidencePreview.padding(.top, 4)
            EvKidBigButton(tone: .ghost, action: onBack) { Text("Back to today") }
        }
    }

    private var evidencePreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("YOUR EVIDENCE")
                .font(.system(size: 13, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(EvlinKidColors.ink3)
            // Show actual photo if cached locally; else placeholder
            placeholderImage
        }
    }

    private var placeholderImage: some View {
        ZStack {
            LinearGradient(
                colors: [EvlinKidColors.primarySoft, EvlinKidColors.green100],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Image(systemName: "camera.fill")
                .font(.system(size: 40))
                .foregroundStyle(EvlinKidColors.ink4)
        }
        .aspectRatio(4.0/3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    // MARK: - Redo phase
    private var redoPhase: some View {
        VStack(alignment: .leading, spacing: 18) {
            EvKidCard(tone: .amber, padding: 22) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Let's try that again")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(EvlinKidColors.primaryInk)
                    Text("A parent sent this back. No stress — have another go.")
                        .font(.system(size: 14))
                        .foregroundStyle(EvlinKidColors.amber)
                        .lineSpacing(2)
                    if let reason = task.redoReason {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("NOTE FROM YOUR PARENT")
                                .font(.system(size: 12, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(EvlinKidColors.amber)
                            Text(reason)
                                .font(.system(size: 15))
                                .foregroundStyle(EvlinKidColors.ink)
                                .lineSpacing(2)
                        }
                        .padding(14)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(EvlinKidColors.green200, lineWidth: 1)
                        )
                    }
                }
            }
            EvKidBigButton(action: { /* phase will flip on next poll once parent re-reviews */ }) {
                Text("Try again")
            }
        }
    }
}

#if DEBUG
#Preview("Input") {
    BigKidTaskDetailView(task: .fixture(status: .todo, phase: .input),
                         onBack: {}, onBypass: {}, onSubmit: { _, _ in })
}
#Preview("Submitted") {
    BigKidTaskDetailView(task: .fixture(status: .submitted, phase: .submitted),
                         onBack: {}, onBypass: {}, onSubmit: { _, _ in })
}
#Preview("Redo") {
    var t = BigKidTask.fixture(status: .todo, phase: .redo)
    t = BigKidTask(id: t.id, title: t.title, description: t.description,
                   category: t.category, due: t.due, status: t.status, phase: t.phase,
                   redoReason: "Bed is still messy. Please smooth the covers.",
                   evidencePhotoURL: nil, bypass: nil)
    return BigKidTaskDetailView(task: t, onBack: {}, onBypass: {}, onSubmit: { _, _ in })
}
#endif
```

- [ ] **Step 2: Visual parity against `task-detail.jsx`**

Open the prototype, walk through input / submitted / redo. Match padding, chip styling, camera button (180pt height, 22pt radius), evidence card.

- [ ] **Step 3: Wire navigation in root view**

Use a `NavigationStack` in `BigKidRootView`:

```swift
@State private var taskNav: BigKidTask?
@State private var bypassNav: BigKidTask?

// inside body Group, wrap home cases in NavigationStack via .navigationDestination
.sheet(item: $taskNav) { t in
    BigKidTaskDetailView(
        task: t,
        onBack: { taskNav = nil },
        onBypass: {
            bypassNav = t
            taskNav = nil
        },
        onSubmit: { data, note in
            _ = try? await client.submitEvidence(taskId: t.id, photoData: data, note: note)
            await poller.refreshNow()
            taskNav = nil
        },
    )
}
```

Then `onTaskTap: { task in taskNav = task }` from BigKidHomeView.

- [ ] **Step 4: Commit**

```bash
git add "Evlin iOS/Views/Child/BigKid/BigKidTaskDetailView.swift" "Evlin iOS/Views/Child/BigKid/BigKidRootView.swift"
git commit -m "feat(child): BigKidTaskDetailView with input/submitted/redo phases + camera"
```

### Task 6.3: `BigKidBypassView`

**Source of truth:** `bypass.jsx` lines 3–125.

**Files:**
- Create: `Evlin iOS/Evlin iOS/Views/Child/BigKid/BigKidBypassView.swift`

- [ ] **Step 1: Build form + sent states**

```swift
import SwiftUI

struct BigKidBypassView: View {
    let task: BigKidTask
    var onBack: () -> Void
    var onSend: (String) async -> Void

    @State private var text: String = ""
    @State private var sent: Bool = false
    @State private var sending: Bool = false

    var body: some View {
        Group { sent ? AnyView(sentView) : AnyView(formView) }
            .background(EvlinKidColors.surface.ignoresSafeArea())
    }

    private var formView: some View {
        VStack(alignment: .leading, spacing: 0) {
            EvKidBackButton(label: "Back", action: onBack)
                .padding(.top, 8)
            Text("For: ")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(EvlinKidColors.ink3)
                .padding(.top, 6)
            +
            Text(task.title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(EvlinKidColors.ink2)
            Text("Tell your parent why")
                .font(.system(size: 28, weight: .heavy))
                .tracking(-0.7)
                .foregroundStyle(EvlinKidColors.ink)
                .padding(.top, 18)
                .padding(.bottom, 8)
            Text("What's stopping you from doing this today? Write it out and your parent will decide if it's okay to skip.")
                .font(.system(size: 15))
                .foregroundStyle(EvlinKidColors.ink2)
                .lineSpacing(3)
                .padding(.bottom, 20)
            TextField("e.g. I had football practice and got home too late.",
                      text: $text, axis: .vertical)
                .lineLimit(8...20)
                .font(.system(size: 16))
                .padding(18)
                .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
                .background(EvlinKidColors.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(EvlinKidColors.line, lineWidth: 1.5)
                )
            Spacer(minLength: 18)
            EvKidBigButton(isDisabled: text.trimmingCharacters(in: .whitespaces).isEmpty || sending,
                           action: send) {
                Text(sending ? "Sending…" : "Send to parent")
            }
            .padding(.bottom, 24)
        }
        .padding(.horizontal, EvlinKidMetrics.Padding.screenH)
    }

    private func send() {
        sending = true
        Task {
            await onSend(text)
            sent = true
            sending = false
        }
    }

    private var sentView: some View {
        VStack(spacing: 0) {
            HStack { EvKidBackButton(label: "Home", action: onBack); Spacer() }
                .padding(.top, 8)
                .padding(.horizontal, EvlinKidMetrics.Padding.screenH)
            Spacer()
            VStack(spacing: 24) {
                ZStack {
                    Circle().fill(EvlinKidColors.green100)
                        .frame(width: 88, height: 88)
                    Circle().fill(EvlinKidColors.green500)
                        .frame(width: 60, height: 60)
                        .shadow(color: EvlinKidColors.green500.opacity(0.25), radius: 12, y: 6)
                    Image(systemName: "checkmark")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text("Your parent has been notified")
                    .font(.system(size: 26, weight: .heavy))
                    .tracking(-0.6)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(EvlinKidColors.ink)
                Text("Wait for their response. They'll let you know if you can skip this task today.")
                    .font(.system(size: 15))
                    .foregroundStyle(EvlinKidColors.ink3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                    .lineSpacing(3)
            }
            Spacer()
            EvKidBigButton(tone: .ghost, action: onBack) { Text("Back to home") }
                .padding(.horizontal, EvlinKidMetrics.Padding.screenH)
                .padding(.bottom, 32)
        }
    }
}

#if DEBUG
#Preview("Form") {
    BigKidBypassView(task: .fixture(), onBack: {}, onSend: { _ in })
}
#endif
```

- [ ] **Step 2: Wire into root view**

```swift
.sheet(item: $bypassNav) { t in
    BigKidBypassView(
        task: t,
        onBack: { bypassNav = nil },
        onSend: { reason in
            _ = try? await client.submitBypass(taskId: t.id, reason: reason)
            await poller.refreshNow()
        },
    )
}
```

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Views/Child/BigKid/BigKidBypassView.swift" "Evlin iOS/Views/Child/BigKid/BigKidRootView.swift"
git commit -m "feat(child): BigKidBypassView form + sent states"
```

### Task 6.4: Backend integration test — Phase 6 end-to-end via UI flow

- [ ] **Step 1: With backend running, exercise full task→evidence→approval→done flow on device/simulator**

1. Open BigKidRootView preview connected to `localhost:8000`.
2. Tap a task → TaskDetail opens.
3. Tap "Take a photo" → simulator: pick from library; device: capture.
4. Tap "Submit for approval" → toast/back to home, task pip should turn green-300 (submitted).
5. From terminal:
   ```bash
   TASK=$(curl -s -H "X-Child-Id: 11111111-1111-1111-1111-111111111111" \
     http://localhost:8000/api/v1/child/state | python3 -c "import sys, json; print(json.load(sys.stdin)['tasks'][0]['id'])")
   curl -s -X POST "http://localhost:8000/api/v1/parent/task/$TASK/review" \
     -H "Content-Type: application/json" \
     -d '{"decision":"approve","redo_reason":null}'
   ```
6. Within 60s the home should show task as Done.

- [ ] **Step 2: Exercise bypass auto-withdraw**

1. Tap task → "I couldn't do this" → BypassView → submit reason.
2. Verify backend: `curl ... /child/state | jq '.tasks[0].bypass.status'` → `"pending"`.
3. Tap same task → submit photo evidence.
4. Verify: `... .bypass.status` is now `"withdrawn"`.

- [ ] **Step 3: Document the smoke flow**

Append to `adaptive-engine/backend/docs/bigkid-smoke.md`:

```markdown
## End-to-end task + bypass smoke

1. Tap task → photo → submit → evidence flagged `submitted`.
2. `POST /parent/task/{id}/review {"decision":"approve"}` → status flips to `done`.
3. Tap task → "I couldn't do this" → submit → bypass `pending`.
4. Tap same task → submit photo → bypass auto `withdrawn`.
```

```bash
git add backend/docs/bigkid-smoke.md
git commit -m "docs(backend): document Phase 6 end-to-end smoke flow"
```

---

## Phase 7: Reflection Flow (5 screens)

The reflection flow uses a navigation stack rooted at LockedScreen. Each sub-step pushes onto the stack, completes, and pops back to LockedScreen. The hub re-renders progress on return. The kid can never leave the flow until 3/3 done; tapping "Unlock my devices" at 3/3 doesn't go to CompleteScreen — it returns the kid to HomeReflection State B (per spec §6.2).

### Task 7.1: `BigKidLockedView` (reflection hub)

**Source of truth:** `consequence-a.jsx` lines 80–186 (`LockedScreen`) + lines 3–78 (`ConsequenceSteps`).

**Files:**
- Create: `Evlin iOS/Evlin iOS/Views/Child/BigKid/Reflection/BigKidLockedView.swift`

- [ ] **Step 1: Build the hub**

```swift
import SwiftUI

struct BigKidLockedView: View {
    @Environment(BigKidState.self) private var state
    var onTapStep: (BigKidReflectionStep) -> Void
    var onUnlock: () -> Void

    private var progress: Int {
        state.reflectionRequest?.stepsCompleted.count ?? 0
    }
    private var allDone: Bool { progress >= 3 }
    private var firstName: String {
        String(state.childName.split(separator: " ").first ?? "there")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topChipRow.padding(.top, 2).padding(.bottom, 18)
            segmentedBar.padding(.bottom, 28)
            headlineBlock.padding(.bottom, 24)
            stepsList
            Spacer(minLength: 24)
            primaryButton
            disclaimer.padding(.top, 14)
        }
        .padding(.horizontal, EvlinKidMetrics.Padding.screenH)
        .padding(.top, 20)
        .padding(.bottom, 30)
        .background(EvlinKidColors.surface.ignoresSafeArea())
    }

    private var topChipRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: allDone ? "checkmark" : "lock.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(allDone ? EvlinKidColors.green500 : EvlinKidColors.ink2)
                Text(allDone ? "READY TO UNLOCK" : "DEVICES LOCKED")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(allDone ? EvlinKidColors.green700 : EvlinKidColors.ink2)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(allDone ? EvlinKidColors.green100 : EvlinKidColors.surface2,
                        in: Capsule())
            .overlay(Capsule()
                .stroke(allDone ? EvlinKidColors.green300 : EvlinKidColors.line, lineWidth: 1))
            Spacer()
            Text("\(progress) / 3")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(EvlinKidColors.ink3)
        }
    }

    private var segmentedBar: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Capsule().fill(i < progress ? EvlinKidColors.green500 : EvlinKidColors.line)
                    .frame(height: 4)
            }
        }
    }

    private var headlineBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("REFLECTION TIME")
                .font(.system(size: 12, weight: .bold))
                .tracking(2.4)
                .foregroundStyle(EvlinKidColors.green500)
            Text("Hey \(firstName).")
                .font(.system(size: 38, weight: .heavy))
                .tracking(-1)
                .foregroundStyle(EvlinKidColors.ink)
            Text(allDone
                 ? "You did the work. Tap below to finish up and get your devices back."
                 : (state.reflectionRequest?.reason ?? "Your devices are locked for a bit. Work through these three steps and they'll unlock."))
                .font(.system(size: 16))
                .foregroundStyle(EvlinKidColors.ink2)
                .lineSpacing(3)
                .frame(maxWidth: 340, alignment: .leading)
        }
    }

    private var stepsList: some View {
        VStack(spacing: 10) {
            stepRow(.video,   index: 0, title: "Watch the video",     sub: "2 min")
            stepRow(.quiz,    index: 1, title: "Answer the quiz",     sub: "5 questions")
            stepRow(.writing, index: 2, title: "Write a reflection",  sub: "3 sentences")
        }
    }

    private func stepRow(_ step: BigKidReflectionStep, index: Int, title: String, sub: String) -> some View {
        let done = (state.reflectionRequest?.stepsCompleted ?? []).contains(step)
        let active = index == progress && !done
        let locked = index > progress && !done

        let bg: Color   = done ? EvlinKidColors.green50  : .white
        let border = done ? EvlinKidColors.green200
                         : (active ? EvlinKidColors.green500 : EvlinKidColors.line)
        let borderW: CGFloat = active ? 1.5 : 1
        let iconBg = done || active ? EvlinKidColors.green500 : EvlinKidColors.surface2
        let iconFg: Color = done || active ? .white : EvlinKidColors.ink4
        let titleC = done ? EvlinKidColors.green700 : (active ? EvlinKidColors.ink : EvlinKidColors.ink3)
        let subC   = done ? EvlinKidColors.green600 : (active ? EvlinKidColors.ink2 : EvlinKidColors.ink4)

        return Button(action: { if active { onTapStep(step) } }) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(iconBg)
                    Image(systemName: done ? "checkmark"
                                          : (locked ? "lock.fill" : iconName(for: step)))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(iconFg)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(index + 1). \(title)")
                        .font(.system(size: 16, weight: .bold))
                        .tracking(EvlinKidMetrics.Letter.body)
                        .foregroundStyle(titleC)
                    Text(done ? "Complete" : (active ? sub : "Locked"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(subC)
                }
                Spacer(minLength: 0)
                if active {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(EvlinKidColors.green500)
                } else if done {
                    Text("DONE")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(EvlinKidColors.green500)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.row))
            .overlay(
                RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.row)
                    .stroke(border, lineWidth: borderW)
            )
            .shadow(color: active ? EvlinKidColors.green500.opacity(0.12) : .clear,
                    radius: 10, y: 8)
        }
        .buttonStyle(.plain)
        .disabled(!active)
    }

    private func iconName(for step: BigKidReflectionStep) -> String {
        switch step { case .video: "video.fill"; case .quiz: "list.bullet.clipboard"; case .writing: "pencil" }
    }

    private var primaryButton: some View {
        Button(action: allDone ? onUnlock : { onTapStep(nextStep) }) {
            Text(allDone ? "Unlock my devices" : nextLabel)
                .font(.system(size: 17, weight: .bold))
                .tracking(EvlinKidMetrics.Letter.body)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: EvlinKidMetrics.Size.buttonHeightLg)
                .background(EvlinKidColors.green500)
                .clipShape(RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.button))
                .shadow(color: EvlinKidColors.green500.opacity(0.24), radius: 12, y: 10)
        }
        .buttonStyle(.plain)
    }

    private var nextStep: BigKidReflectionStep {
        let steps: [BigKidReflectionStep] = [.video, .quiz, .writing]
        return steps[min(progress, 2)]
    }

    private var nextLabel: String {
        switch progress {
        case 0: "Start the video"
        case 1: "Start the quiz"
        case 2: "Start writing"
        default: "Continue"
        }
    }

    private var disclaimer: some View {
        Text("You can't leave this screen until you're done")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(EvlinKidColors.ink3)
            .frame(maxWidth: .infinity)
    }
}

#if DEBUG
#Preview("0/3") {
    BigKidLockedView(onTapStep: { _ in }, onUnlock: {})
        .environment(BigKidState(snapshot: .fixture(reflection: .fixture())))
}
#Preview("2/3") {
    BigKidLockedView(onTapStep: { _ in }, onUnlock: {})
        .environment(BigKidState(snapshot: .fixture(
            reflection: .fixture(stepsCompleted: [.video, .quiz]),
        )))
}
#Preview("3/3") {
    BigKidLockedView(onTapStep: { _ in }, onUnlock: {})
        .environment(BigKidState(snapshot: .fixture(
            reflection: .fixture(stepsCompleted: [.video, .quiz, .writing]),
        )))
}
#endif
```

- [ ] **Step 2: Visual diff against `consequence-a.jsx` LockedScreen**

Render the prototype. Verify segmented bar (4pt thick, 6pt gap), step rows (44×44 icon, 18 radius row, 1.5 border on active), bottom CTA (60pt height, 18 radius, deep green shadow).

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Views/Child/BigKid/Reflection/BigKidLockedView.swift"
git commit -m "feat(child): BigKidLockedView reflection hub with 3-step progress"
```

### Task 7.2: `BigKidVideoView` — YouTube embed with no-skip enforcement

**Source of truth:** `consequence-a.jsx` lines 188–310 (`VideoScreen`).

**Files:**
- Create: `Evlin iOS/Evlin iOS/Views/Child/BigKid/Reflection/BigKidVideoView.swift`

- [ ] **Step 1: Build the view**

We reuse `InlineYouTubeWebView` from existing `Components/YouTubePlayerView.swift` (already in the project, handles Referer for Error 153) but wire a JS bridge to detect `ended`.

```swift
import SwiftUI
import WebKit

struct BigKidVideoView: View {
    let videoId: String
    let videoTitle: String
    var onComplete: () async -> Void

    @State private var playbackPercent: Double = 0
    @State private var ended: Bool = false
    @State private var completing: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.top, 6).padding(.bottom, 20)
            VideoEmbedView(videoId: videoId,
                           onProgress: { playbackPercent = $0 },
                           onEnded: { ended = true })
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .frame(maxHeight: 440)
            VStack(spacing: 10) {
                progressBar.padding(.top, 20)
                lockHint
            }
            Spacer(minLength: 16)
            primaryButton.padding(.top, 20)
        }
        .padding(.horizontal, EvlinKidMetrics.Padding.screenH)
        .padding(.bottom, 30)
        .background(EvlinKidColors.surface.ignoresSafeArea())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("STEP 1 OF 3 — REFLECTION TIME")
                .font(.system(size: 12, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(EvlinKidColors.green500)
            Text(videoTitle)
                .font(.system(size: 22, weight: .heavy))
                .tracking(-0.4)
                .foregroundStyle(EvlinKidColors.ink)
                .lineSpacing(3)
        }
    }

    private var progressBar: some View {
        EvKidProgressBar(value: playbackPercent, max: 100, tone: .primary, height: 6)
    }

    private var lockHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(EvlinKidColors.ink3)
            Text("Watch the whole video — no skipping")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(EvlinKidColors.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var primaryButton: some View {
        if ended || playbackPercent >= 99 {
            EvKidBigButton(isDisabled: completing,
                           action: complete) {
                Text(completing ? "Saving…" : "Continue")
            }
        } else {
            EvKidBigButton(isDisabled: true, action: {}) {
                Text("Watching...")
            }
        }
    }

    private func complete() {
        completing = true
        Task { await onComplete(); completing = false }
    }
}

private struct VideoEmbedView: UIViewRepresentable {
    let videoId: String
    let onProgress: (Double) -> Void
    let onEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgress: onProgress, onEnded: onEnded)
    }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.userContentController.add(context.coordinator, name: "evlinPlayer")
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.scrollView.isScrollEnabled = false
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.navigationDelegate = context.coordinator
        let html = """
        <!DOCTYPE html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>html,body{margin:0;padding:0;background:#000;width:100%;height:100%;overflow:hidden}#p{width:100%;height:100%}</style></head>
        <body><div id="p"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
        var player;
        function onYouTubeIframeAPIReady(){
          player=new YT.Player('p',{videoId:'\(videoId)',
            playerVars:{playsinline:1,controls:0,disablekb:1,modestbranding:1,rel:0,fs:0},
            events:{
              onReady:function(){player.playVideo();
                setInterval(function(){
                  try{
                    var d=player.getDuration();var t=player.getCurrentTime();
                    if(d>0)window.webkit.messageHandlers.evlinPlayer.postMessage({k:'p',v:(t/d)*100});
                  }catch(e){}
                },500);},
              onStateChange:function(e){
                if(e.data===0)window.webkit.messageHandlers.evlinPlayer.postMessage({k:'end'});
              }
            }});
        }
        </script></body></html>
        """
        web.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com"))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let onProgress: (Double) -> Void
        let onEnded: () -> Void
        init(onProgress: @escaping (Double) -> Void, onEnded: @escaping () -> Void) {
            self.onProgress = onProgress; self.onEnded = onEnded
        }
        func userContentController(_ uc: WKUserContentController, didReceive m: WKScriptMessage) {
            guard let dict = m.body as? [String: Any], let k = dict["k"] as? String else { return }
            if k == "p", let v = dict["v"] as? Double { onProgress(min(100, v)) }
            else if k == "end" { onEnded() }
        }
    }
}

#if DEBUG
#Preview {
    BigKidVideoView(videoId: "dQw4w9WgXcQ",
                    videoTitle: "Why rest time matters for your brain",
                    onComplete: {})
}
#endif
```

- [ ] **Step 2: Commit**

```bash
git add "Evlin iOS/Views/Child/BigKid/Reflection/BigKidVideoView.swift"
git commit -m "feat(child): BigKidVideoView with no-skip YouTube embed + progress bar"
```

### Task 7.3: `BigKidQuizView` — 5 questions + results

**Source of truth:** `consequence-b.jsx` lines 58–208 (`QuizScreen`).

**Files:**
- Create: `Evlin iOS/Evlin iOS/Views/Child/BigKid/Reflection/BigKidQuizView.swift`

- [ ] **Step 1: Build the quiz with per-question UI + results**

```swift
import SwiftUI

struct BigKidQuizView: View {
    let request: ReflectionRequest
    var onAnswer: (Int, Int) async -> QuizAnswerOutcome
    var onComplete: () async -> Void
    var onRetry: () -> Void

    @State private var currentIndex: Int = 0
    @State private var selected: Int? = nil
    @State private var answers: [Int] = []
    @State private var score: Int = 0
    @State private var showResults: Bool = false
    @State private var submitting: Bool = false

    var body: some View {
        Group {
            if showResults { resultsView } else { questionView }
        }
        .padding(.horizontal, EvlinKidMetrics.Padding.screenH)
        .padding(.top, 20).padding(.bottom, 30)
        .background(EvlinKidColors.surface.ignoresSafeArea())
    }

    private var questionView: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 20)
            Text(request.quiz[currentIndex].q)
                .font(.system(size: 24, weight: .heavy))
                .tracking(-0.4)
                .foregroundStyle(EvlinKidColors.ink)
                .lineSpacing(4)
                .padding(.top, 8).padding(.bottom, 24)
            options.padding(.bottom, 20)
            Spacer(minLength: 0)
            confirmButton
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STEP 2 OF 3 — QUESTION \(currentIndex + 1) OF \(request.quiz.count)")
                .font(.system(size: 12, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(EvlinKidColors.green500)
            EvKidProgressBar(value: Double(currentIndex + 1),
                             max: Double(request.quiz.count),
                             tone: .primary, height: 4)
        }
    }

    private var options: some View {
        VStack(spacing: 10) {
            ForEach(Array(request.quiz[currentIndex].options.enumerated()), id: \.offset) { idx, text in
                Button { selected = idx } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .stroke(selected == idx ? EvlinKidColors.green500 : EvlinKidColors.line,
                                        lineWidth: 2)
                                .background(
                                    Circle().fill(selected == idx ? EvlinKidColors.green500 : .clear)
                                )
                            if selected == idx {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 26, height: 26)
                        Text(text)
                            .font(.system(size: 16, weight: .semibold))
                            .tracking(-0.1)
                            .foregroundStyle(EvlinKidColors.ink)
                            .lineSpacing(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(18)
                    .background(selected == idx ? EvlinKidColors.green50 : .white)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(selected == idx ? EvlinKidColors.green500 : EvlinKidColors.line,
                                    lineWidth: 1.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var confirmButton: some View {
        EvKidBigButton(isDisabled: selected == nil || submitting,
                       action: confirm) {
            Text(submitting ? "Checking…" : "Confirm answer")
        }
    }

    private func confirm() {
        guard let s = selected else { return }
        submitting = true
        Task {
            let outcome = await onAnswer(currentIndex, s)
            answers.append(s)
            selected = nil
            score = outcome.score
            submitting = false
            if currentIndex == request.quiz.count - 1 {
                showResults = true
            } else {
                currentIndex += 1
            }
        }
    }

    private var resultsView: some View {
        let passed = score >= 4
        return VStack(spacing: 0) {
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(passed ? EvlinKidColors.green100 : EvlinKidColors.surface2)
                        .overlay(Circle().stroke(passed ? EvlinKidColors.green300 : EvlinKidColors.line, lineWidth: 2))
                    Image(systemName: passed ? "checkmark" : "questionmark")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(passed ? EvlinKidColors.green500 : EvlinKidColors.ink2)
                }
                .frame(width: 84, height: 84)
                .padding(.top, 40)
                Text(passed ? "Nice work." : "Almost there.")
                    .font(.system(size: 28, weight: .heavy))
                    .tracking(-0.8)
                    .foregroundStyle(EvlinKidColors.ink)
                Text(passed ? "You understood what matters. One more step to go."
                            : "Have another go — you need 4 out of 5.")
                    .font(.system(size: 15))
                    .foregroundStyle(EvlinKidColors.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                    .lineSpacing(2)
            }
            VStack(spacing: 8) {
                Text("YOUR SCORE")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(passed ? EvlinKidColors.green700 : EvlinKidColors.ink3)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(score)")
                        .font(.system(size: 72, weight: .heavy))
                        .tracking(-3)
                        .foregroundStyle(passed ? EvlinKidColors.green500 : EvlinKidColors.ink2)
                        .monospacedDigit()
                    Text("/ \(request.quiz.count)")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(EvlinKidColors.ink3)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(passed ? EvlinKidColors.green50 : EvlinKidColors.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(passed ? EvlinKidColors.green200 : EvlinKidColors.line, lineWidth: 1)
            )
            .padding(.top, 28)
            Spacer(minLength: 0)
            EvKidBigButton(action: passed ? continueAction : retryAction) {
                Text(passed ? "Continue" : "Retry quiz")
            }
            .padding(.top, 24)
        }
    }

    private func continueAction() {
        Task { await onComplete() }
    }
    private func retryAction() {
        currentIndex = 0; selected = nil; answers = []; score = 0; showResults = false
        onRetry()
    }
}

#if DEBUG
#Preview {
    BigKidQuizView(request: .fixture(),
                   onAnswer: { _, _ in QuizAnswerOutcome(correct: true, allCorrect: false, score: 5) },
                   onComplete: {}, onRetry: {})
}
#endif
```

- [ ] **Step 2: Commit**

```bash
git add "Evlin iOS/Views/Child/BigKid/Reflection/BigKidQuizView.swift"
git commit -m "feat(child): BigKidQuizView with 5-question flow + results screen"
```

### Task 7.4: `BigKidWritingView` — essay submission with validators

**Source of truth:** `consequence-b.jsx` lines 210–304 (`ReflectionScreen`).

**Files:**
- Create: `Evlin iOS/Evlin iOS/Views/Child/BigKid/Reflection/BigKidWritingView.swift`

- [ ] **Step 1: Build the writing view + validators**

```swift
import SwiftUI

struct BigKidWritingView: View {
    let prompt: String
    var onSubmit: (String) async -> Void

    @State private var text: String = ""
    @State private var showTryAgain: Bool = false
    @State private var submitting: Bool = false

    private var sentenceCount: Int {
        text.split { ".!?".contains($0) }
            .filter { $0.trimmingCharacters(in: .whitespaces).count > 3 }
            .count
    }
    private var minMet: Bool {
        sentenceCount >= 3 && text.trimmingCharacters(in: .whitespaces).count >= 40
    }
    private var uniqueWords: Int {
        Set(text.split { !$0.isLetter }.map { $0.lowercased() }).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepLabel.padding(.bottom, 16)
            promptCard.padding(.bottom, 16)
            editor
            countersRow.padding(.top, 10).padding(.bottom, 12)
            if showTryAgain { tryAgainHint.padding(.bottom, 12) }
            submitButton
        }
        .padding(.horizontal, EvlinKidMetrics.Padding.screenH)
        .padding(.top, 20).padding(.bottom, 30)
        .background(EvlinKidColors.surface.ignoresSafeArea())
    }

    private var stepLabel: some View {
        Text("STEP 3 OF 3 — REFLECTION TIME")
            .font(.system(size: 12, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(EvlinKidColors.green500)
    }

    private var promptCard: some View {
        EvKidCard(tone: .amber, padding: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("EVLIN ASKS")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(EvlinKidColors.green700)
                Text(prompt)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(EvlinKidColors.ink)
                    .lineSpacing(3)
            }
        }
    }

    private var editor: some View {
        TextField("Take your time. Write at least 3 sentences...",
                  text: $text, axis: .vertical)
            .lineLimit(8...20)
            .font(.system(size: 16))
            .foregroundStyle(EvlinKidColors.ink)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(EvlinKidColors.line, lineWidth: 1.5)
            )
    }

    private var countersRow: some View {
        HStack {
            Text("\(sentenceCount) of 3 sentences")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(EvlinKidColors.ink3)
            Spacer()
            HStack(spacing: 6) {
                if minMet {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(EvlinKidColors.green600)
                }
                Text(minMet ? "Minimum met" : "Keep going")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(minMet ? EvlinKidColors.green600 : EvlinKidColors.ink3)
            }
        }
    }

    private var tryAgainHint: some View {
        EvKidCard(tone: .amber, padding: 14) {
            Text("Thanks for writing — can you add a bit more about how you felt? A longer answer helps you more than me.")
                .font(.system(size: 13))
                .foregroundStyle(EvlinKidColors.green700)
                .lineSpacing(2)
        }
    }

    private var submitButton: some View {
        EvKidBigButton(isDisabled: !minMet || submitting, action: submit) {
            Text(submitting ? "Submitting…" : "Submit reflection")
        }
    }

    private func submit() {
        if uniqueWords < 12 { showTryAgain = true; return }
        submitting = true
        Task { await onSubmit(text); submitting = false }
    }
}

#if DEBUG
#Preview {
    BigKidWritingView(prompt: "What were you feeling, and what could you do differently tomorrow?",
                      onSubmit: { _ in })
}
#endif
```

- [ ] **Step 2: Commit**

```bash
git add "Evlin iOS/Views/Child/BigKid/Reflection/BigKidWritingView.swift"
git commit -m "feat(child): BigKidWritingView with 3-sentence/40-char/12-unique-word validators"
```

### Task 7.5: `BigKidCompleteView` — Welcome back

**Source of truth:** `consequence-b.jsx` lines 306–387 (`CompleteScreen`).

**Files:**
- Create: `Evlin iOS/Evlin iOS/Views/Child/BigKid/Reflection/BigKidCompleteView.swift`

- [ ] **Step 1: Build complete view**

```swift
import SwiftUI

struct BigKidCompleteView: View {
    let request: ReflectionRequest
    var onContinue: () async -> Void

    @State private var ackInFlight: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 20) {
                ZStack {
                    Circle().fill(EvlinKidColors.green100)
                        .overlay(Circle().stroke(EvlinKidColors.green300, lineWidth: 2))
                    Image(systemName: "checkmark")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(EvlinKidColors.green500)
                }
                .frame(width: 84, height: 84)
                .padding(.top, 40)
                Text("Welcome back")
                    .font(.system(size: 30, weight: .heavy))
                    .tracking(-0.8)
                    .foregroundStyle(EvlinKidColors.ink)
                if let note = request.parentNote, !note.isEmpty {
                    Text("\u{201C}\(note)\u{201D}")
                        .font(.system(size: 16))
                        .italic()
                        .foregroundStyle(EvlinKidColors.ink2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                        .lineSpacing(3)
                } else {
                    Text("Thanks for taking the time to think it through. Tomorrow's a fresh start.")
                        .font(.system(size: 16))
                        .foregroundStyle(EvlinKidColors.ink2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                        .lineSpacing(3)
                }
            }
            EvKidCard(padding: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("YOU COMPLETED")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(EvlinKidColors.ink3)
                    summaryRow(icon: "video.fill", label: "Video watched", detail: "2 min")
                    summaryRow(icon: "list.bullet.clipboard", label: "Quiz passed",
                               detail: "\(request.quizScore ?? 4) / \(request.quiz.count) correct")
                    summaryRow(icon: "pencil", label: "Reflection submitted", detail: "3+ sentences")
                }
            }
            .padding(.top, 28)
            Spacer(minLength: 24)
            EvKidBigButton(isDisabled: ackInFlight, action: ack) {
                Text(ackInFlight ? "Heading home…" : "Back to home")
            }
        }
        .padding(.horizontal, EvlinKidMetrics.Padding.screenH)
        .padding(.bottom, 30)
        .background(EvlinKidColors.surface.ignoresSafeArea())
    }

    private func summaryRow(icon: String, label: String, detail: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(EvlinKidColors.green100)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(EvlinKidColors.green600)
            }
            .frame(width: 36, height: 36)
            Text(label)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(EvlinKidColors.ink)
            Spacer(minLength: 0)
            Text(detail)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(EvlinKidColors.ink3)
        }
    }

    private func ack() {
        ackInFlight = true
        Task { await onContinue(); ackInFlight = false }
    }
}

#if DEBUG
#Preview {
    var r = ReflectionRequest.fixture(status: .approved,
                                      stepsCompleted: [.video, .quiz, .writing])
    r = ReflectionRequest(
        id: r.id, reason: r.reason, videoId: r.videoId, videoTitle: r.videoTitle,
        writingPrompt: r.writingPrompt, quiz: r.quiz, stepsCompleted: r.stepsCompleted,
        quizScore: 5, essayText: "ok", status: .approved,
        parentNote: "Thanks for being honest. Proud of you.",
        submittedAt: Date(), approvedAt: Date(),
    )
    return BigKidCompleteView(request: r, onContinue: {})
}
#endif
```

- [ ] **Step 2: Commit**

```bash
git add "Evlin iOS/Views/Child/BigKid/Reflection/BigKidCompleteView.swift"
git commit -m "feat(child): BigKidCompleteView post-approval celebration"
```

### Task 7.6: Wire the reflection flow into `BigKidRootView`

**Files:**
- Modify: `Evlin iOS/Evlin iOS/Views/Child/BigKid/BigKidRootView.swift`

- [ ] **Step 1: Add navigation state for the reflection sub-flow**

```swift
enum ReflectionNav: Hashable {
    case locked
    case video
    case quiz
    case writing
}

// In BigKidRootView body
@State private var reflectionPath = NavigationPath()

case .homeReflectionA:
    NavigationStack(path: $reflectionPath) {
        BigKidHomeReflectionView(
            subState: .a,
            onStartReflection: { reflectionPath.append(ReflectionNav.locked) },
            onTaskTap: { _ in },
            onNudgeParent: {},
        )
        .navigationDestination(for: ReflectionNav.self) { dest in
            destinationView(for: dest)
        }
    }
```

- [ ] **Step 2: Define `destinationView` factory**

```swift
@ViewBuilder
private func destinationView(for dest: ReflectionNav) -> some View {
    switch dest {
    case .locked:
        BigKidLockedView(
            onTapStep: { step in
                switch step {
                case .video:   reflectionPath.append(ReflectionNav.video)
                case .quiz:    reflectionPath.append(ReflectionNav.quiz)
                case .writing: reflectionPath.append(ReflectionNav.writing)
                }
            },
            onUnlock: {
                // 3/3 done → return to State B (HomeReflection waiting)
                reflectionPath = NavigationPath()
            },
        )
        .navigationBarBackButtonHidden(true)
    case .video:
        if let r = state.reflectionRequest {
            BigKidVideoView(videoId: r.videoId, videoTitle: r.videoTitle) {
                _ = try? await client.reflectionStepComplete(rid: r.id, step: .video)
                await poller.refreshNow()
                reflectionPath.removeLast()
            }
        }
    case .quiz:
        if let r = state.reflectionRequest {
            BigKidQuizView(
                request: r,
                onAnswer: { idx, sel in
                    (try? await client.reflectionQuizAnswer(rid: r.id,
                                                             questionIndex: idx,
                                                             selectedIndex: sel))
                    ?? QuizAnswerOutcome(correct: false, allCorrect: false, score: 0)
                },
                onComplete: {
                    await poller.refreshNow()
                    reflectionPath.removeLast()
                },
                onRetry: {},
            )
        }
    case .writing:
        if let r = state.reflectionRequest {
            BigKidWritingView(prompt: r.writingPrompt) { text in
                _ = try? await client.reflectionEssay(rid: r.id, text: text)
                await poller.refreshNow()
                reflectionPath = NavigationPath()
            }
        }
    }
}
```

- [ ] **Step 3: Wire CompleteScreen branch**

```swift
case .complete:
    if let r = state.reflectionRequest {
        BigKidCompleteView(request: r) {
            _ = try? await client.reflectionAck(rid: r.id)
            await poller.refreshNow()
        }
    }
```

- [ ] **Step 4: Walk the full reflection flow on simulator with backend running**

1. Trigger reflection via curl.
2. App switches to HomeReflection State A.
3. Tap Start Reflection → LockedScreen.
4. Tap step 1 → VideoScreen → wait for end → Continue → returns to LockedScreen with step 1 done.
5. Tap step 2 → QuizScreen → answer all 5 (3rd seed answer = idx 2) → results → Continue.
6. Tap step 3 → WritingScreen → type ≥3 sentences with ≥40 chars and ≥12 unique words → Submit.
7. Returns to HomeReflection State B.
8. From terminal:
   ```bash
   RID=$(curl -s -H "X-Child-Id: 11111111-1111-1111-1111-111111111111" \
     http://localhost:8000/api/v1/child/state | python3 -c "import sys, json; print(json.load(sys.stdin)['reflection_request']['id'])")
   curl -s -X POST "http://localhost:8000/api/v1/parent/reflection/$RID/approve" \
     -H "Content-Type: application/json" \
     -d '{"parent_note":"Thanks for being honest."}'
   ```
9. Within 60s app surfaces CompleteScreen → tap Back to home → green Home returns.

- [ ] **Step 5: Commit**

```bash
git add "Evlin iOS/Views/Child/BigKid/BigKidRootView.swift"
git commit -m "feat(child): wire reflection flow navigation in BigKidRootView"
```

---

## Phase 8: End-of-day Screens

### Task 8.1: `BigKidScreenTimeFinishedView`

**Source of truth:** `consequence-b.jsx` lines 389–439 (`ScreenTimeFinishedScreen`).

**Files:**
- Create: `Evlin iOS/Evlin iOS/Views/Child/BigKid/BigKidScreenTimeFinishedView.swift`

- [ ] **Step 1: Build the view**

```swift
import SwiftUI

struct BigKidScreenTimeFinishedView: View {
    @Environment(BigKidState.self) private var state
    var onAck: () async -> Void

    @State private var ackInFlight: Bool = false

    private var doneCount: Int {
        state.tasks.filter { $0.status == .done || $0.bypass?.status == .approved }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 20) {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(EvlinKidColors.green600)
                    .padding(.top, 40)
                Text("That's your screen time for today")
                    .font(.system(size: 28, weight: .heavy))
                    .tracking(-0.7)
                    .foregroundStyle(EvlinKidColors.ink)
                    .multilineTextAlignment(.center)
                Text("Nice work sticking with it. Go do something off-screen — we'll see you tomorrow.")
                    .font(.system(size: 15))
                    .foregroundStyle(EvlinKidColors.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                    .lineSpacing(3)
            }
            EvKidCard(padding: 20) {
                VStack(spacing: 18) {
                    statRow("Tasks completed today", "\(doneCount) of \(state.tasks.count)")
                    Divider()
                    statRow("Screen time used", "\(state.minutesMax) min")
                    Divider()
                    statRow("Devices unlock", "Tomorrow, 7:00 AM")
                }
            }
            .padding(.top, 28)
            Spacer(minLength: 0)
            EvKidBigButton(isDisabled: ackInFlight, action: ack) {
                Text(ackInFlight ? "OK" : "OK")
            }
        }
        .padding(.horizontal, EvlinKidMetrics.Padding.screenH)
        .padding(.bottom, 30)
        .background(EvlinKidColors.surface.ignoresSafeArea())
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(EvlinKidColors.ink2)
            Spacer()
            Text(value)
                .font(.system(size: 16, weight: .bold))
                .tracking(-0.2)
                .foregroundStyle(EvlinKidColors.ink)
        }
    }

    private func ack() { ackInFlight = true; Task { await onAck(); ackInFlight = false } }
}

#if DEBUG
#Preview {
    BigKidScreenTimeFinishedView(onAck: {})
        .environment(BigKidState(snapshot: .fixture(
            tasks: [.fixture(status: .done), .fixture(status: .done)],
            minutesLeft: 0,
        )))
}
#endif
```

- [ ] **Step 2: Wire into root view**

```swift
case .screenTimeFinished:
    BigKidScreenTimeFinishedView(onAck: {
        _ = try? await client.ackScreenTimeFinished()
        await poller.refreshNow()
    })
```

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Views/Child/BigKid/BigKidScreenTimeFinishedView.swift" "Evlin iOS/Views/Child/BigKid/BigKidRootView.swift"
git commit -m "feat(child): BigKidScreenTimeFinishedView with ack endpoint wiring"
```

### Task 8.2: `BigKidDailyCompleteView`

**Source of truth:** `consequence-b.jsx` lines 441–560 (`DailyCompleteScreen`).

**Files:**
- Create: `Evlin iOS/Evlin iOS/Views/Child/BigKid/BigKidDailyCompleteView.swift`

- [ ] **Step 1: Build the view**

```swift
import SwiftUI

struct BigKidDailyCompleteView: View {
    @Environment(BigKidState.self) private var state
    var onContinue: () async -> Void

    @State private var ackInFlight: Bool = false

    private var earned: Int { Swift.max(0, Swift.min(state.minutesMax, state.minutesLeft)) }
    private var hours: Int { earned / 60 }
    private var mins: Int { earned % 60 }
    private var pct: Double { Double(earned) / Double(state.minutesMax) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 20) {
                Image(systemName: "sparkles")
                    .font(.system(size: 56))
                    .foregroundStyle(EvlinKidColors.green500)
                    .padding(.top, 32)
                Text("Great job today")
                    .font(.system(size: 28, weight: .heavy))
                    .tracking(-0.7)
                    .foregroundStyle(EvlinKidColors.ink)
                Text("All tasks done. Here's the screen time you've earned.")
                    .font(.system(size: 15))
                    .foregroundStyle(EvlinKidColors.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                    .lineSpacing(3)
            }
            EvKidCard(tone: .green, padding: 22) {
                VStack(spacing: 14) {
                    HStack {
                        Text("YOU'VE EARNED")
                            .font(.system(size: 12, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(EvlinKidColors.green700)
                        Spacer()
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            if hours > 0 {
                                Text("\(hours)").font(.system(size: 32, weight: .heavy))
                                    .tracking(-1).foregroundStyle(EvlinKidColors.green700)
                                    .monospacedDigit()
                                Text("h").font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(EvlinKidColors.green700)
                            }
                            Text("\(mins)").font(.system(size: 32, weight: .heavy))
                                .tracking(-1).foregroundStyle(EvlinKidColors.green700)
                                .monospacedDigit()
                                .padding(.leading, hours > 0 ? 4 : 0)
                            Text("m").font(.system(size: 14, weight: .bold))
                                .foregroundStyle(EvlinKidColors.green700)
                        }
                    }
                    EvKidProgressBar(value: Double(earned), max: Double(state.minutesMax),
                                     tone: .primary, height: 14)
                    HStack {
                        Text("\(Int(pct * 100))% OF TODAY")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.4)
                            .foregroundStyle(EvlinKidColors.green700)
                        Spacer()
                        Text("\(state.minutesMax) MIN CAP")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.4)
                            .foregroundStyle(EvlinKidColors.green700.opacity(0.7))
                    }
                }
            }
            .padding(.top, 24)
            EvKidCard(padding: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("TODAY YOU DID")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(EvlinKidColors.ink3)
                    ForEach(state.tasks) { t in
                        HStack(spacing: 10) {
                            ZStack {
                                Circle().fill(EvlinKidColors.green500)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .frame(width: 22, height: 22)
                            Text(t.title)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(EvlinKidColors.ink)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .padding(.top, 16)
            Spacer(minLength: 0)
            EvKidBigButton(isDisabled: ackInFlight, action: continueAction) {
                Text(ackInFlight ? "Heading home…" : "Continue")
            }
        }
        .padding(.horizontal, EvlinKidMetrics.Padding.screenH)
        .padding(.bottom, 30)
        .background(EvlinKidColors.surface.ignoresSafeArea())
    }

    private func continueAction() {
        ackInFlight = true
        Task { await onContinue(); ackInFlight = false }
    }
}

#if DEBUG
#Preview {
    BigKidDailyCompleteView(onContinue: {})
        .environment(BigKidState(snapshot: .fixture(
            tasks: [.fixture(status: .done), .fixture(status: .done), .fixture(status: .done)],
            minutesLeft: 95, minutesMax: 120,
        )))
}
#endif
```

- [ ] **Step 2: Wire into root view**

```swift
case .dailyComplete:
    BigKidDailyCompleteView(onContinue: {
        _ = try? await client.ackDailyComplete()
        await poller.refreshNow()
    })
```

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Views/Child/BigKid/BigKidDailyCompleteView.swift" "Evlin iOS/Views/Child/BigKid/BigKidRootView.swift"
git commit -m "feat(child): BigKidDailyCompleteView with earned-time bar + ack wiring"
```

---

## Phase 9: Backend — Gemini integration for reflection content

Replace the seed fixture with live Gemini-generated reflection content per spec §10.

### Task 9.1: Gemini reflection generator service

**Files:**
- Create: `adaptive-engine/backend/app/services/gemini_reflection.py`
- Create: `adaptive-engine/backend/tests/test_gemini_reflection.py`

- [ ] **Step 1: Write failing test (mocked Gemini)**

```python
"""Tests for Gemini reflection content generator."""
from __future__ import annotations

import json
from unittest.mock import AsyncMock, patch

import pytest

from backend.app.services.gemini_reflection import generate_reflection_content


@pytest.mark.asyncio
async def test_generate_reflection_content_parses_response() -> None:
    fake_json = {
        "videoQuery": "screen time and brain rest for kids",
        "writingPrompt": "How did you feel and what could you do differently?",
        "quiz": [
            {"q": "Q1?", "options": ["a","b","c","d"], "correctIndex": 0}
        ] * 5,
    }
    with patch("backend.app.services.gemini_reflection._call_gemini",
               new=AsyncMock(return_value=json.dumps(fake_json))):
        with patch("backend.app.services.gemini_reflection._search_youtube",
                   new=AsyncMock(return_value=("yt123", "Some video title"))):
            content = await generate_reflection_content(reason="kept scrolling")
    assert content.video_id == "yt123"
    assert content.video_title == "Some video title"
    assert len(content.quiz) == 5
    assert content.writing_prompt.startswith("How did you feel")
```

- [ ] **Step 2: Run — expect failure**

```bash
cd /Users/fred/Desktop/Evlin/adaptive-engine
python3 -m pytest backend/tests/test_gemini_reflection.py -v
```

- [ ] **Step 3: Implement the service**

```python
"""Gemini-based reflection content generator (spec §10).

Public entry: ``generate_reflection_content(reason)`` returning a structured
``ReflectionContent`` ready to persist via ``BigKidStore.trigger_reflection``.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass

import httpx


GEMINI_KEY = os.environ.get("GEMINI_API_KEY", "")
YOUTUBE_KEY = os.environ.get("YOUTUBE_API_KEY", "")

PROMPT_TEMPLATE = """\
For an 8–12 year old, generate reflection content for this issue: {reason}.
Return strict JSON with three keys:
- "videoQuery": a single sentence YouTube search for an age-appropriate \
educational video on the underlying topic
- "quiz": an array of EXACTLY 5 multiple-choice questions, each with \
"q" (string), "options" (array of 4 strings), "correctIndex" (integer 0..3)
- "writingPrompt": a 1-2 sentence prompt asking the kid to reflect on their \
behaviour and what they could do differently.
Only output JSON. No prose, no code fences.
"""


@dataclass
class QuizSeed:
    q: str
    options: list[str]
    correct_index: int


@dataclass
class ReflectionContent:
    video_id: str
    video_title: str
    quiz: list[QuizSeed]
    writing_prompt: str


async def generate_reflection_content(*, reason: str) -> ReflectionContent:
    raw = await _call_gemini(PROMPT_TEMPLATE.format(reason=reason))
    parsed = json.loads(raw)
    if len(parsed["quiz"]) != 5:
        raise ValueError("Gemini returned wrong number of quiz questions")
    video_id, video_title = await _search_youtube(parsed["videoQuery"])
    return ReflectionContent(
        video_id=video_id, video_title=video_title,
        quiz=[QuizSeed(q=q["q"], options=q["options"],
                       correct_index=int(q["correctIndex"])) for q in parsed["quiz"]],
        writing_prompt=parsed["writingPrompt"],
    )


async def _call_gemini(prompt: str) -> str:
    if not GEMINI_KEY:
        raise RuntimeError("GEMINI_API_KEY missing")
    url = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key={GEMINI_KEY}"
    body = {
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {"temperature": 0.4, "responseMimeType": "application/json"},
    }
    async with httpx.AsyncClient(timeout=30) as c:
        r = await c.post(url, json=body)
        r.raise_for_status()
        data = r.json()
    return data["candidates"][0]["content"]["parts"][0]["text"]


async def _search_youtube(query: str) -> tuple[str, str]:
    if not YOUTUBE_KEY:
        raise RuntimeError("YOUTUBE_API_KEY missing")
    url = "https://www.googleapis.com/youtube/v3/search"
    params = {"key": YOUTUBE_KEY, "q": query, "part": "snippet",
              "maxResults": 1, "type": "video", "safeSearch": "strict"}
    async with httpx.AsyncClient(timeout=20) as c:
        r = await c.get(url, params=params)
        r.raise_for_status()
        data = r.json()
    if not data.get("items"):
        raise RuntimeError("YouTube returned no results")
    item = data["items"][0]
    return item["id"]["videoId"], item["snippet"]["title"]
```

- [ ] **Step 4: Run test — expect pass**

```bash
python3 -m pytest backend/tests/test_gemini_reflection.py -v
```

- [ ] **Step 5: Commit**

```bash
git add backend/app/services/gemini_reflection.py backend/tests/test_gemini_reflection.py
git commit -m "feat(backend): Gemini-based reflection content generator with YouTube search"
```

### Task 9.2: Wire `/parent/reflection/trigger` to live generator (with fixture fallback)

**Files:**
- Modify: `adaptive-engine/backend/app/services/bigkid_store.py`
- Modify: `adaptive-engine/backend/app/api/routes/bigkid_parent.py`

- [ ] **Step 1: Extend store to accept generated content**

In `bigkid_store.py`, add:

```python
def trigger_reflection_with_content(
    self, child_id: UUID, *, reason: str,
    video_id: str, video_title: str, writing_prompt: str,
    quiz_public: list[QuizQuestionPublic], correct_indices: list[int],
) -> ReflectionRequest:
    s = self._ensure_seeded(child_id)
    rid = uuid4()
    req = ReflectionRequest(
        id=rid, reason=reason,
        video_id=video_id, video_title=video_title,
        writing_prompt=writing_prompt, quiz=quiz_public,
        status=ReflectionStatus.pending,
    )
    s.reflection = req
    self._reflection_correct[(child_id, rid)] = correct_indices
    return req
```

- [ ] **Step 2: Update `bigkid_parent.py` trigger endpoint**

```python
import os
from backend.app.services.gemini_reflection import generate_reflection_content
from backend.app.schemas.bigkid import QuizQuestionPublic


@router.post("/parent/reflection/trigger", response_model=ReflectionRequest)
async def trigger_reflection(
    body: ParentReflectionTriggerBody,
    store: BigKidStore = Depends(get_store),
) -> ReflectionRequest:
    if os.environ.get("BIGKID_USE_GEMINI", "0") == "1":
        try:
            content = await generate_reflection_content(reason=body.reason)
            return store.trigger_reflection_with_content(
                body.child_id, reason=body.reason,
                video_id=content.video_id, video_title=content.video_title,
                writing_prompt=content.writing_prompt,
                quiz_public=[QuizQuestionPublic(q=q.q, options=q.options) for q in content.quiz],
                correct_indices=[q.correct_index for q in content.quiz],
            )
        except Exception:
            pass  # fall through to fixture
    return store.trigger_reflection(body.child_id, body.reason)
```

- [ ] **Step 3: Test fallback path with env var off**

```bash
BIGKID_USE_GEMINI=0 python3 -m pytest backend/tests/test_bigkid_endpoints.py::test_reflection_full_flow -v
```

Expected: still passes (uses fixture).

- [ ] **Step 4: Live smoke test (requires real keys)**

```bash
export GEMINI_API_KEY=...
export YOUTUBE_API_KEY=...
export BIGKID_USE_GEMINI=1
uvicorn app.main:app --port 8000 --reload &
curl -s -X POST http://localhost:8000/api/v1/parent/reflection/trigger \
     -H "Content-Type: application/json" \
     -d '{"child_id":"11111111-1111-1111-1111-111111111111","reason":"yelled at sister"}' \
     | python3 -m json.tool | head -30
```

Expected: real videoId + Gemini-generated quiz + writingPrompt.

- [ ] **Step 5: Commit**

```bash
git add backend/app/services/bigkid_store.py backend/app/api/routes/bigkid_parent.py
git commit -m "feat(backend): wire /parent/reflection/trigger to Gemini generator with fixture fallback"
```

---

## Phase 10: DeviceActivity Time-consumption Reporting

Goal: when the kid is in free-play (after `allTasksDone` and `minutesLeft > 0`), iOS reports consumption to the backend, decrementing `minutesLeft`. Use `DeviceActivityEvent` with a 5-minute threshold per spec §13 Q3.

### Task 10.1: Add `BigKidTimeReporter` service in iOS

**Files:**
- Create: `Evlin iOS/Evlin iOS/Services/BigKidTimeReporter.swift`

- [ ] **Step 1: Implement reporter that posts in 5-minute chunks**

```swift
import Foundation
import DeviceActivity
import FamilyControls
import ManagedSettings

/// Reports free-play consumption to the backend in 5-minute chunks.
/// Called from a `DeviceActivityMonitor` extension event handler that
/// fires when the kid hits the configured threshold while in free-play.
@MainActor
final class BigKidTimeReporter: ObservableObject {
    static let chunkMinutes = 5
    private let client: BigKidAPIClient

    init(client: BigKidAPIClient) { self.client = client }

    func reportChunk() async {
        do {
            try await client.reportTimeUse(minutesUsed: Self.chunkMinutes)
        } catch {
            // queue locally and retry next foreground; for v1 just log
            print("[BigKidTimeReporter] chunk report failed: \(error)")
        }
    }
}
```

- [ ] **Step 2: Add event configuration in main app**

In the existing app entry (search for `EvlinScreenTime` or `Evlin_iOSApp.swift`), add a function to start monitoring when `state.minutesLeft > 0` and `state.allTasksDone`. Stop when those conditions flip:

```swift
// New file: Evlin iOS/Evlin iOS/Services/BigKidActivityScheduler.swift
import Foundation
import DeviceActivity
import FamilyControls
import ManagedSettings

@MainActor
final class BigKidActivityScheduler {
    static let shared = BigKidActivityScheduler()
    private let center = DeviceActivityCenter()
    private let activityName = DeviceActivityName("evlin.bigkid.freeplay")
    private let eventName = DeviceActivityEvent.Name("evlin.bigkid.chunk")

    func start(threshold minutes: Int = BigKidTimeReporter.chunkMinutes,
               appsToMeasure: FamilyActivitySelection) {
        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59),
            repeats: true,
        )
        let event = DeviceActivityEvent(
            applications: appsToMeasure.applicationTokens,
            categories: appsToMeasure.categoryTokens,
            webDomains: appsToMeasure.webDomainTokens,
            threshold: DateComponents(minute: minutes),
        )
        try? center.startMonitoring(activityName,
                                    during: schedule,
                                    events: [eventName: event])
    }

    func stop() {
        center.stopMonitoring([activityName])
    }
}
```

- [ ] **Step 3: Update `EvlinDeviceActivityMonitor` extension to handle the new event**

Locate `EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift` (existing file). Add:

```swift
override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name,
                                      activity: DeviceActivityName) {
    super.eventDidReachThreshold(event, activity: activity)
    guard event.rawValue == "evlin.bigkid.chunk" else { return }
    // Hit the backend from the extension. Use shared keychain/UserDefaults
    // for the child token + base URL so we don't depend on the host app.
    Task { await BigKidExtensionReporter.shared.reportChunk() }
}
```

Create `EvlinDeviceActivityMonitor/BigKidExtensionReporter.swift`:

```swift
import Foundation

actor BigKidExtensionReporter {
    static let shared = BigKidExtensionReporter()

    func reportChunk() async {
        guard let baseURL = ExtensionConfig.baseURL,
              let childId = ExtensionConfig.childId else { return }
        var req = URLRequest(url: baseURL.appendingPathComponent("child/time-consumption"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(childId.uuidString, forHTTPHeaderField: "X-Child-Id")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["minutes_used": 5])
        _ = try? await URLSession.shared.data(for: req)
    }
}

enum ExtensionConfig {
    static var baseURL: URL? {
        let v = UserDefaults(suiteName: "group.com.evlin.ios")?.string(forKey: "evlin.baseURL")
        return v.flatMap { URL(string: $0) }
    }
    static var childId: UUID? {
        let v = UserDefaults(suiteName: "group.com.evlin.ios")?.string(forKey: "evlin.childId")
        return v.flatMap { UUID(uuidString: $0) }
    }
}
```

The host app must mirror its baseURL + childId into App Group defaults at startup (modify `Evlin_iOSApp` if not already done — search for `evlin.baseURL` to find existing pattern).

- [ ] **Step 4: Smoke test**

This requires real device + paired apps. Manual test plan:
1. Pair child mode, complete all 3 tasks, see `minutesLeft = 120`.
2. `BigKidActivityScheduler.shared.start(...)` invoked from app on entering home with time pool > 0.
3. Use Instagram (or whatever `appsToMeasure` covers) for 5 minutes.
4. Backend should receive `POST /child/time-consumption {minutes_used: 5}`.
5. App polls; `minutesLeft` decrements to 115.

- [ ] **Step 5: Commit**

```bash
git add "Evlin iOS/Services/BigKidTimeReporter.swift" \
        "Evlin iOS/Services/BigKidActivityScheduler.swift" \
        "EvlinDeviceActivityMonitor/BigKidExtensionReporter.swift" \
        "EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift"
git commit -m "feat(child): DeviceActivity 5-min chunk reporting to /child/time-consumption"
```

---

## Phase 11: End-to-End Real-Device Test

### Task 11.1: Manual E2E test plan

**Files:**
- Create: `Evlin iOS/docs/superpowers/checklists/2026-05-02-bigkid-e2e.md`

- [ ] **Step 1: Author the checklist**

```markdown
# Big-Kid Child Mode — E2E Manual Test Checklist

Run on a real iPhone paired to the Evlin parent device.

## Prerequisites
- Backend running on a network-reachable host (`uvicorn` on Mac + iPhone on same Wi-Fi).
- `evlin.baseURL` + `evlin.childId` set in Settings → BigKid.
- All Phase 0–10 commits merged.

## 1. Cold start, locked home
- [ ] Launch app in child mode → green Home appears.
- [ ] Hero card shows "SCREEN TIME LOCKED" + "Finish today's tasks to unlock".
- [ ] Three task rows visible, all "To do".

## 2. Task evidence flow
- [ ] Tap task 1 → TaskDetail input phase.
- [ ] Tap "Take a photo" → camera opens → capture → returns with "Photo ready".
- [ ] Add note "all done!" → tap Submit → returns to home (or submitted phase).
- [ ] Pip 1 turns green-300 (submitted).
- [ ] On parent device (or terminal `parent/task/.../review approve`) → within 60s pip turns full green-500.

## 3. Bypass auto-withdraw
- [ ] Tap task 2 → "I couldn't do this" → BypassView.
- [ ] Type reason → "Send to parent" → confirmation screen.
- [ ] Tap same task → submit photo evidence.
- [ ] Verify backend: `tasks[1].bypass.status == "withdrawn"`.

## 4. All tasks done → DailyComplete
- [ ] Approve all 3 tasks.
- [ ] App routes to DailyComplete celebration screen.
- [ ] Earned bar shows "120m / 120 MIN CAP".
- [ ] Tap Continue → green Home with time hero card.

## 5. Free-play time consumption
- [ ] With time pool unlocked, leave the app and use a measured-app for 5 minutes.
- [ ] Return to Evlin → minutesLeft decreased to 115.

## 6. Reflection trigger from parent
- [ ] On parent device, trigger reflection with reason.
- [ ] Within 60s child app routes to HomeReflection State A (brown).
- [ ] Tap "Start Reflection" → LockedScreen 0/3.

## 7. Video step
- [ ] Tap step 1 → VideoScreen plays YouTube embed.
- [ ] Skip / fast-forward → fails (controls disabled).
- [ ] Watch to end → "Continue" enables → tap → returns to LockedScreen 1/3.

## 8. Quiz step
- [ ] Tap step 2 → QuizScreen Q1.
- [ ] Pick wrong answer 5×, see results "Almost there", "Retry quiz".
- [ ] Retry, pick correct answers → "Nice work" 5/5.
- [ ] Tap Continue → returns to LockedScreen 2/3.

## 9. Writing step
- [ ] Tap step 3 → WritingScreen.
- [ ] Type 1 sentence → submit disabled.
- [ ] Reach ≥3 sentences, ≥40 chars, ≥12 unique words → submit enabled.
- [ ] Submit with <12 unique words → "can you add a bit more" inline tip.
- [ ] Submit valid → returns to HomeReflection State B.

## 10. State B nudge cooldown
- [ ] Hero card text: "You finished — nice work."
- [ ] Tap "Give them a nudge" → button changes to cooldown countdown.
- [ ] Wait 30s → countdown ticks down.
- [ ] Force-quit and relaunch → countdown still active (server-side).

## 11. Parent approves → Complete → Home
- [ ] On parent: approve reflection with note.
- [ ] Within 60s → CompleteScreen appears with parent note quoted.
- [ ] Summary shows video / quiz score / reflection.
- [ ] Tap "Back to home" → green Home (no reflection).

## 12. Out-of-time → ScreenTimeFinished
- [ ] Use time until `minutesLeft == 0`.
- [ ] App routes to ScreenTimeFinishedScreen.
- [ ] Tap OK → green Home shows "All used up" card.

## 13. Force-quit during reflection step
- [ ] Begin VideoScreen, force-quit during playback.
- [ ] Relaunch → returns to LockedScreen with step 1 still NOT completed.
- [ ] Re-enter VideoScreen → starts from beginning (scenePhase fallback per spec §6.2).

## 14. Server-down resilience
- [ ] Stop the backend.
- [ ] App polls fail; UI keeps last good state, shows no banner (v1 silent).
- [ ] Restart backend; within 60s state refreshes.
```

- [ ] **Step 2: Walk the checklist on hardware. Record any failures as separate bug issues; do not modify production code from inside the checklist.**

- [ ] **Step 3: Commit the checklist**

```bash
git add docs/superpowers/checklists/2026-05-02-bigkid-e2e.md
git commit -m "docs(child): E2E manual test checklist for big-kid mode"
```

---

## v1.1 — Deferred Items

Tracked here so they don't get lost. Not part of v1 execution.

### Deferred Task: AAC integration

- Wraps `BigKidVideoView`, `BigKidQuizView`, `BigKidWritingView` in `AEAssessmentSession`.
- Drops the `scenePhase` reset fallback from VideoScreen (AAC owns it).
- Requires Apple `com.apple.developer.automatic-assessment-configuration` entitlement (filed; ETA 2–6 weeks).
- Implementation is a single new wrapper view + entitlement plist + ~30 LOC; do not start until entitlement lands.

### Deferred Task: APNs push (replaces 60s polling)

- Silent push for status changes (parent approves, parent denies bypass, parent triggers reflection).
- Adds an `evlin-server-side` token table + APNs cert plumbing.
- Swap polling cadence to 30 minutes once push is reliable; keep poll as fallback.

### Deferred Task: Real DB persistence

- Replace `BigKidStore` in-memory with SQLAlchemy tables: `bigkid_child_state`, `bigkid_tasks`, `bigkid_reflection_requests`, `bigkid_bypass_requests`.
- Migrate existing in-memory contracts directly; keep the schema responses identical so iOS doesn't change.

### Deferred Task: Real Supabase Storage upload

- Replace `stub_upload_evidence` (Phase 2 Task 2.4) with actual Supabase Storage client per spec §13 Q4.
- Bucket policy: child can write, parent can read.

### Deferred Task: Home variant B (circular dial)

- Port `home.jsx` `HomeScreenB` as a parallel `BigKidHomeViewB`.
- Add a Settings toggle to switch between A and B at runtime.

### Deferred Task: Mascot illustrations

- When Esen ships final mascot art, port `EvlinMascot` to a SwiftUI view.
- Add to ScreenTimeFinishedScreen (top) and DailyCompleteScreen (top) per `consequence-b.jsx`.

---

## Self-Review

### 1. Spec coverage check

| Spec section | Plan coverage |
|---|---|
| §1 Goals | All 11 screens + backend + Gemini + DeviceActivity = covered. AAC explicitly v1.1. ✓ |
| §2 JSX truth source | Phase 1 ports tokens + primitives; every screen task in Phases 5–8 cites the JSX file + line range. ✓ |
| §3 Screen inventory | 11 screens covered: Home (5.2), HomeReflection A+B (5.3), TaskDetail 3-phase (6.2), Bypass (6.3), Locked (7.1), Video (7.2), Quiz (7.3), Writing (7.4), Complete (7.5), ScreenTimeFinished (8.1), DailyComplete (8.2). ✓ |
| §4 State model | Task 3.1 implements `BigKidState` + `ReflectionRequest` + `BypassRequest` etc. ✓ |
| §5 Routing | Phase 4 — pure router function with branch coverage tests. ✓ |
| §6.1 Normal day flow | Phase 6 (TaskDetail + evidence) + Phase 8 (DailyComplete) + Phase 10 (consumption). ✓ |
| §6.2 Reflection flow + State B | Phase 5.3 (State B with cooldown), Phase 7 (full sub-flow), Phase 7.6 wiring. ✓ |
| §6.3 Bypass parallel/auto-withdraw | Phase 2.5 backend test + Phase 6.3 UI + Phase 6.4 E2E smoke. ✓ |
| §7 iOS file structure | Files match spec layout — `Views/Child/BigKid/`, `Components/Kid/`, `Models/BigKid/`, `DesignSystem/EvlinKid*`. ✓ |
| §8.1 GET /child/state | Phase 2.3. ✓ |
| §8.2 POST /child/task/{id}/evidence | Phase 2.4. ✓ |
| §8.3 POST /child/bypass | Phase 2.5. ✓ |
| §8.4 POST /child/reflection/{id}/quiz-answer | Phase 2.6. ✓ |
| §8.5 POST /child/reflection/{id}/essay | Phase 2.6. ✓ |
| §8.6 POST /child/reflection/{id}/nudge + cooldown | Phase 2.6 + UI in 5.3. ✓ |
| §8.7 ack | Phase 2.6. ✓ |
| §8.8 daily-complete ack | Phase 2.6 + UI 8.2. ✓ |
| §8.9 screen-time-finished ack | Phase 2.6 + UI 8.1. ✓ |
| §8.10 time-consumption | Phase 2.6 backend + Phase 10 iOS reporter. ✓ |
| §8.11 parent-side endpoints | Phase 2.6 (`bigkid_parent.py`). ✓ |
| §9 Auth | Header-based shim (`X-Child-Id`) in Task 2.3; real pairing deferred (v1.1). Acceptable — spec §9 says no pairing changes in scope. ✓ |
| §10 Gemini | Phase 9. ✓ |
| §11 Divergences | Documented in plan: HomeReflection State B (Task 5.3), parent-approval gate (Task 7.6), bypass auto-withdraw (Task 2.5), no mascot, server-side correctIndex (Task 2.6 quiz answer endpoint), real consumption (Phase 10), no dev-tool buttons. ✓ |
| §12 Out-of-scope | Phase 9 ends + v1.1 section. ✓ |
| §13 Open questions | Q1+Q4 resolved in Phase 0; Q2 (State B copy) draft baked in 5.3, can be tweaked from spec; Q3 5-min threshold acknowledged in 10.1; Q5 resolved via `allTasksDone`. ✓ |
| §14 Verification | Phase 11 checklist covers every screen and the cross-cutting flows. ✓ |

### 2. Placeholder scan

- All steps include actual code, exact paths, exact commands.
- No "TBD", "TODO", "fill in later" except inside `// TODO Phase X` markers in iOS source where the next phase explicitly fills them in (deliberate forward references; not abandoned).
- No "Add appropriate error handling" hand-waving — error paths are explicit (`BigKidAPIError`, `lastError`, retry counters, etc.).

### 3. Type consistency

Spot-checks:
- `BigKidTask.bypass: BypassRequest?` declared in Task 3.1, used identically in Tasks 5.1 / 5.2 / 6.2.
- `ReflectionRequest.stepsCompleted: [BigKidReflectionStep]` declared in 3.1, queried as `.count` in 4.1 / 7.1.
- `BigKidStatePoller.refreshNow()` declared in 3.3, called in 4.2 / 6.2 / 7.6 / 8.x.
- `BigKidAPIClient.reflectionStepComplete(rid:step:)` declared in 3.2, called in 7.6.
- All Pydantic snake_case fields match Swift camelCase via `convertFromSnakeCase`.
- Backend `ReflectionStep` enum values (`video / quiz / writing`) match Swift `BigKidReflectionStep`.

No inconsistencies found.

---

**Plan complete and saved to `docs/superpowers/plans/2026-05-02-bigkid-child-mode-plan.md`.**

Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
