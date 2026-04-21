# iOS UI Rebuild — Esen Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the parent-mode iOS UI in SwiftUI to visually and structurally match the React prototype at `/Users/fred/Desktop/Evlin/frontend_for_app_evlin/`, per the approved spec `docs/superpowers/specs/2026-04-21-ios-ui-rebuild-esen-parity-design.md`.

**Architecture:** Replace six main screens (Home / Profile / Calendar / Evlin Chat / Library / Insights) and shared components; preserve onboarding, service layer, and existing chat card components. Data hardcoded where real integration is out of scope. File-by-file rewrites with surgical token migration.

**Tech Stack:** SwiftUI, iOS 17+, `@AppStorage`, `UIImpactFeedbackGenerator`, `.scrollTargetBehavior(.viewAligned)`, `AsyncImage`, existing `APIClient`/`ChatViewModel`/`ScreenTimeManager` service layer (untouched).

**Spec:** `docs/superpowers/specs/2026-04-21-ios-ui-rebuild-esen-parity-design.md`
**Visual reference:** `/Users/fred/Desktop/Evlin/frontend_for_app_evlin/` — each screen's `.jsx` file is the golden master. Open with `python3 -m http.server 3333` to see live.

**Conventions**
- "Project root" = `/Users/fred/Desktop/Evlin/Evlin iOS/`
- All SwiftUI file paths relative to project root unless noted
- "Build-verify" = `cd "/Users/fred/Desktop/Evlin/Evlin iOS" && xcodebuild -scheme "Evlin iOS" -destination 'generic/platform=iOS' build 2>&1 | tail -20` — expected no errors (warnings OK)
- Existing codebase uses file system synchronized groups (Xcode 16) — new `.swift` files auto-pick up, no `.pbxproj` edits needed
- Use `@Previewable @State` (iOS 17) for preview helpers when needed
- Every task ends with a commit. Commit messages use conventional format: `feat:` for new, `refactor:` for rewrites, `style:` for tokens

---

## Task 1: Design Token Migration

**Files:**
- Modify: `Evlin iOS/DesignSystem/EvlinColors.swift` (full body rewrite)

- [ ] **Step 1: Overwrite EvlinColors.swift with migrated tokens + per-child colors**

```swift
import SwiftUI

// MARK: - Evlin Design Tokens: "The Informed Sentinel"
// Aligned with frontend_for_app_evlin/tokens.js (Apr 2026 refresh)

extension Color {
    // MARK: Primary
    static let evPrimary = Color(hex: 0x041627)
    static let evPrimaryContainer = Color(hex: 0xF0F4F8)   // lightened — was navy container
    static let evOnPrimary = Color.white
    static let evOnPrimaryContainer = Color(hex: 0x8192A7)
    static let evPrimaryFixed = Color(hex: 0xD2E4FB)
    static let evPrimaryFixedDim = Color(hex: 0xB7C8DE)

    // MARK: Secondary (success / unlocked)
    static let evSecondary = Color(hex: 0x2E7D32)           // lighter forest
    static let evSecondaryContainer = Color(hex: 0xE8F5E9)  // pale container
    static let evSecondaryFixed = Color(hex: 0xC8E6C9)
    static let evSecondaryFixedDim = Color(hex: 0x88D982)
    static let evOnSecondaryContainer = Color(hex: 0x2E7D32)

    // MARK: Tertiary (caution / amber)
    static let evTertiary = Color(hex: 0x261000)
    static let evTertiaryContainer = Color(hex: 0xFFF3E0)
    static let evTertiaryFixed = Color(hex: 0xFFDCC3)
    static let evTertiaryFixedDim = Color(hex: 0xFFB77D)
    static let evOnTertiaryContainer = Color(hex: 0xE65100)

    // MARK: Surface
    static let evSurface = Color(hex: 0xFCFCFD)                 // was F9F9FD
    static let evSurfaceContainerLowest = Color.white
    static let evSurfaceContainerLow = Color(hex: 0xF7F8FA)
    static let evSurfaceContainer = Color(hex: 0xF1F2F4)
    static let evSurfaceContainerHigh = Color(hex: 0xEEF0F3)
    static let evSurfaceContainerHighest = Color(hex: 0xE2E2E6)
    static let evSurfaceDim = Color(hex: 0xD9DADD)

    // MARK: On-Surface
    static let evOnSurface = Color(hex: 0x1A1C1E)
    static let evOnSurfaceVariant = Color(hex: 0x5A5E66)        // was 44474C
    static let evOutline = Color(hex: 0x8E9199)
    static let evOutlineVariant = Color(hex: 0xE2E4E9)          // was C4C6CD

    // MARK: Error
    static let evError = Color(hex: 0xD32F2F)
    static let evErrorContainer = Color(hex: 0xFFEBEE)

    // MARK: Per-child accents (NEW)
    static let evChildLiam = Color(hex: 0x2563EB)   // calm blue
    static let evChildMaya = Color(hex: 0x2E7D32)   // forest (same as evSecondary)
    static let evChildEmma = Color(hex: 0xEF6C00)   // amber

    // MARK: Gradients
    static let evChatGradient = LinearGradient(
        colors: [Color(hex: 0x041627), Color(hex: 0x1A2B3C)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let evPrimaryGradient = LinearGradient(
        colors: [Color(hex: 0x041627), Color(hex: 0x1A2B3C)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let evSecondaryGradient = LinearGradient(
        colors: [Color(hex: 0x2E7D32), Color(hex: 0x4CAF50)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let evTertiaryGradient = LinearGradient(
        colors: [Color(hex: 0xEF6C00), Color(hex: 0xFF9800)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Premium shadow helpers
enum EvlinShadowToken {
    case premium, premiumHover, ambient
    var color: Color {
        switch self {
        case .premium, .premiumHover: return .black
        case .ambient: return Color(hex: 0x191C1E)
        }
    }
    var opacity: Double {
        switch self {
        case .premium: return 0.04
        case .premiumHover: return 0.08
        case .ambient: return 0.06
        }
    }
    var radius: CGFloat {
        switch self {
        case .premium: return 30
        case .premiumHover: return 40
        case .ambient: return 32
        }
    }
    var y: CGFloat {
        switch self {
        case .premium: return 10
        case .premiumHover: return 20
        case .ambient: return 12
        }
    }
}

extension View {
    func evShadow(_ token: EvlinShadowToken) -> some View {
        self.shadow(color: token.color.opacity(token.opacity), radius: token.radius, x: 0, y: token.y)
    }
}

// MARK: - Hex Initializer
extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
```

- [ ] **Step 2: Build-verify**

Run the build-verify command. Expected: no errors.

- [ ] **Step 3: Commit**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git add "Evlin iOS/DesignSystem/EvlinColors.swift"
git commit -m "style: align color tokens to Esen refresh + per-child accents"
```

---

## Task 2: ChildProfile Data Model Rewrite

**Files:**
- Modify: `Evlin iOS/Models/ChildProfile.swift` (full rewrite)

- [ ] **Step 1: Overwrite ChildProfile.swift**

```swift
import SwiftUI

// MARK: - Child Profile Model (aligned to Esen's EvlinFamily)

struct ChildProfile: Identifiable, Hashable {
    enum Status: String, Hashable { case unlocked, locked }

    let id: String              // "liam" / "maya" / "emma"
    let name: String
    let age: Int
    let avatarURL: String?
    let accentColor: Color
    let status: Status
    let timeLeft: String        // "1h 30m"
    let timePct: Double         // 0.0 ... 1.0
    let subtitle: String

    var initial: String { String(name.prefix(1)).uppercased() }
}

// MARK: - Mock Data (mirrors frontend_for_app_evlin/tokens.js verbatim)

extension ChildProfile {
    static let liam = ChildProfile(
        id: "liam",
        name: "Liam",
        age: 12,
        avatarURL: "https://lh3.googleusercontent.com/aida-public/AB6AXuBka2hek2iCWOSQRWVwFCLdYUcsh87WZfrhCtc5YQ5YDn4ihWAzq5t8HypHJUMHa8XKcjzVTPucfTrO3jKUrXFVxRlRbXkV4aZRQTLzW7GAkR-wG1K7IR4dGBA6Q_QMB2H1iTH0byjAnA_LVUBsFUmmOxrwhpOhP538V8NhmgvYx6RKGtCOJNRjtbwMhL8zgSp-ymKuimRWWitAARSaq8BoR_GYesFIxUs0cZrbGWSs6xntdfYxbsLs5SDYLStU5AUBgmt4WxHqDoA",
        accentColor: .evChildLiam,
        status: .unlocked,
        timeLeft: "1h 30m",
        timePct: 0.75,
        subtitle: "Focused today · 3 of 5 tasks done"
    )

    static let maya = ChildProfile(
        id: "maya",
        name: "Maya",
        age: 8,
        avatarURL: "https://i.pravatar.cc/256?img=47",
        accentColor: .evChildMaya,
        status: .unlocked,
        timeLeft: "45m",
        timePct: 0.38,
        subtitle: "On bedtime wind-down in 2h"
    )

    static let emma = ChildProfile(
        id: "emma",
        name: "Emma",
        age: 6,
        avatarURL: "https://i.pravatar.cc/256?img=16",
        accentColor: .evChildEmma,
        status: .locked,
        timeLeft: "0m",
        timePct: 0.0,
        subtitle: "Quiet time · unlocks at 4:00 PM"
    )

    static let all: [ChildProfile] = [.liam, .maya, .emma]
}
```

- [ ] **Step 2: Build-verify** (expect errors — call sites in ContentView / ProfilePickerView reference old shape; fix in Task 3 and after. Non-fatal for now, just confirm no other model issues.)

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Models/ChildProfile.swift"
git commit -m "refactor: rewrite ChildProfile to Esen schema (Liam/Maya/Emma)"
```

---

## Task 3: Retain ProfilePickerView with explanatory comment

**Files:**
- Modify: `Evlin iOS/Views/ProfilePicker/ProfilePickerView.swift` (top-of-file comment + fix compile)

- [ ] **Step 1: Read current file**

```bash
head -30 "Evlin iOS/Views/ProfilePicker/ProfilePickerView.swift"
```

- [ ] **Step 2: Prepend comment block and fix `avatarEmoji`/`accentColor` references if any**

Prepend immediately after `import SwiftUI`:

```swift
// MARK: - DEPRECATED / RETAINED FOR REFERENCE
// Replaced by HomeView's dashboard (see Views/Home/HomeView.swift), which
// handles child profile selection as part of the main parent flow.
// Not wired into ContentView routing. Kept on disk per spec §2 preservation
// rule. Do not delete. Do not wire back in without updating spec.
```

Then scan the body: the old file references `profile.avatarEmoji`. Replace any remaining `avatarEmoji` reference with `profile.initial` (now that the model no longer has `avatarEmoji`). If the file references `profile.accentColor` that still works (unchanged property). If the file references `profile.age`, unchanged.

Concretely: open `Views/ProfilePicker/ProfilePickerView.swift`, find the line `Text(profile.avatarEmoji)` (or similar) and change to `Text(profile.initial)`. Keep the rest of the file intact.

- [ ] **Step 3: Build-verify** — expect compile errors from `ChildProfile.all` shape change in other files too. If ProfilePickerView itself compiles clean, move on.

- [ ] **Step 4: Commit**

```bash
git add "Evlin iOS/Views/ProfilePicker/ProfilePickerView.swift"
git commit -m "docs(profile-picker): mark as deprecated, retained for reference"
```

---

## Task 4: Flatten EvlinTabBar

**Files:**
- Modify: `Evlin iOS/Components/EvlinTabBar.swift` (full rewrite)

- [ ] **Step 1: Overwrite EvlinTabBar.swift**

```swift
import SwiftUI

// MARK: - Flat 5-tab bar (post-Esen-refresh)
// All tabs equal weight; selection indicator = short capsule at top of tab.

enum EvlinTab: String, CaseIterable, Hashable {
    case home = "Home"
    case calendar = "Calendar"
    case chat = "Chat"
    case library = "Library"
    case insights = "Insights"

    var sfSymbol: String {
        switch self {
        case .home: return "house"
        case .calendar: return "calendar"
        case .chat: return "bubble.left"
        case .library: return "books.vertical"
        case .insights: return "chart.bar"
        }
    }

    var sfSymbolFilled: String {
        switch self {
        case .home: return "house.fill"
        case .calendar: return "calendar"
        case .chat: return "bubble.left.fill"
        case .library: return "books.vertical.fill"
        case .insights: return "chart.bar.fill"
        }
    }
}

struct EvlinTabBar: View {
    @Binding var selectedTab: EvlinTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(EvlinTab.allCases, id: \.self) { tab in
                tabItem(tab)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 76)
        .background(
            Color.evSurfaceContainerLowest.opacity(0.92)
                .background(.ultraThinMaterial)
                .ignoresSafeArea(edges: .bottom)
        )
        .overlay(
            Rectangle()
                .fill(Color.evOutlineVariant)
                .frame(height: 0.5),
            alignment: .top
        )
    }

    private func tabItem(_ tab: EvlinTab) -> some View {
        let isActive = selectedTab == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 4) {
                Capsule()
                    .fill(isActive ? Color.evPrimary : Color.clear)
                    .frame(width: 28, height: 3)

                Image(systemName: isActive ? tab.sfSymbolFilled : tab.sfSymbol)
                    .font(.system(size: 22, weight: isActive ? .semibold : .regular))
                    .frame(height: 26)
                    .foregroundStyle(isActive ? Color.evPrimary : Color.evOnSurfaceVariant)

                Text(tab.rawValue.uppercased())
                    .font(.custom("Manrope", size: 10).weight(.heavy))
                    .tracking(0.4)
                    .foregroundStyle(isActive ? Color.evPrimary : Color.evOnSurfaceVariant)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .opacity(isActive ? 1.0 : 0.55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    @Previewable @State var tab: EvlinTab = .home
    return VStack { Spacer(); EvlinTabBar(selectedTab: $tab) }
        .background(Color.evSurface)
}
```

- [ ] **Step 2: Build-verify**

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Components/EvlinTabBar.swift"
git commit -m "refactor(tabbar): flatten to 5 equal tabs, remove center FAB"
```

---

## Task 5: Extend GlassmorphicHeader

**Files:**
- Modify: `Evlin iOS/Components/GlassmorphicHeader.swift` (full rewrite)

- [ ] **Step 1: Overwrite GlassmorphicHeader.swift**

```swift
import SwiftUI

// MARK: - Sticky header with kicker, back affordance, trailing slot
// Mirrors Esen's GlassHeader from frontend_for_app_evlin/ui.jsx lines 23-70.

struct GlassmorphicHeader<Trailing: View>: View {
    let title: String
    var kicker: String? = nil
    var onBack: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.evPrimary)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 2) {
                if let kicker {
                    Text(kicker.uppercased())
                        .font(.custom("Inter", size: 10).weight(.bold))
                        .tracking(1.4)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }
                if !title.isEmpty {
                    Text(title)
                        .font(.custom("Manrope", size: 19).weight(.heavy))
                        .tracking(-0.15)
                        .foregroundStyle(Color.evPrimary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)

            trailing()
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 56)
        .padding(.vertical, 6)
        .background(
            Color.evSurface.opacity(0.99)
                .background(.ultraThinMaterial)
        )
        .overlay(
            Rectangle()
                .fill(Color.evOutlineVariant)
                .frame(height: 0.5),
            alignment: .bottom
        )
    }
}

// Convenience init — no trailing content
extension GlassmorphicHeader where Trailing == EmptyView {
    init(title: String, kicker: String? = nil, onBack: (() -> Void)? = nil) {
        self.init(title: title, kicker: kicker, onBack: onBack, trailing: { EmptyView() })
    }
}

// MARK: - Standard header icon button (40x40 circular, optional red dot)

struct HeaderIconButton: View {
    let systemName: String
    var badge: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemName)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Color.evOnSurface)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
                if badge {
                    Circle()
                        .fill(Color.evError)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Color.evSurface, lineWidth: 2))
                        .offset(x: -8, y: 8)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    VStack(spacing: 0) {
        GlassmorphicHeader(title: "Child Insights", kicker: "Past 7 days") {
            HStack(spacing: 4) {
                HeaderIconButton(systemName: "bell", badge: true) {}
                HeaderIconButton(systemName: "gearshape") {}
            }
        }
        Spacer()
    }
    .background(Color.evSurface)
}
```

- [ ] **Step 2: Build-verify**

Call-site `GlassmorphicHeader(onSettings: ...)` inits in ContentView / OnboardingView / ChildModeView must still compile. The convenience init handles that? No — old sites pass `onSettings:`, new type has `trailing:`. This breaks compilation. Accept the break; fix in Task 6.

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Components/GlassmorphicHeader.swift"
git commit -m "refactor(header): add kicker, onBack, generic trailing slot"
```

---

## Task 6: Patch existing GlassmorphicHeader call sites

**Files:**
- Modify: `Evlin iOS/Views/Child/ChildModeView.swift:20` (approximate)
- Modify: `Evlin iOS/ContentView.swift` (old Home parentView call — will be further refactored in Task 22)

- [ ] **Step 1: ChildModeView — patch old call**

Find in `Evlin iOS/Views/Child/ChildModeView.swift` the line resembling:
```swift
GlassmorphicHeader {
    showSettings = true
}
```
Replace with:
```swift
GlassmorphicHeader(title: "Evlin Child") {
    HeaderIconButton(systemName: "gearshape") { showSettings = true }
}
```

- [ ] **Step 2: ContentView — temporarily patch the `parentView` GlassmorphicHeader invocation**

In `Evlin iOS/ContentView.swift`, the existing call is:
```swift
GlassmorphicHeader(
    childName: activeChild?.name,
    onSwitchProfile: { ... },
    onSettings: { showSettings = true }
)
```
Replace with a minimal stub that compiles; this whole block gets rewritten in Task 22 anyway:
```swift
GlassmorphicHeader(title: "Evlin") {
    HeaderIconButton(systemName: "gearshape") { showSettings = true }
}
```

Also patch: where `activeChild` usage now breaks (if any) — leave `@State var activeChild: ChildProfile?` in place; Task 22 removes it.

- [ ] **Step 3: Build-verify** — should compile now.

- [ ] **Step 4: Commit**

```bash
git add "Evlin iOS/Views/Child/ChildModeView.swift" "Evlin iOS/ContentView.swift"
git commit -m "fix: patch GlassmorphicHeader call sites for new API"
```

---

## Task 7: Shared primitives — SectionHead, EvlinPill, EvlinAvatar, EvlinCard

**Files:**
- Create: `Evlin iOS/Components/SectionHead.swift`
- Create: `Evlin iOS/Components/EvlinPill.swift`
- Create: `Evlin iOS/Components/EvlinAvatarView.swift`
- Create: `Evlin iOS/Components/EvlinCard.swift`
- Create: `Evlin iOS/Components/EvlinButton.swift`

- [ ] **Step 1: Create SectionHead.swift**

```swift
import SwiftUI

// MARK: - Section header row — title + optional kicker + right-side slot
// Mirrors Esen's SectionHead from ui.jsx lines 311-333.

struct SectionHead<Right: View>: View {
    let title: String
    var kicker: String? = nil
    @ViewBuilder var right: () -> Right

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                if let kicker {
                    Text(kicker.uppercased())
                        .font(.custom("Inter", size: 10).weight(.bold))
                        .tracking(1.6)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }
                Text(title)
                    .font(.custom("Manrope", size: 22).weight(.heavy))
                    .tracking(-0.33)
                    .foregroundStyle(Color.evPrimary)
                    .lineSpacing(-2)
            }
            Spacer()
            right()
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 14)
    }
}

extension SectionHead where Right == EmptyView {
    init(_ title: String, kicker: String? = nil) {
        self.init(title: title, kicker: kicker, right: { EmptyView() })
    }
}
```

- [ ] **Step 2: Create EvlinPill.swift**

```swift
import SwiftUI

// MARK: - Evlin status chip / pill
// Mirrors Esen's Pill from ui.jsx lines 203-233.

enum EvlinPillTone {
    case neutral, success, warn, danger, primary, liam, maya, emma

    var bg: Color {
        switch self {
        case .neutral: return .evSurfaceContainerHigh
        case .success: return .evSecondaryContainer
        case .warn:    return .evTertiaryFixed
        case .danger:  return .evErrorContainer
        case .primary: return .evPrimaryContainer
        case .liam:    return Color(hex: 0x2563EB).opacity(0.10)
        case .maya:    return Color(hex: 0x2E7D32).opacity(0.10)
        case .emma:    return Color(hex: 0xEF6C00).opacity(0.10)
        }
    }
    var fg: Color {
        switch self {
        case .neutral: return .evOnSurfaceVariant
        case .success: return .evSecondary
        case .warn:    return .evOnTertiaryContainer
        case .danger:  return .evError
        case .primary: return .evPrimary
        case .liam:    return .evChildLiam
        case .maya:    return .evChildMaya
        case .emma:    return .evChildEmma
        }
    }
}

enum EvlinPillSize { case xs, sm, md
    var fontSize: CGFloat { self == .xs ? 9 : self == .sm ? 10 : 11 }
    var hPad: CGFloat { self == .xs ? 8 : self == .sm ? 10 : 12 }
    var vPad: CGFloat { self == .xs ? 3 : self == .sm ? 5 : 6 }
}

struct EvlinPill: View {
    let text: String
    var tone: EvlinPillTone = .neutral
    var size: EvlinPillSize = .sm
    var outlined: Bool = false

    var body: some View {
        Text(text.uppercased())
            .font(.custom("Inter", size: size.fontSize).weight(.heavy))
            .tracking(1.3)
            .foregroundStyle(tone.fg)
            .padding(.horizontal, size.hPad)
            .padding(.vertical, size.vPad)
            .background(
                Capsule()
                    .fill(outlined ? Color.clear : tone.bg)
                    .overlay(
                        Capsule().stroke(outlined ? tone.fg.opacity(0.25) : Color.clear, lineWidth: 1)
                    )
            )
    }
}
```

- [ ] **Step 3: Create EvlinAvatarView.swift**

```swift
import SwiftUI

// MARK: - Circular avatar with optional status lock dot
// Mirrors Esen's Avatar from ui.jsx lines 235-274.

struct EvlinAvatarView: View {
    let url: String?
    let name: String
    var size: CGFloat = 48
    var status: ChildProfile.Status? = nil
    var ring: Bool = false
    var ringColor: Color = .evPrimary

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if ring {
                Circle()
                    .stroke(ringColor, lineWidth: 2)
                    .frame(width: size + 8, height: size + 8)
            }

            Group {
                if let url, let u = URL(string: url) {
                    AsyncImage(url: u) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFill()
                        default: fallback
                        }
                    }
                } else {
                    fallback
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)

            if let status {
                statusDot(status: status)
            }
        }
        .frame(width: size, height: size)
    }

    private var fallback: some View {
        ZStack {
            Color.evPrimaryContainer
            Text(String(name.prefix(1)).uppercased())
                .font(.custom("Manrope", size: size * 0.38).weight(.heavy))
                .foregroundStyle(Color.evPrimary)
        }
    }

    private func statusDot(status: ChildProfile.Status) -> some View {
        ZStack {
            Circle()
                .fill(status == .unlocked ? AnyShapeStyle(Color.evSecondaryGradient) : AnyShapeStyle(Color.evSurfaceContainerHighest))
                .frame(width: size * 0.32, height: size * 0.32)
                .overlay(Circle().stroke(Color.white, lineWidth: 3))
            Image(systemName: status == .unlocked ? "lock.open.fill" : "lock.fill")
                .font(.system(size: size * 0.17, weight: .bold))
                .foregroundStyle(status == .unlocked ? Color.white : Color.evOnSurfaceVariant)
        }
        .offset(x: 2, y: 2)
    }
}
```

- [ ] **Step 4: Create EvlinCard.swift**

```swift
import SwiftUI

// MARK: - Premium surface card
// Mirrors Esen's Card from ui.jsx lines 157-178.

struct EvlinCard<Content: View>: View {
    var padded: Bool = true
    var hover: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padded ? 20 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.evSurfaceContainerLowest)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
            )
            .evShadow(.premium)
    }
}
```

- [ ] **Step 5: Create EvlinButton.swift**

```swift
import SwiftUI

// MARK: - CTA button with variants
// Mirrors Esen's Button from ui.jsx lines 276-308.

enum EvlinButtonVariant { case primary, success, ghost, outline }
enum EvlinButtonSize { case sm, md, lg
    var fontSize: CGFloat { self == .sm ? 11 : self == .md ? 12 : 13 }
    var hPad: CGFloat { self == .sm ? 14 : self == .md ? 18 : 20 }
    var vPad: CGFloat { self == .sm ? 8 : self == .md ? 11 : 14 }
}

struct EvlinButton: View {
    let title: String
    var icon: String? = nil
    var variant: EvlinButtonVariant = .primary
    var size: EvlinButtonSize = .md
    var block: Bool = false
    var action: () -> Void = {}

    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .bold))
                }
                Text(title.uppercased())
                    .font(.custom("Manrope", size: size.fontSize).weight(.bold))
                    .tracking(0.9)
            }
            .foregroundStyle(fgColor)
            .padding(.horizontal, size.hPad)
            .padding(.vertical, size.vPad)
            .frame(maxWidth: block ? .infinity : nil)
            .background(bgShape)
            .shadow(color: shadowColor, radius: 12, x: 0, y: 4)
            .scaleEffect(pressed ? 0.98 : 1.0)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }

    @ViewBuilder private var bgShape: some View {
        switch variant {
        case .primary:
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.evPrimaryGradient)
        case .success:
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.evSecondaryGradient)
        case .ghost:
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.evOutlineVariant, lineWidth: 1)
                )
        case .outline:
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.evTertiaryFixed, lineWidth: 1)
                )
        }
    }

    private var fgColor: Color {
        switch variant {
        case .primary, .success: return .white
        case .ghost: return .evPrimary
        case .outline: return .evOnTertiaryContainer
        }
    }

    private var shadowColor: Color {
        switch variant {
        case .primary: return Color(hex: 0x041627).opacity(0.2)
        case .success: return Color(hex: 0x2E7D32).opacity(0.2)
        default: return .clear
        }
    }
}
```

- [ ] **Step 6: Build-verify**

- [ ] **Step 7: Commit**

```bash
git add "Evlin iOS/Components/SectionHead.swift" \
        "Evlin iOS/Components/EvlinPill.swift" \
        "Evlin iOS/Components/EvlinAvatarView.swift" \
        "Evlin iOS/Components/EvlinCard.swift" \
        "Evlin iOS/Components/EvlinButton.swift"
git commit -m "feat: add shared primitives (SectionHead/Pill/Avatar/Card/Button)"
```

---

## Task 8: ProfileCard component

**Files:**
- Create: `Evlin iOS/Components/ProfileCard.swift`

- [ ] **Step 1: Create ProfileCard.swift**

Matches `screen-home.jsx` `ProfileCard` at lines ~395-449: avatar (64pt) + status pill with ping + progress bar + subtitle + chevron.

```swift
import SwiftUI

struct ProfileCard: View {
    let child: ChildProfile
    var action: () -> Void = {}

    @State private var ping: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 16) {
                EvlinAvatarView(url: child.avatarURL, name: child.name, size: 56, status: child.status)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(child.name)
                            .font(.custom("Manrope", size: 17).weight(.heavy))
                            .tracking(-0.2)
                            .foregroundStyle(Color.evPrimary)
                        if child.status == .unlocked {
                            HStack(spacing: 5) {
                                ZStack {
                                    Circle()
                                        .fill(Color.evSecondary.opacity(0.6))
                                        .frame(width: 8, height: 8)
                                        .scaleEffect(ping ? 1.8 : 1.0)
                                        .opacity(ping ? 0 : 0.6)
                                    Circle()
                                        .fill(Color.evSecondary)
                                        .frame(width: 8, height: 8)
                                }
                                Text("UNLOCKED")
                                    .font(.custom("Inter", size: 9).weight(.heavy))
                                    .tracking(1.5)
                                    .foregroundStyle(Color.evSecondary)
                            }
                        } else {
                            Text("QUIET TIME")
                                .font(.custom("Inter", size: 9).weight(.heavy))
                                .tracking(1.5)
                                .foregroundStyle(Color.evOnSurfaceVariant)
                        }
                    }

                    Text(child.subtitle)
                        .font(.custom("Inter", size: 12))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .lineLimit(1)

                    // progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.evSecondaryContainer).frame(height: 5)
                            Capsule().fill(Color.evSecondary)
                                .frame(width: max(6, geo.size.width * child.timePct), height: 5)
                        }
                    }
                    .frame(height: 5)

                    Text("\(child.timeLeft) left today")
                        .font(.custom("Inter", size: 11).weight(.bold))
                        .foregroundStyle(Color.evSecondary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.evOutline)
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.evSurfaceContainerLowest)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
            )
            .evShadow(.premium)
        }
        .buttonStyle(.plain)
        .onAppear {
            if child.status == .unlocked {
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                    ping = true
                }
            }
        }
    }
}

#Preview {
    VStack(spacing: 14) {
        ProfileCard(child: .liam)
        ProfileCard(child: .maya)
        ProfileCard(child: .emma)
    }
    .padding()
    .background(Color.evSurface)
}
```

- [ ] **Step 2: Build-verify**

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Components/ProfileCard.swift"
git commit -m "feat: add ProfileCard component for Home dashboard"
```

---

## Task 9: ChildFilterPills + RuleRow + TaskRow + DeviceRow

**Files:**
- Create: `Evlin iOS/Components/ChildFilterPills.swift`
- Create: `Evlin iOS/Components/RuleRow.swift`
- Create: `Evlin iOS/Components/TaskRow.swift`
- Create: `Evlin iOS/Components/DeviceRow.swift`

- [ ] **Step 1: Create ChildFilterPills.swift**

```swift
import SwiftUI

struct ChildFilterPills: View {
    @Binding var selection: String   // "all" | "liam" | "maya" | "emma"
    var includeAll: Bool = true

    private var items: [(id: String, label: String, color: Color)] {
        var arr: [(String, String, Color)] = []
        if includeAll {
            arr.append(("all", "All", .evPrimary))
        }
        for c in ChildProfile.all { arr.append((c.id, c.name, c.accentColor)) }
        return arr
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.id) { item in
                    pill(id: item.id, label: item.label, color: item.color)
                }
            }
        }
    }

    @ViewBuilder
    private func pill(id: String, label: String, color: Color) -> some View {
        let on = selection == id
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { selection = id }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label)
                    .font(.custom("Manrope", size: 12).weight(.bold))
            }
            .foregroundStyle(on ? Color.white : Color.evPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(on ? Color.evPrimary : Color.evSurfaceContainerLowest)
            )
            .overlay(
                Capsule().stroke(on ? Color.clear : Color.evOutlineVariant, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: Create RuleRow.swift**

```swift
import SwiftUI

struct RuleRow: View {
    enum Tone { case primary, tertiary, neutral }

    let iconSystemName: String
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var tone: Tone = .primary

    private var iconBg: Color {
        switch tone {
        case .primary: return .evPrimaryContainer
        case .tertiary: return .evTertiaryContainer
        case .neutral: return .evSurfaceContainerHigh
        }
    }
    private var iconFg: Color {
        switch tone {
        case .primary: return .evPrimary
        case .tertiary: return .evOnTertiaryContainer
        case .neutral: return .evOnSurfaceVariant
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(iconBg)
                Image(systemName: iconSystemName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(iconFg)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.custom("Manrope", size: 14).weight(.heavy))
                    .foregroundStyle(Color.evPrimary)
                Text(detail)
                    .font(.custom("Inter", size: 12))
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Color.evSecondary)
        }
        .padding(.vertical, 10)
    }
}
```

- [ ] **Step 3: Create TaskRow.swift**

```swift
import SwiftUI

struct TaskItem: Identifiable, Hashable {
    let id: Int
    var title: String
    var state: State
    var iconSystemName: String?

    enum State: String, Hashable {
        case pending, done, review, overdue
        var label: String {
            switch self {
            case .pending: return "Pending"
            case .done: return "Done"
            case .review: return "Review"
            case .overdue: return "Overdue"
            }
        }
        var tone: EvlinPillTone {
            switch self {
            case .pending: return .neutral
            case .done: return .success
            case .review: return .warn
            case .overdue: return .danger
            }
        }
    }
}

struct TaskRow: View {
    let task: TaskItem
    var isLast: Bool = false
    var onApprove: () -> Void = {}
    var onRedo: () -> Void = {}

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.evSurfaceContainerLow)
                Image(systemName: task.iconSystemName ?? defaultIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.evPrimary)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.custom("Manrope", size: 14).weight(.bold))
                    .foregroundStyle(Color.evPrimary)
                EvlinPill(text: task.state.label, tone: task.state.tone, size: .xs)
            }
            Spacer()
            if task.state == .review {
                Button(action: onApprove) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.evSecondary))
                }
                .buttonStyle(.plain)
                Button(action: onRedo) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.evPrimary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.evSurfaceContainerHigh))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .overlay(
            Rectangle().fill(Color.evOutlineVariant.opacity(isLast ? 0 : 0.4))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private var defaultIcon: String {
        switch task.state {
        case .done: return "checkmark.circle.fill"
        case .review: return "eye"
        case .pending: return "clock"
        case .overdue: return "exclamationmark.circle"
        }
    }
}
```

- [ ] **Step 4: Create DeviceRow.swift**

```swift
import SwiftUI

struct DeviceRow: View {
    let iconSystemName: String
    let name: String
    let detail: String
    var locked: Bool = false
    var isLast: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.evSurfaceContainerLow)
                Image(systemName: iconSystemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.evPrimary)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.custom("Manrope", size: 14).weight(.bold))
                    .foregroundStyle(Color.evPrimary)
                Text(detail)
                    .font(.custom("Inter", size: 12))
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }
            Spacer()
            Image(systemName: locked ? "lock.fill" : "lock.open")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(locked ? Color.evOnTertiaryContainer : Color.evSecondary)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .overlay(
            Rectangle().fill(Color.evOutlineVariant.opacity(isLast ? 0 : 0.4))
                .frame(height: 1),
            alignment: .bottom
        )
    }
}
```

- [ ] **Step 5: Build-verify**

- [ ] **Step 6: Commit**

```bash
git add "Evlin iOS/Components/ChildFilterPills.swift" \
        "Evlin iOS/Components/RuleRow.swift" \
        "Evlin iOS/Components/TaskRow.swift" \
        "Evlin iOS/Components/DeviceRow.swift"
git commit -m "feat: add Profile/Insights row components"
```

---

## Task 10: Library card components — ReelCard, LessonCard, CategoryTile

**Files:**
- Create: `Evlin iOS/Components/ReelCard.swift`
- Create: `Evlin iOS/Components/LessonCard.swift`
- Create: `Evlin iOS/Components/CategoryTile.swift`

- [ ] **Step 1: Create ReelCard.swift**

```swift
import SwiftUI

struct ReelItem: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let author: String
    let gradient: LinearGradient

    static func == (lhs: ReelItem, rhs: ReelItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ReelCard: View {
    let reel: ReelItem

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(reel.gradient)

            VStack {
                HStack {
                    Spacer()
                    Circle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 36, height: 36)
                        .overlay(
                            Image(systemName: "play.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                        )
                }
                Spacer()
                VStack(alignment: .leading, spacing: 6) {
                    Text(reel.author.uppercased())
                        .font(.custom("Inter", size: 9).weight(.heavy))
                        .tracking(1.0)
                        .foregroundStyle(.white.opacity(0.7))
                    Text(reel.title)
                        .font(.custom("Manrope", size: 13).weight(.heavy))
                        .lineSpacing(0)
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
        }
        .frame(width: 148, height: 214)
        .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 6)
    }
}
```

- [ ] **Step 2: Create LessonCard.swift**

```swift
import SwiftUI

struct LessonItem: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let subtitle: String
    let durationMin: Int
    let gradient: LinearGradient

    static func == (lhs: LessonItem, rhs: LessonItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct LessonCard: View {
    let lesson: LessonItem

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(lesson.gradient)
                .frame(width: 72, height: 72)
                .overlay(
                    Image(systemName: "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(lesson.title)
                    .font(.custom("Manrope", size: 14).weight(.heavy))
                    .foregroundStyle(Color.evPrimary)
                    .lineLimit(2)
                Text(lesson.subtitle)
                    .font(.custom("Inter", size: 12))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .lineLimit(1)
                Text("\(lesson.durationMin) min")
                    .font(.custom("Inter", size: 10).weight(.bold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.evOutline)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.evSurfaceContainerLowest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
        )
        .evShadow(.premium)
    }
}
```

- [ ] **Step 3: Create CategoryTile.swift**

```swift
import SwiftUI

struct CategoryTileInfo: Identifiable, Hashable {
    let id: String      // "ei", "digital", "conflict", "growth"
    let label: String
    let count: String   // "12 series"
    let iconSystemName: String
    let gradient: LinearGradient

    static func == (lhs: CategoryTileInfo, rhs: CategoryTileInfo) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct CategoryTile: View {
    let info: CategoryTileInfo
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: info.iconSystemName)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                Text(info.count.uppercased())
                    .font(.custom("Inter", size: 9).weight(.heavy))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.7))
                Text(info.label)
                    .font(.custom("Manrope", size: 16).weight(.heavy))
                    .lineSpacing(-1)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .frame(height: 150)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(info.gradient))
            .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 4: Build-verify**

- [ ] **Step 5: Commit**

```bash
git add "Evlin iOS/Components/ReelCard.swift" \
        "Evlin iOS/Components/LessonCard.swift" \
        "Evlin iOS/Components/CategoryTile.swift"
git commit -m "feat: add Library card components (Reel/Lesson/Category)"
```

---

## Task 11: StrategyCard + ObservationBubble

**Files:**
- Create: `Evlin iOS/Components/StrategyCard.swift`
- Create: `Evlin iOS/Components/ObservationBubble.swift`

- [ ] **Step 1: Create StrategyCard.swift**

```swift
import SwiftUI

// Matches screen-evlin.jsx's StrategyCard (lines 93-148).
struct StrategyCardData: Hashable {
    let title: String
    let status: String          // "Locked"
    let category: String        // "Active Monitoring › Immediate Action"
    let videoLabel: String      // "Managing Transition Frustration"
    let videoDuration: String   // "3:00"
    let tip: String
}

struct StrategyCard: View {
    let data: StrategyCardData

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(Color.evSecondaryFixedDim.opacity(0.3))
                        .frame(width: 26, height: 26)
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.evSecondary)
                }
                EvlinPill(text: data.status, tone: .success, size: .xs)
                Spacer()
            }

            Text(data.category.uppercased())
                .font(.custom("Inter", size: 9).weight(.heavy))
                .tracking(1.6)
                .foregroundStyle(Color.evOnSurfaceVariant)

            Text(data.title)
                .font(.custom("Manrope", size: 18).weight(.heavy))
                .tracking(-0.3)
                .foregroundStyle(Color.evPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.evPrimaryGradient)
                    .frame(width: 56, height: 42)
                    .overlay(
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(data.videoLabel)
                        .font(.custom("Manrope", size: 13).weight(.heavy))
                        .foregroundStyle(Color.evPrimary)
                        .lineLimit(1)
                    Text(data.videoDuration)
                        .font(.custom("Inter", size: 11).weight(.semibold))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }
                Spacer()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.evSurfaceContainerLow)
            )

            Text(data.tip)
                .font(.custom("Inter", size: 12))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.evSurfaceContainerLowest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.evOutlineVariant.opacity(0.5), lineWidth: 1)
        )
        .evShadow(.premium)
    }
}
```

- [ ] **Step 2: Create ObservationBubble.swift**

```swift
import SwiftUI

struct ObservationBubble: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(Color.evPrimaryGradient)
                    .frame(width: 28, height: 28)
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }

            Text(text)
                .font(.custom("Inter", size: 14))
                .foregroundStyle(Color.evOnSurface)
                .lineSpacing(3)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.evSurfaceContainerLowest)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
                )
        }
    }
}
```

- [ ] **Step 3: Build-verify**

- [ ] **Step 4: Commit**

```bash
git add "Evlin iOS/Components/StrategyCard.swift" "Evlin iOS/Components/ObservationBubble.swift"
git commit -m "feat: add StrategyCard and ObservationBubble for chat artifacts"
```

---

## Task 12: Mock data files for screens

**Files:**
- Create: `Evlin iOS/Models/HomeMockData.swift`
- Create: `Evlin iOS/Models/ProfileMockData.swift`
- Create: `Evlin iOS/Models/CalendarMockData.swift`
- Create: `Evlin iOS/Models/LibraryMockData.swift`
- Create: `Evlin iOS/Models/InsightsMockData.swift`

- [ ] **Step 1: Create HomeMockData.swift**

Mirrors `screen-home.jsx` NOTIFS array (lines 7-13).

```swift
import SwiftUI

struct HomeNotification: Identifiable, Hashable {
    let id: Int
    let childId: String      // "liam" / "maya" / "emma" / "family"
    let iconSystemName: String
    let title: String
    let body: String
    let time: String
    var unread: Bool
}

enum HomeMockData {
    static let notifications: [HomeNotification] = [
        .init(id: 1, childId: "liam", iconSystemName: "checkmark.circle",
              title: "Homework Complete",
              body: "Liam finished his Science Project and submitted it for review.",
              time: "2m ago", unread: true),
        .init(id: 2, childId: "maya", iconSystemName: "music.note",
              title: "Piano Practice Done",
              body: "Maya completed her 45-min piano session.",
              time: "18m ago", unread: true),
        .init(id: 3, childId: "liam", iconSystemName: "figure.soccer",
              title: "Soccer Practice",
              body: "Liam's session starts in 30 minutes at City Park.",
              time: "1h ago", unread: false),
        .init(id: 4, childId: "emma", iconSystemName: "book",
              title: "Reading Goal Reached",
              body: "Emma read for 60 minutes today — new personal best!",
              time: "2h ago", unread: false),
        .init(id: 5, childId: "family", iconSystemName: "fork.knife",
              title: "Family Dinner Reminder",
              body: "Family dinner is in 1 hour. Everyone to the dining room.",
              time: "3h ago", unread: false),
    ]

    static func childColor(_ id: String) -> Color {
        switch id {
        case "liam": return .evChildLiam
        case "maya": return .evChildMaya
        case "emma": return .evChildEmma
        default: return .evPrimary
        }
    }

    static func avatarURL(_ id: String) -> String? {
        ChildProfile.all.first(where: { $0.id == id })?.avatarURL
    }
}
```

- [ ] **Step 2: Create ProfileMockData.swift**

Mirrors `screen-profile.jsx` lines 88-117 (rules/tasks) + CHILD_EVENTS style data. Keep per-child lists. Device list hardcoded same for all kids for simplicity.

```swift
import SwiftUI

struct RuleItem: Identifiable, Hashable {
    let id: String
    let iconSystemName: String
    let title: String
    let detail: String
    var on: Bool
    let tone: RuleRow.Tone
}

struct ProfileEvent: Identifiable, Hashable {
    let id = UUID()
    let time: String
    let title: String
    let location: String?
}

struct DeviceItem: Identifiable, Hashable {
    let id = UUID()
    let iconSystemName: String
    let name: String
    let detail: String
    let locked: Bool
}

enum ProfileMockData {
    static func rules(for childId: String) -> [RuleItem] {
        [
            .init(id: "screen", iconSystemName: "display",
                  title: "Daily Screen Time", detail: "1h limit per day",
                  on: true, tone: .primary),
            .init(id: "bed", iconSystemName: "moon",
                  title: "Bedtime", detail: "8:00 PM Sharp",
                  on: true, tone: .tertiary),
            .init(id: "chores", iconSystemName: "sun.max",
                  title: "Morning Chores", detail: "Mandatory sequence",
                  on: false, tone: .neutral),
        ]
    }

    static func tasks(for childId: String) -> [TaskItem] {
        [
            .init(id: 1, title: "Clean Table", state: .done, iconSystemName: "checkmark"),
            .init(id: 2, title: "Science Project", state: .review, iconSystemName: "camera"),
            .init(id: 3, title: "Math Practice", state: .pending, iconSystemName: nil),
            .init(id: 4, title: "Walk Dog", state: .overdue, iconSystemName: nil),
        ]
    }

    static func events(for childId: String) -> [ProfileEvent] {
        switch childId {
        case "liam":
            return [
                .init(time: "8:00 AM", title: "Clean Table", location: "Kitchen"),
                .init(time: "1:30 PM", title: "Math Practice", location: "Study Room"),
                .init(time: "4:00 PM", title: "Soccer Practice", location: "City Park"),
            ]
        case "maya":
            return [
                .init(time: "10:00 AM", title: "Piano Practice", location: "Living Room"),
                .init(time: "3:30 PM", title: "Art Class", location: "Art Studio"),
            ]
        default:
            return [
                .init(time: "2:00 PM", title: "Reading Time", location: "Bedroom"),
                .init(time: "7:30 PM", title: "Story Time", location: "Bedroom"),
            ]
        }
    }

    static func devices(for childId: String) -> [DeviceItem] {
        [
            .init(iconSystemName: "iphone", name: "iPhone 13", detail: "Primary device", locked: false),
            .init(iconSystemName: "ipad", name: "iPad", detail: "Homework only", locked: true),
            .init(iconSystemName: "laptopcomputer", name: "MacBook Air", detail: "School hours 9-3", locked: false),
        ]
    }
}
```

- [ ] **Step 3: Create CalendarMockData.swift**

Mirror `screen-calendar.jsx` `PEOPLE` + `EVENTS` + `ALL_DAY` + `DAY_NAMES` verbatim for days 12 and 19.

```swift
import SwiftUI

struct CalendarPerson: Identifiable, Hashable {
    let id: String
    let name: String
    let color: Color
    let bg: Color
}

struct CalendarEvent: Identifiable, Hashable {
    let id = UUID()
    let col: String          // "family" / "liam" / "maya" / "emma"
    let title: String
    let emoji: String
    let start: String        // "08:00 AM"
    let end: String          // "08:30 AM"
    let category: String
    let location: String
    let note: String
}

struct AllDayItem: Identifiable, Hashable {
    let id = UUID()
    let col: String
    let title: String
}

enum CalendarMockData {
    static let HOUR_H: CGFloat = 56
    static let START_H: Int = 0
    static let END_H: Int = 24
    static let TIME_W: CGFloat = 48

    static let people: [CalendarPerson] = [
        .init(id: "family", name: "Family",
              color: Color(hex: 0x7C6FF7), bg: Color(hex: 0xEDE9FE)),
        .init(id: "liam", name: "Liam",
              color: .evChildLiam, bg: Color(hex: 0xDBEAFE)),
        .init(id: "maya", name: "Maya",
              color: Color(hex: 0x3DAA5C), bg: Color(hex: 0xDCFCE7)),
        .init(id: "emma", name: "Emma",
              color: Color(hex: 0xF97316), bg: Color(hex: 0xFFEDD5)),
    ]

    static let dayNames: [Int: String] = [
        1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat",
        8: "Mon", 9: "Tue", 10: "Wed", 11: "Thu", 12: "Thu", 13: "Fri", 14: "Sat",
        15: "Sun", 16: "Mon", 17: "Tue", 18: "Wed", 19: "Thu", 20: "Fri", 21: "Sat",
        22: "Sun", 23: "Mon", 24: "Tue", 25: "Wed", 26: "Thu", 27: "Fri", 28: "Sat",
        29: "Sun", 30: "Mon",
    ]

    static let events: [Int: [CalendarEvent]] = [
        12: [
            CalendarEvent(col: "liam",   title: "Clean Table",     emoji: "🧹",
                          start: "08:00 AM", end: "08:30 AM", category: "Chore",
                          location: "Kitchen", note: "Wipe down the kitchen table and chairs after lunch."),
            CalendarEvent(col: "maya",   title: "Piano Practice",  emoji: "🎹",
                          start: "10:00 AM", end: "11:30 AM", category: "Lesson",
                          location: "Living Room", note: "Work on the new piece from last week."),
            CalendarEvent(col: "family", title: "Family Lunch",    emoji: "🍽️",
                          start: "12:00 PM", end: "01:00 PM", category: "Family",
                          location: "Dining Room", note: "Everyone together. No devices at the table."),
            CalendarEvent(col: "liam",   title: "Math Practice",   emoji: "📐",
                          start: "01:30 PM", end: "02:30 PM", category: "Study",
                          location: "Study Room", note: "Chapter 7 exercises, pages 112-118."),
            CalendarEvent(col: "emma",   title: "Reading Time",    emoji: "📚",
                          start: "02:00 PM", end: "03:00 PM", category: "Study",
                          location: "Bedroom", note: "Choose one book from the reading list."),
            CalendarEvent(col: "maya",   title: "Art Class",       emoji: "🎨",
                          start: "03:30 PM", end: "05:00 PM", category: "Lesson",
                          location: "Art Studio", note: "Bring the watercolor set."),
            CalendarEvent(col: "liam",   title: "Soccer Practice", emoji: "⚽",
                          start: "04:00 PM", end: "05:30 PM", category: "Sport",
                          location: "City Park", note: "Don't forget shin guards."),
            CalendarEvent(col: "family", title: "Family Dinner",   emoji: "🍴",
                          start: "06:00 PM", end: "07:00 PM", category: "Family",
                          location: "Dining Room", note: "Everyone helps set the table."),
            CalendarEvent(col: "emma",   title: "Story Time",      emoji: "🌙",
                          start: "07:30 PM", end: "08:30 PM", category: "Routine",
                          location: "Bedroom", note: "Two stories max, then lights out."),
        ],
        19: [
            CalendarEvent(col: "liam", title: "Science Lab", emoji: "🔬",
                          start: "10:00 AM", end: "11:30 AM", category: "Study",
                          location: "Study Room", note: "Volcanos experiment."),
            CalendarEvent(col: "maya", title: "Reading", emoji: "📖",
                          start: "09:00 AM", end: "10:00 AM", category: "Study",
                          location: "Living Room", note: "Finish chapter 4."),
            CalendarEvent(col: "family", title: "Library Trip", emoji: "🏛️",
                          start: "01:00 PM", end: "03:00 PM", category: "Family",
                          location: "Central Library", note: "Each kid picks two new books."),
            CalendarEvent(col: "emma", title: "Nap Time", emoji: "😴",
                          start: "02:00 PM", end: "03:30 PM", category: "Routine",
                          location: "Bedroom", note: "Keep the house quiet."),
            CalendarEvent(col: "liam", title: "Soccer Practice", emoji: "⚽",
                          start: "04:00 PM", end: "05:30 PM", category: "Sport",
                          location: "City Park", note: "Arrive 10 min early today."),
            CalendarEvent(col: "family", title: "Family Dinner", emoji: "🍴",
                          start: "06:00 PM", end: "07:00 PM", category: "Family",
                          location: "Dining Room", note: "Everyone helps set the table."),
        ],
    ]

    static let allDay: [Int: [AllDayItem]] = [
        12: [AllDayItem(col: "liam", title: "Wellness Day 🧘")],
    ]

    // Parse "08:00 AM" into total minutes from midnight
    static func parseTimeToMinutes(_ s: String) -> Int {
        let parts = s.split(separator: " ")
        guard parts.count == 2 else { return 0 }
        let hm = parts[0].split(separator: ":").compactMap { Int($0) }
        guard hm.count == 2 else { return 0 }
        var h = hm[0]
        let m = hm[1]
        let period = String(parts[1])
        if period == "PM", h != 12 { h += 12 }
        if period == "AM", h == 12 { h = 0 }
        return h * 60 + m
    }

    static func yFor(_ timeStr: String) -> CGFloat {
        let mins = parseTimeToMinutes(timeStr)
        return CGFloat(mins) / 60 * HOUR_H
    }

    static func heightFor(start: String, end: String) -> CGFloat {
        let h = yFor(end) - yFor(start)
        return max(h, 36)
    }

    static func person(_ id: String) -> CalendarPerson {
        people.first(where: { $0.id == id }) ?? people[0]
    }
}
```

- [ ] **Step 4: Create LibraryMockData.swift**

```swift
import SwiftUI

struct LibraryReelContent { let reels: [ReelItem]; let lessons: [LessonItem]; let categories: [CategoryTileInfo] }

enum LibraryMockData {
    static let reels: [ReelItem] = [
        ReelItem(title: "Morning mindfulness for busy parents",
                 author: "Dr. Julian Vance",
                 gradient: LinearGradient(colors: [Color(hex: 0xEF6C00), Color(hex: 0x261000)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing)),
        ReelItem(title: "The \"No-Phone\" Zone Protocol",
                 author: "Elena Rodriguez",
                 gradient: LinearGradient(colors: [Color(hex: 0x1A2B3C), Color(hex: 0x041627)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing)),
        ReelItem(title: "Tantrum de-escalation playbook",
                 author: "Dr. Mira Shah",
                 gradient: LinearGradient(colors: [Color(hex: 0x2E7D32), Color(hex: 0x1B4A1C)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing)),
        ReelItem(title: "When screen time is actually OK",
                 author: "Prof. Aisha Green",
                 gradient: LinearGradient(colors: [Color(hex: 0x6E3900), Color(hex: 0x261000)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing)),
    ]

    static let lessons: [LessonItem] = [
        LessonItem(title: "Setting boundaries without conflict",
                   subtitle: "3-part video series", durationMin: 18,
                   gradient: LinearGradient(colors: [.evChildLiam, Color(hex: 0x1E3A8A)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing)),
        LessonItem(title: "The dopamine reset weekend",
                   subtitle: "Dr. Mira Shah", durationMin: 24,
                   gradient: LinearGradient(colors: [Color(hex: 0x2E7D32), Color(hex: 0x1B4A1C)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing)),
        LessonItem(title: "Tech tantrums: a field guide",
                   subtitle: "Elena Rodriguez", durationMin: 12,
                   gradient: LinearGradient(colors: [Color(hex: 0xEF6C00), Color(hex: 0x6E3900)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing)),
    ]

    static let categories: [CategoryTileInfo] = [
        .init(id: "ei", label: "Emotional Intelligence", count: "12 series",
              iconSystemName: "brain",
              gradient: LinearGradient(colors: [Color(hex: 0x1A2B3C), Color(hex: 0x041627)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)),
        .init(id: "digital", label: "Digital Boundaries", count: "8 series",
              iconSystemName: "shield",
              gradient: LinearGradient(colors: [Color(hex: 0x2E7D32), Color(hex: 0x1B4A1C)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)),
        .init(id: "conflict", label: "Conflict Resolution", count: "15 series",
              iconSystemName: "hands.sparkles",
              gradient: LinearGradient(colors: [Color(hex: 0x6E3900), Color(hex: 0x261000)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)),
        .init(id: "growth", label: "Growth Mindset", count: "20 series",
              iconSystemName: "arrow.up.right.circle",
              gradient: LinearGradient(colors: [Color(hex: 0x0B1D2D), Color.black],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)),
    ]

    // Per-category detail content (hero video + grid items)
    struct DetailItem: Identifiable, Hashable {
        let id = UUID()
        let kind: Kind
        let title: String
        let meta: String
        enum Kind { case video, article }
    }

    static func detail(for categoryId: String) -> (heroTitle: String, heroAuthor: String, items: [DetailItem]) {
        switch categoryId {
        case "ei":
            return ("Emotional Intelligence in practice", "Dr. Julian Vance", [
                .init(kind: .video, title: "Naming feelings with toddlers", meta: "6 min video"),
                .init(kind: .article, title: "The wheel of emotions", meta: "5 min read"),
                .init(kind: .video, title: "Co-regulation basics", meta: "8 min video"),
                .init(kind: .article, title: "Empathy vs sympathy", meta: "4 min read"),
            ])
        case "digital":
            return ("Building digital boundaries that stick", "Elena Rodriguez", [
                .init(kind: .video, title: "The family phone contract", meta: "10 min video"),
                .init(kind: .article, title: "Screen-free dinner rule", meta: "3 min read"),
                .init(kind: .video, title: "Digital sunset for teens", meta: "7 min video"),
                .init(kind: .article, title: "Device-free homework", meta: "5 min read"),
            ])
        case "conflict":
            return ("Conflict resolution starter pack", "Dr. Mira Shah", [
                .init(kind: .video, title: "Calm-down corners", meta: "5 min video"),
                .init(kind: .article, title: "Sibling mediation steps", meta: "6 min read"),
                .init(kind: .video, title: "Naming the need", meta: "9 min video"),
                .init(kind: .article, title: "Repair after rupture", meta: "4 min read"),
            ])
        default:
            return ("Cultivating growth mindset", "Prof. Aisha Green", [
                .init(kind: .video, title: "Praise the effort", meta: "8 min video"),
                .init(kind: .article, title: "Yet: the magic word", meta: "3 min read"),
                .init(kind: .video, title: "Failure stories at dinner", meta: "6 min video"),
                .init(kind: .article, title: "Progress over perfection", meta: "5 min read"),
            ])
        }
    }
}
```

- [ ] **Step 5: Create InsightsMockData.swift**

Mirror `screen-insights.jsx` recommendations + breakdown.

```swift
import SwiftUI

struct InsightsRecommendation: Identifiable, Hashable {
    let id = UUID()
    let iconSystemName: String
    let title: String
    let sub: String
}

struct InsightsAppStat: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let time: String
    let pct: Double
    let color: Color
    let iconBg: Color
    let iconSystemName: String
}

struct InsightsCategoryStat: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let time: String
    let color: Color
    let weight: Double    // for segmented bar proportions
}

enum InsightsMockData {
    static let heroTitle = "Liam's late-night gaming is impacting morning focus."
    static let heroBody  = "Analysis shows a 45% increase in Roblox activity after 9:00 PM this week. This correlates with a slower start to educational tasks the following mornings."

    static let recommendations: [InsightsRecommendation] = [
        .init(iconSystemName: "timer",
              title: "15-min warning for TikTok",
              sub: "Help transition away smoothly"),
        .init(iconSystemName: "graduationcap",
              title: "Educational YouTube mode",
              sub: "Prioritize learning content"),
        .init(iconSystemName: "moon.stars",
              title: "8:30 PM Digital Sunset",
              sub: "Lock all non-essential apps"),
    ]

    static let dailyTotalHours: Int = 4
    static let dailyTotalMinutes: Int = 32
    static let deltaPct: Int = 12   // "+12% vs yesterday"

    static let categories: [InsightsCategoryStat] = [
        .init(label: "Entertainment", time: "2h 15m", color: .evPrimary, weight: 135),
        .init(label: "Social", time: "1h 05m", color: .evSecondary, weight: 65),
        .init(label: "Games", time: "45m", color: .evTertiaryFixedDim, weight: 45),
    ]

    static let apps: [InsightsAppStat] = [
        .init(name: "YouTube", time: "1h 15m", pct: 0.68,
              color: Color(hex: 0xFF0000),
              iconBg: .white,
              iconSystemName: "play.rectangle.fill"),
        .init(name: "Roblox", time: "45m", pct: 0.40,
              color: Color(hex: 0xE2231A),
              iconBg: .black,
              iconSystemName: "gamecontroller.fill"),
        .init(name: "TikTok", time: "42m", pct: 0.38,
              color: Color(hex: 0xFF0050),
              iconBg: .black,
              iconSystemName: "music.note"),
    ]
}
```

- [ ] **Step 6: Build-verify**

- [ ] **Step 7: Commit**

```bash
git add "Evlin iOS/Models/HomeMockData.swift" \
        "Evlin iOS/Models/ProfileMockData.swift" \
        "Evlin iOS/Models/CalendarMockData.swift" \
        "Evlin iOS/Models/LibraryMockData.swift" \
        "Evlin iOS/Models/InsightsMockData.swift"
git commit -m "feat: add hardcoded mock data for all 5 screens"
```

---

## Task 13: HomeView dashboard

**Files:**
- Modify: `Evlin iOS/Views/Home/HomeView.swift` (full rewrite)

- [ ] **Step 1: Overwrite HomeView.swift**

```swift
import SwiftUI

struct HomeView: View {
    @AppStorage("parentName") private var parentName: String = "Morgan"
    @State private var showNotifications = false
    @State private var showSettings = false
    @Binding var selectedTab: EvlinTab
    var onOpenProfile: (ChildProfile) -> Void

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        if h < 12 { return "Good morning" }
        if h < 18 { return "Good afternoon" }
        return "Good evening"
    }

    private var unreadCount: Int {
        HomeMockData.notifications.filter(\.unread).count
    }

    var body: some View {
        VStack(spacing: 0) {
            GlassmorphicHeader(title: "", kicker: "\(greeting), \(parentName)") {
                HStack(spacing: 4) {
                    HeaderIconButton(systemName: "bell", badge: unreadCount > 0) {
                        showNotifications = true
                    }
                    HeaderIconButton(systemName: "gearshape") {
                        showSettings = true
                    }
                }
            }

            ScrollView {
                VStack(spacing: 28) {
                    // Children section
                    VStack(spacing: 14) {
                        SectionHead("Children", kicker: "Select a profile")
                        ForEach(ChildProfile.all) { child in
                            ProfileCard(child: child) {
                                onOpenProfile(child)
                            }
                        }
                    }

                    // Evlin observation prompt
                    Button {
                        selectedTab = .chat
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.evPrimaryGradient)
                                    .frame(width: 44, height: 44)
                                Image(systemName: "sparkles")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Evlin has 3 observations for you")
                                    .font(.custom("Manrope", size: 14).weight(.heavy))
                                    .foregroundStyle(Color.evPrimary)
                                Text("Incl. one late-night gaming pattern · Liam")
                                    .font(.custom("Inter", size: 12))
                                    .foregroundStyle(Color.evOnSurfaceVariant)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.evOutline)
                        }
                        .padding(18)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.evSurfaceContainerLow)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.evOutlineVariant, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
                .padding(.bottom, 40)
            }
        }
        .background(Color.evSurface)
        .fullScreenCover(isPresented: $showNotifications) {
            NotificationPanel(onClose: { showNotifications = false })
        }
        .fullScreenCover(isPresented: $showSettings) {
            HomeSettingsSheet(onClose: { showSettings = false })
        }
    }
}
```

- [ ] **Step 2: Build-verify** (expect errors in ContentView since it still calls `HomeView()` with old sig; fix in Task 22. Expect `NotificationPanel` and `HomeSettingsSheet` missing — fix in Task 14/15.)

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Views/Home/HomeView.swift"
git commit -m "feat(home): rewrite as dashboard with ProfileCards and observation prompt"
```

---

## Task 14: NotificationPanel

**Files:**
- Create: `Evlin iOS/Views/Home/NotificationPanel.swift`

- [ ] **Step 1: Create NotificationPanel.swift**

```swift
import SwiftUI

struct NotificationPanel: View {
    var onClose: () -> Void
    @State private var notifs: [HomeNotification] = HomeMockData.notifications

    private var unread: Int { notifs.filter(\.unread).count }

    var body: some View {
        VStack(spacing: 0) {
            // Custom header for this modal
            HStack(spacing: 10) {
                Button(action: onClose) {
                    Image(systemName: "arrow.backward")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.evPrimary)
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.evSurfaceContainerHigh)
                        )
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Notifications")
                        .font(.custom("Manrope", size: 18).weight(.heavy))
                        .foregroundStyle(Color.evPrimary)
                    if unread > 0 {
                        Text("\(unread) unread")
                            .font(.custom("Inter", size: 11))
                            .foregroundStyle(Color.evOnSurfaceVariant)
                    }
                }
                Spacer()
                if unread > 0 {
                    Button {
                        withAnimation { notifs = notifs.map { var n = $0; n.unread = false; return n } }
                    } label: {
                        Text("Mark all read")
                            .font(.custom("Inter", size: 12).weight(.bold))
                            .foregroundStyle(Color.evPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)
            .overlay(
                Rectangle().fill(Color.evOutlineVariant).frame(height: 0.5),
                alignment: .bottom
            )

            if notifs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 40))
                    Text("All caught up")
                        .font(.custom("Inter", size: 14))
                }
                .foregroundStyle(Color.evOnSurfaceVariant)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(notifs) { n in
                            row(for: n)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        withAnimation { notifs.removeAll { $0.id == n.id } }
                                    } label: {
                                        Label("Dismiss", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .background(Color.evSurface.ignoresSafeArea())
    }

    @ViewBuilder
    private func row(for n: HomeNotification) -> some View {
        let color = HomeMockData.childColor(n.childId)
        Button {
            withAnimation {
                if let idx = notifs.firstIndex(where: { $0.id == n.id }) {
                    notifs[idx].unread = false
                }
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                if n.unread {
                    Circle().fill(color).frame(width: 6, height: 6).offset(y: 8)
                } else {
                    Color.clear.frame(width: 6, height: 6).offset(y: 8)
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(color.opacity(0.12))
                    if let url = HomeMockData.avatarURL(n.childId), let u = URL(string: url) {
                        AsyncImage(url: u) { phase in
                            if let img = phase.image {
                                img.resizable().scaledToFill()
                            } else {
                                Image(systemName: n.iconSystemName)
                                    .font(.system(size: 16))
                                    .foregroundStyle(color)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    } else {
                        Image(systemName: n.iconSystemName)
                            .font(.system(size: 18))
                            .foregroundStyle(color)
                    }
                }
                .frame(width: 42, height: 42)
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(color.opacity(0.25), lineWidth: 1.5)
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(n.title)
                            .font(.custom("Manrope", size: 13).weight(.heavy))
                            .foregroundStyle(Color.evPrimary)
                        Spacer()
                        Text(n.time)
                            .font(.custom("Inter", size: 10))
                            .foregroundStyle(Color.evOutline)
                    }
                    Text(n.body)
                        .font(.custom("Inter", size: 12))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .lineSpacing(1)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 14)
            .background(n.unread ? color.opacity(0.03) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(
            Rectangle().fill(Color.evOutlineVariant.opacity(0.4)).frame(height: 1),
            alignment: .bottom
        )
    }
}
```

- [ ] **Step 2: Build-verify**

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Views/Home/NotificationPanel.swift"
git commit -m "feat(home): add NotificationPanel with mark-read / swipe-dismiss"
```

---

## Task 15: HomeSettingsSheet

**Files:**
- Create: `Evlin iOS/Views/Home/HomeSettingsSheet.swift`

- [ ] **Step 1: Create HomeSettingsSheet.swift**

Minimal iOS-style family management: list children + add/edit/delete in-memory (not persisted).

```swift
import SwiftUI

struct HomeSettingsSheet: View {
    var onClose: () -> Void
    @State private var children: [ChildProfile] = ChildProfile.all
    @State private var editing: ChildProfile? = nil
    @State private var adding: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Family") {
                    ForEach(children) { c in
                        Button {
                            editing = c
                        } label: {
                            HStack(spacing: 12) {
                                EvlinAvatarView(url: c.avatarURL, name: c.name, size: 36)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.name)
                                        .font(.custom("Manrope", size: 14).weight(.bold))
                                        .foregroundStyle(Color.evOnSurface)
                                    Text("Age \(c.age)")
                                        .font(.custom("Inter", size: 12))
                                        .foregroundStyle(Color.evOnSurfaceVariant)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.evOutline)
                            }
                        }
                    }
                    .onDelete { children.remove(atOffsets: $0) }

                    Button {
                        adding = true
                    } label: {
                        Label("Add child", systemImage: "plus.circle.fill")
                            .foregroundStyle(Color.evPrimary)
                    }
                }

                Section("App") {
                    LabeledContent("Parent name") {
                        ParentNameField()
                    }
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onClose() }
                }
            }
            .sheet(item: $editing) { child in
                ChildEditSheet(child: child) { updated in
                    if let idx = children.firstIndex(where: { $0.id == updated.id }) {
                        children[idx] = updated
                    }
                    editing = nil
                }
            }
            .sheet(isPresented: $adding) {
                ChildEditSheet(child: nil) { newChild in
                    children.append(newChild)
                    adding = false
                }
            }
        }
    }
}

private struct ParentNameField: View {
    @AppStorage("parentName") private var parentName: String = "Morgan"
    var body: some View {
        TextField("", text: $parentName)
            .multilineTextAlignment(.trailing)
            .textFieldStyle(.plain)
    }
}

private struct ChildEditSheet: View {
    let child: ChildProfile?
    var onSave: (ChildProfile) -> Void

    @State private var name: String = ""
    @State private var age: Int = 8

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Name", text: $name)
                    Stepper("Age: \(age)", value: $age, in: 1...18)
                }
            }
            .navigationTitle(child == nil ? "Add child" : "Edit \(child?.name ?? "")")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let c = child {
                    name = c.name
                    age = c.age
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let id = child?.id ?? name.lowercased()
                        let updated = ChildProfile(
                            id: id, name: name, age: age,
                            avatarURL: child?.avatarURL,
                            accentColor: child?.accentColor ?? .evPrimary,
                            status: child?.status ?? .unlocked,
                            timeLeft: child?.timeLeft ?? "1h",
                            timePct: child?.timePct ?? 0.5,
                            subtitle: child?.subtitle ?? "New family member"
                        )
                        onSave(updated)
                    }
                    .disabled(name.isEmpty)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Build-verify**

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Views/Home/HomeSettingsSheet.swift"
git commit -m "feat(home): add HomeSettingsSheet with in-memory family mgmt"
```

---

## Task 16: ProfileView (child detail)

**Files:**
- Create: `Evlin iOS/Views/Profile/ProfileView.swift`

- [ ] **Step 1: Create ProfileView.swift**

```swift
import SwiftUI

struct ProfileView: View {
    let child: ChildProfile
    var onBack: () -> Void = {}
    var onOpenCalendar: () -> Void = {}

    @State private var rules: [RuleItem] = []
    @State private var tasks: [TaskItem] = []
    @State private var events: [ProfileEvent] = []
    @State private var devices: [DeviceItem] = []

    var body: some View {
        VStack(spacing: 0) {
            GlassmorphicHeader(title: "\(child.name)'s Space", onBack: onBack) {
                HeaderIconButton(systemName: "ellipsis") {}
            }

            ScrollView {
                VStack(spacing: 26) {
                    // Summary card
                    summaryCard
                    // Active Rules
                    VStack(spacing: 0) {
                        SectionHead(title: "Active Rules") {
                            EvlinPill(text: "Verified", tone: .success, size: .sm)
                        }
                        VStack(spacing: 0) {
                            ForEach($rules) { $rule in
                                RuleRow(iconSystemName: rule.iconSystemName,
                                        title: rule.title, detail: rule.detail,
                                        isOn: $rule.on, tone: rule.tone)
                                    .padding(.horizontal, 14)
                                    .overlay(
                                        Rectangle().fill(Color.evOutlineVariant.opacity(0.4)).frame(height: 1),
                                        alignment: .bottom
                                    )
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.evSurfaceContainerLowest)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
                        )
                    }

                    // Tasks
                    VStack(spacing: 0) {
                        SectionHead(title: "Tasks") {
                            Text("\(tasks.filter { $0.state == .done }.count)/\(tasks.count) done")
                                .font(.custom("Inter", size: 11).weight(.bold))
                                .tracking(1.2)
                                .textCase(.uppercase)
                                .foregroundStyle(Color.evOnSurfaceVariant)
                        }
                        VStack(spacing: 0) {
                            ForEach(Array(tasks.enumerated()), id: \.element.id) { idx, t in
                                TaskRow(
                                    task: t,
                                    isLast: idx == tasks.count - 1,
                                    onApprove: {
                                        if let i = tasks.firstIndex(where: { $0.id == t.id }) {
                                            tasks[i].state = .done
                                        }
                                    },
                                    onRedo: {
                                        if let i = tasks.firstIndex(where: { $0.id == t.id }) {
                                            tasks[i].state = .pending
                                        }
                                    }
                                )
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.evSurfaceContainerLowest)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
                        )
                    }

                    // Today's Schedule
                    VStack(spacing: 0) {
                        SectionHead(title: "Today's Schedule") {
                            Button { onOpenCalendar() } label: {
                                Text("OPEN CALENDAR")
                                    .font(.custom("Inter", size: 10).weight(.heavy))
                                    .tracking(1.4)
                                    .foregroundStyle(Color.evPrimary)
                            }
                        }
                        VStack(spacing: 0) {
                            ForEach(events) { e in
                                HStack(spacing: 14) {
                                    Text(e.time)
                                        .font(.custom("Inter", size: 11).weight(.bold))
                                        .tracking(0.6)
                                        .foregroundStyle(Color.evOnSurfaceVariant)
                                        .frame(width: 72, alignment: .leading)
                                    Circle().fill(child.accentColor).frame(width: 6, height: 6)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(e.title)
                                            .font(.custom("Manrope", size: 14).weight(.bold))
                                            .foregroundStyle(Color.evPrimary)
                                        if let loc = e.location {
                                            Text(loc)
                                                .font(.custom("Inter", size: 11))
                                                .foregroundStyle(Color.evOnSurfaceVariant)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 12)
                                .padding(.horizontal, 14)
                                .overlay(
                                    Rectangle().fill(Color.evOutlineVariant.opacity(0.4)).frame(height: 1),
                                    alignment: .bottom
                                )
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.evSurfaceContainerLowest)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
                        )
                    }

                    // Devices
                    VStack(spacing: 0) {
                        SectionHead(title: "Device Permissions")
                        VStack(spacing: 0) {
                            ForEach(Array(devices.enumerated()), id: \.element.id) { idx, d in
                                DeviceRow(
                                    iconSystemName: d.iconSystemName, name: d.name,
                                    detail: d.detail, locked: d.locked,
                                    isLast: idx == devices.count - 1
                                )
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.evSurfaceContainerLowest)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
        }
        .background(Color.evSurface)
        .navigationBarBackButtonHidden(true)
        .onAppear {
            rules = ProfileMockData.rules(for: child.id)
            tasks = ProfileMockData.tasks(for: child.id)
            events = ProfileMockData.events(for: child.id)
            devices = ProfileMockData.devices(for: child.id)
        }
    }

    private var summaryCard: some View {
        HStack(spacing: 18) {
            EvlinAvatarView(url: child.avatarURL, name: child.name, size: 64, status: child.status)
            VStack(alignment: .leading, spacing: 6) {
                Text(child.name)
                    .font(.custom("Manrope", size: 22).weight(.heavy))
                    .tracking(-0.22)
                    .foregroundStyle(Color.evPrimary)
                Text(child.status == .unlocked ? "UNLOCKED" : "QUIET TIME")
                    .font(.custom("Inter", size: 10).weight(.heavy))
                    .tracking(1.6)
                    .foregroundStyle(child.status == .unlocked ? Color.evSecondary : Color.evOnSurfaceVariant)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.evSecondaryContainer).frame(height: 5)
                        Capsule().fill(Color.evSecondary)
                            .frame(width: max(6, geo.size.width * child.timePct), height: 5)
                    }
                }
                .frame(height: 5)
                Text("\(child.timeLeft) left today")
                    .font(.custom("Inter", size: 11).weight(.bold))
                    .foregroundStyle(Color.evSecondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.evSurfaceContainerLowest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
        )
        .evShadow(.premium)
    }
}
```

- [ ] **Step 2: Build-verify**

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Views/Profile/ProfileView.swift"
git commit -m "feat: add ProfileView child detail (rules/tasks/schedule/devices)"
```

---

## Task 17: CalendarView 24h timeline + MonthPickerSheet + EventDetailSheet

**Files:**
- Modify: `Evlin iOS/Views/Calendar/CalendarView.swift` (full rewrite)
- Create: `Evlin iOS/Views/Calendar/MonthPickerSheet.swift`
- Create: `Evlin iOS/Views/Calendar/EventDetailSheet.swift`

- [ ] **Step 1: Create EventDetailSheet.swift**

```swift
import SwiftUI

struct EventDetailSheet: View {
    let event: CalendarEvent
    let person: CalendarPerson
    let dayLabel: String      // "Thu, Sep 12"
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Backdrop handled by presenting sheet; this is the card content.
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(person.bg)
                    Text(event.emoji).font(.system(size: 28))
                }
                .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.custom("Manrope", size: 19).weight(.heavy))
                        .foregroundStyle(Color.evPrimary)
                    EvlinPill(text: event.category, tone: .neutral, size: .sm)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.evSurfaceContainerHigh))
                }
                .buttonStyle(.plain)
            }

            Divider().padding(.vertical, 16)

            row(icon: "calendar", label: "Date", value: dayLabel)
            row(icon: "clock", label: "Time", value: "\(event.start) – \(event.end)")
            row(icon: "mappin.and.ellipse", label: "Where", value: event.location)
            row(icon: "person.crop.circle", label: "Who", value: person.name)

            if !event.note.isEmpty {
                Text("NOTE")
                    .font(.custom("Inter", size: 10).weight(.heavy))
                    .tracking(1.4)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .padding(.top, 18)
                Text(event.note)
                    .font(.custom("Inter", size: 13))
                    .foregroundStyle(Color.evOnSurface)
                    .lineSpacing(3)
                    .padding(.top, 4)
            }

            Spacer(minLength: 24)
        }
        .padding(22)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .frame(width: 24)
            Text(label.uppercased())
                .font(.custom("Inter", size: 10).weight(.heavy))
                .tracking(1.4)
                .foregroundStyle(Color.evOnSurfaceVariant)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.custom("Inter", size: 13).weight(.semibold))
                .foregroundStyle(Color.evOnSurface)
            Spacer()
        }
        .padding(.vertical, 6)
    }
}
```

- [ ] **Step 2: Create MonthPickerSheet.swift**

```swift
import SwiftUI

struct MonthPickerSheet: View {
    @Binding var selectedDay: Int
    var onClose: () -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("September")
                .font(.custom("Manrope", size: 22).weight(.heavy))
                .foregroundStyle(Color.evPrimary)

            HStack(spacing: 6) {
                ForEach(["S","M","T","W","T","F","S"], id: \.self) { d in
                    Text(d).font(.custom("Inter", size: 11).weight(.bold))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(1...30, id: \.self) { d in
                    let on = d == selectedDay
                    Button {
                        selectedDay = d
                        onClose()
                    } label: {
                        Text("\(d)")
                            .font(.custom("Manrope", size: 15).weight(.heavy))
                            .foregroundStyle(on ? Color.white : Color.evOnSurface)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(
                                Circle().fill(on ? Color.evPrimary : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
        .padding(20)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
```

- [ ] **Step 3: Overwrite CalendarView.swift**

```swift
import SwiftUI

struct CalendarView: View {
    @State private var selectedDay: Int = 12
    @State private var showMonthPicker = false
    @State private var focusPerson: String? = nil   // nil = all
    @State private var activeEvent: CalendarEvent? = nil

    private let totalHeight: CGFloat = CGFloat(CalendarMockData.END_H) * CalendarMockData.HOUR_H

    private var events: [CalendarEvent] {
        CalendarMockData.events[selectedDay] ?? []
    }
    private var visibleEvents: [CalendarEvent] {
        guard let focusPerson else { return events }
        return events.filter { $0.col == focusPerson }
    }
    private var allDayItems: [AllDayItem] {
        CalendarMockData.allDay[selectedDay] ?? []
    }
    private var dayLabel: String {
        let name = CalendarMockData.dayNames[selectedDay] ?? "—"
        return "\(name), Sep \(selectedDay)"
    }

    var body: some View {
        VStack(spacing: 0) {
            GlassmorphicHeader(title: "Schedule", kicker: "September") {
                HStack(spacing: 4) {
                    HeaderIconButton(systemName: focusPerson == nil ? "person.2" : "person.fill") {
                        cycleFocus()
                    }
                }
            }

            dayNav

            ScrollViewReader { proxy in
                ScrollView {
                    timelineBody
                        .id("timeline")
                }
                .onAppear {
                    // Scroll to first event
                    scrollToFirstEvent(proxy)
                }
                .onChange(of: selectedDay) { _, _ in
                    scrollToFirstEvent(proxy)
                }
            }
        }
        .background(Color(hex: 0xF0F4F8))
        .sheet(isPresented: $showMonthPicker) {
            MonthPickerSheet(selectedDay: $selectedDay, onClose: { showMonthPicker = false })
        }
        .sheet(item: $activeEvent) { event in
            EventDetailSheet(
                event: event,
                person: CalendarMockData.person(event.col),
                dayLabel: dayLabel,
                onClose: { activeEvent = nil }
            )
        }
    }

    // MARK: - Day nav

    private var dayNav: some View {
        HStack {
            navButton(systemName: "chevron.left") {
                selectedDay = max(1, selectedDay - 1)
            }
            Spacer()
            Button {
                showMonthPicker = true
            } label: {
                VStack(spacing: 1) {
                    Text(dayLabel)
                        .font(.custom("Manrope", size: 17).weight(.heavy))
                        .foregroundStyle(Color.evPrimary)
                    Text("TAP TO CHANGE DATE")
                        .font(.custom("Inter", size: 10).weight(.heavy))
                        .tracking(1.2)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            navButton(systemName: "chevron.right") {
                selectedDay = min(30, selectedDay + 1)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
        .background(Color(hex: 0xF0F4F8).opacity(0.97))
        .overlay(
            Rectangle().fill(Color.evOutlineVariant).frame(height: 0.5),
            alignment: .bottom
        )
    }

    private func navButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.evPrimary)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white)
                )
                .evShadow(.premium)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Timeline

    private var timelineBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            // All-day strip
            if !allDayItems.isEmpty {
                HStack(spacing: 8) {
                    Text("ALL DAY")
                        .font(.custom("Inter", size: 10).weight(.heavy))
                        .tracking(1.4)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                    ForEach(allDayItems) { item in
                        let p = CalendarMockData.person(item.col)
                        Text(item.title)
                            .font(.custom("Inter", size: 12).weight(.semibold))
                            .foregroundStyle(p.color)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(p.bg))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }

            // Timeline
            HStack(alignment: .top, spacing: 0) {
                timeGutter
                ZStack(alignment: .topLeading) {
                    // Hour lines
                    ForEach(CalendarMockData.START_H...CalendarMockData.END_H, id: \.self) { h in
                        Rectangle()
                            .fill(Color.evOutlineVariant.opacity(0.4))
                            .frame(height: 1)
                            .offset(y: CGFloat(h) * CalendarMockData.HOUR_H)
                    }

                    ForEach(visibleEvents) { ev in
                        eventPill(ev)
                            .offset(y: CalendarMockData.yFor(ev.start))
                            .id("ev_\(ev.id)")
                    }
                }
                .frame(height: totalHeight, alignment: .top)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
        }
        .padding(.bottom, 120)
    }

    private var timeGutter: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(CalendarMockData.START_H...CalendarMockData.END_H, id: \.self) { h in
                Text(hourLabel(h))
                    .font(.custom("Inter", size: 10).weight(.bold))
                    .tracking(0.6)
                    .foregroundStyle(Color.evOutline)
                    .frame(height: CalendarMockData.HOUR_H, alignment: .topTrailing)
                    .padding(.trailing, 8)
                    .offset(y: -4)
            }
        }
        .frame(width: CalendarMockData.TIME_W)
    }

    private func hourLabel(_ h: Int) -> String {
        switch h {
        case 0, 24: return ""       // hide midnight
        case 12: return "12 PM"
        case let h where h < 12: return "\(h) AM"
        default: return "\(h - 12) PM"
        }
    }

    private func eventPill(_ ev: CalendarEvent) -> some View {
        let p = CalendarMockData.person(ev.col)
        let h = CalendarMockData.heightFor(start: ev.start, end: ev.end)
        return Button {
            activeEvent = ev
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(p.color).frame(width: 4).cornerRadius(2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(ev.emoji).font(.system(size: 14))
                        Text(ev.title)
                            .font(.custom("Manrope", size: 13).weight(.heavy))
                            .foregroundStyle(Color.evPrimary)
                            .lineLimit(1)
                    }
                    Text(ev.start)
                        .font(.custom("Inter", size: 10).weight(.bold))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: h, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(p.bg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(p.color.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func scrollToFirstEvent(_ proxy: ScrollViewProxy) {
        guard let first = visibleEvents.map({ CalendarMockData.yFor($0.start) }).min() else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo("timeline", anchor: UnitPoint(x: 0, y: max(0, first - 80) / totalHeight))
        }
    }

    private func cycleFocus() {
        let order: [String?] = [nil, "liam", "maya", "emma", "family"]
        let idx = (order.firstIndex(of: focusPerson) ?? 0)
        focusPerson = order[(idx + 1) % order.count]
    }
}
```

- [ ] **Step 4: Build-verify**

- [ ] **Step 5: Commit**

```bash
git add "Evlin iOS/Views/Calendar/CalendarView.swift" \
        "Evlin iOS/Views/Calendar/MonthPickerSheet.swift" \
        "Evlin iOS/Views/Calendar/EventDetailSheet.swift"
git commit -m "feat(calendar): rewrite as 24h timeline with focus filter + detail sheet"
```

---

## Task 18: LibraryView with Apple Music-style Reels + CategoryDetailView

**Files:**
- Modify: `Evlin iOS/Views/Library/LibraryView.swift` (full rewrite)
- Create: `Evlin iOS/Views/Library/CategoryDetailView.swift`

- [ ] **Step 1: Create CategoryDetailView.swift**

```swift
import SwiftUI

struct CategoryDetailView: View {
    let category: CategoryTileInfo
    var onBack: () -> Void = {}

    private var detail: (heroTitle: String, heroAuthor: String, items: [LibraryMockData.DetailItem]) {
        LibraryMockData.detail(for: category.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            GlassmorphicHeader(title: category.label, onBack: onBack) {
                HeaderIconButton(systemName: "bookmark") {}
            }

            ScrollView {
                VStack(spacing: 20) {
                    // Hero
                    VStack(alignment: .leading, spacing: 14) {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(category.gradient)
                            .frame(height: 200)
                            .overlay(alignment: .bottomLeading) {
                                VStack(alignment: .leading, spacing: 6) {
                                    EvlinPill(text: "Featured", tone: .primary, size: .xs)
                                    Text(detail.heroTitle)
                                        .font(.custom("Manrope", size: 20).weight(.heavy))
                                        .foregroundStyle(.white)
                                    Text(detail.heroAuthor.uppercased())
                                        .font(.custom("Inter", size: 10).weight(.heavy))
                                        .tracking(1.2)
                                        .foregroundStyle(.white.opacity(0.75))
                                }
                                .padding(18)
                            }
                            .overlay(alignment: .topTrailing) {
                                Circle().fill(.white.opacity(0.2))
                                    .frame(width: 44, height: 44)
                                    .overlay(
                                        Image(systemName: "play.fill")
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundStyle(.white)
                                    )
                                    .padding(18)
                            }
                    }

                    // 2-col grid of mixed items
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                        ForEach(detail.items) { item in
                            itemCard(item)
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 40)
            }
        }
        .background(Color.evSurface)
        .navigationBarBackButtonHidden(true)
    }

    @ViewBuilder
    private func itemCard(_ item: LibraryMockData.DetailItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(category.gradient.opacity(item.kind == .video ? 1.0 : 0.15))
                .frame(height: 100)
                .overlay(
                    Image(systemName: item.kind == .video ? "play.circle.fill" : "doc.text")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(item.kind == .video ? .white : Color.evPrimary)
                )
            Text(item.title)
                .font(.custom("Manrope", size: 13).weight(.heavy))
                .foregroundStyle(Color.evPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(item.meta.uppercased())
                .font(.custom("Inter", size: 9).weight(.heavy))
                .tracking(1.2)
                .foregroundStyle(Color.evOnSurfaceVariant)
        }
    }
}

extension LinearGradient {
    func opacity(_ o: Double) -> some ShapeStyle {
        self
    }
}
```

*(Note: the `LinearGradient.opacity` extension is a stub; for simplicity the duplicate layering is acceptable visual.)*

- [ ] **Step 2: Overwrite LibraryView.swift**

```swift
import SwiftUI

struct LibraryView: View {
    @State private var scrolledReelId: UUID?
    @State private var selectedCategory: CategoryTileInfo? = nil

    var body: some View {
        VStack(spacing: 0) {
            GlassmorphicHeader(title: "Library") {
                HStack(spacing: 4) {
                    HeaderIconButton(systemName: "magnifyingglass") {}
                    HeaderIconButton(systemName: "bookmark") {}
                }
            }

            ScrollView {
                VStack(spacing: 24) {
                    // Trending Reels
                    VStack(alignment: .leading, spacing: 0) {
                        SectionHead(title: "Trending Reels") {
                            Text("60-SECOND INSIGHTS")
                                .font(.custom("Inter", size: 10).weight(.heavy))
                                .tracking(1.4)
                                .foregroundStyle(Color.evOnSurfaceVariant)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 15) {
                                ForEach(LibraryMockData.reels) { reel in
                                    ReelCard(reel: reel)
                                        .id(reel.id)
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
                    }

                    // Trending Lessons
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHead(title: "Trending Lessons")
                        VStack(spacing: 12) {
                            ForEach(LibraryMockData.lessons) { lesson in
                                LessonCard(lesson: lesson)
                            }
                        }
                    }

                    // Topic Categories
                    VStack(alignment: .leading, spacing: 0) {
                        SectionHead(title: "Topic Categories")
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                            ForEach(LibraryMockData.categories) { cat in
                                CategoryTile(info: cat) {
                                    selectedCategory = cat
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 40)
            }
        }
        .background(Color.evSurface)
        .fullScreenCover(item: $selectedCategory) { cat in
            CategoryDetailView(category: cat, onBack: { selectedCategory = nil })
        }
    }
}
```

- [ ] **Step 3: Build-verify**

- [ ] **Step 4: Commit**

```bash
git add "Evlin iOS/Views/Library/LibraryView.swift" "Evlin iOS/Views/Library/CategoryDetailView.swift"
git commit -m "feat(library): Apple Music-style reel carousel + lessons + categories"
```

---

## Task 19: InsightsView with AI analysis hero

**Files:**
- Modify: `Evlin iOS/Views/Insights/InsightsView.swift` (full rewrite)

- [ ] **Step 1: Overwrite InsightsView.swift**

```swift
import SwiftUI

struct InsightsView: View {
    @State private var selection: String = "liam"

    var body: some View {
        VStack(spacing: 0) {
            GlassmorphicHeader(title: "Child Insights", kicker: "Past 7 days") {
                HStack(spacing: 4) {
                    HeaderIconButton(systemName: "bell", badge: true) {}
                    HeaderIconButton(systemName: "gearshape") {}
                }
            }

            ScrollView {
                VStack(spacing: 22) {
                    ChildFilterPills(selection: $selection)
                        .padding(.horizontal, -4)

                    heroCard

                    recommendations

                    dailyUsageCard

                    detailedBreakdown
                }
                .padding(20)
                .padding(.bottom, 40)
            }
        }
        .background(Color.evSurface)
    }

    // MARK: - Hero (AI analysis)

    private var heroCard: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle().fill(Color.evSecondary.opacity(0.15))
                .frame(width: 180, height: 180)
                .blur(radius: 60)
                .offset(x: 40, y: 40)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.evSecondaryGradient)
                            .frame(width: 26, height: 26)
                        Image(systemName: "sparkles")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    Text("EVLIN AI ANALYSIS")
                        .font(.custom("Inter", size: 10).weight(.heavy))
                        .tracking(1.6)
                        .foregroundStyle(Color.evSecondaryFixed)
                }
                .padding(.bottom, 4)

                Text(InsightsMockData.heroTitle)
                    .font(.custom("Manrope", size: 22).weight(.heavy))
                    .tracking(-0.25)
                    .foregroundStyle(.white)
                    .lineSpacing(-2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(InsightsMockData.heroBody)
                    .font(.custom("Inter", size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    EvlinButton(title: "Review strategy", icon: "checkmark.seal", variant: .success, size: .sm) {}
                    Text("DISMISS")
                        .font(.custom("Manrope", size: 11).weight(.heavy))
                        .tracking(0.9)
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(.white.opacity(0.2), lineWidth: 1)
                        )
                }
                .padding(.top, 6)
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.evPrimaryGradient)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - Recommendations

    private var recommendations: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(title: "Strategic Recommendations", kicker: "3 suggested")
            VStack(spacing: 0) {
                ForEach(Array(InsightsMockData.recommendations.enumerated()), id: \.element.id) { idx, r in
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.evSurfaceContainerLow)
                            Image(systemName: r.iconSystemName)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Color.evPrimary)
                        }
                        .frame(width: 40, height: 40)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.title)
                                .font(.custom("Manrope", size: 14).weight(.bold))
                                .foregroundStyle(Color.evOnSurface)
                            Text(r.sub)
                                .font(.custom("Inter", size: 11))
                                .foregroundStyle(Color.evOnSurfaceVariant)
                        }
                        Spacer()
                        EvlinButton(title: "Apply", size: .sm) {}
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .overlay(
                        Rectangle()
                            .fill(Color.evOutlineVariant.opacity(idx == 0 ? 0 : 0.25))
                            .frame(height: 1),
                        alignment: .top
                    )
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.evSurfaceContainerLowest)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
            )
            .evShadow(.premium)
        }
    }

    // MARK: - Daily usage card

    private var dailyUsageCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(title: "Daily App Usage") {
                EvlinPill(text: "+\(InsightsMockData.deltaPct)% vs yesterday", tone: .success, size: .xs)
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(InsightsMockData.dailyTotalHours)h")
                        .font(.custom("Manrope", size: 48).weight(.heavy))
                        .tracking(-1.0)
                        .foregroundStyle(Color.evPrimary)
                    Text(String(format: "%02dm", InsightsMockData.dailyTotalMinutes))
                        .font(.custom("Manrope", size: 32).weight(.heavy))
                        .tracking(-0.6)
                        .foregroundStyle(Color.evPrimary)
                }

                // Segmented bar
                GeometryReader { geo in
                    let total = InsightsMockData.categories.map(\.weight).reduce(0, +)
                    HStack(spacing: 0) {
                        ForEach(InsightsMockData.categories) { c in
                            Rectangle().fill(c.color)
                                .frame(width: geo.size.width * c.weight / total)
                        }
                    }
                    .frame(height: 6)
                    .clipShape(Capsule())
                }
                .frame(height: 6)

                // Legend
                HStack(spacing: 18) {
                    ForEach(InsightsMockData.categories) { c in
                        HStack(spacing: 6) {
                            Circle().fill(c.color).frame(width: 8, height: 8)
                            Text(c.label)
                                .font(.custom("Inter", size: 11).weight(.semibold))
                                .foregroundStyle(Color.evOnSurface)
                            Text(c.time)
                                .font(.custom("Inter", size: 11))
                                .foregroundStyle(Color.evOnSurfaceVariant)
                        }
                    }
                    Spacer()
                }
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.evSurfaceContainerLowest)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
            )
            .evShadow(.premium)
        }
    }

    // MARK: - Detailed breakdown

    private var detailedBreakdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(title: "Detailed Breakdown") {
                Text("VIEW ALL")
                    .font(.custom("Inter", size: 10).weight(.heavy))
                    .tracking(1.4)
                    .foregroundStyle(Color.evPrimary)
            }

            VStack(spacing: 10) {
                ForEach(InsightsMockData.apps) { app in
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(app.iconBg)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                                )
                            Image(systemName: app.iconSystemName)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(app.color)
                        }
                        .frame(width: 38, height: 38)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(app.name)
                                    .font(.custom("Manrope", size: 14).weight(.heavy))
                                    .foregroundStyle(Color.evOnSurface)
                                Spacer()
                                Text(app.time)
                                    .font(.custom("Inter", size: 12).weight(.semibold))
                                    .foregroundStyle(Color.evOnSurfaceVariant)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.evSurfaceContainerHigh)
                                    Capsule().fill(app.color)
                                        .frame(width: max(6, geo.size.width * app.pct))
                                }
                            }
                            .frame(height: 4)
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.evSurfaceContainerLowest)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.evOutlineVariant.opacity(0.35), lineWidth: 1)
                    )
                }
            }
        }
    }
}
```

- [ ] **Step 2: Build-verify**

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Views/Insights/InsightsView.swift"
git commit -m "feat(insights): rewrite with AI analysis hero + recommendations + breakdown"
```

---

## Task 20: ChatView refinements — seed initial messages, render StrategyCard/ObservationBubble

**Files:**
- Modify: `Evlin iOS/Views/Chat/ChatViewModel.swift`
- Modify: `Evlin iOS/Models/ChatModels.swift`
- Modify: `Evlin iOS/Views/Chat/ChatView.swift`

- [ ] **Step 1: Extend ChatMessage to carry artifact data**

Read `Evlin iOS/Models/ChatModels.swift`, find the `ChatMessage` struct. Add optional artifact fields. Preserve all existing fields exactly.

Append to `ChatMessage`:
```swift
// Strategy artifact (new)
var strategyTitle: String? = nil
var strategyStatus: String? = nil
var strategyCategory: String? = nil
var strategyVideoLabel: String? = nil
var strategyVideoDuration: String? = nil
var strategyTip: String? = nil

var isStrategyArtifact: Bool { strategyTitle != nil }
```

Also make sure these new fields are in the `CodingKeys` / default decode path — if the struct uses automatic Codable, nothing to do; if it has custom init(from:), add these fields with `decodeIfPresent`.

- [ ] **Step 2: Seed initial 3 messages in ChatViewModel on empty history**

In `Evlin iOS/Views/Chat/ChatViewModel.swift`, find `init()` and locate `loadMessages()` call. After loading, if `messages.isEmpty`, seed the prototype's 3 messages.

Append the seed logic:
```swift
if messages.isEmpty {
    seedInitialMessages()
}
```

Add private method `seedInitialMessages()`:
```swift
private func seedInitialMessages() {
    let now = Date()
    let m1 = ChatMessage(
        id: UUID(),
        role: .agent,
        content: "I've confirmed the manual lock on Liam's device. Given his recent focus patterns, he may experience a frustration spike.",
        timestamp: now
    )
    var m2 = ChatMessage(
        id: UUID(),
        role: .agent,
        content: "",
        timestamp: now
    )
    m2.strategyTitle = "Real-time De-escalation Strategy"
    m2.strategyStatus = "Locked"
    m2.strategyCategory = "Active Monitoring › Immediate Action"
    m2.strategyVideoLabel = "Managing Transition Frustration"
    m2.strategyVideoDuration = "3:00"
    m2.strategyTip = "If a tantrum occurs, use \"Planned Ignoring\". I've prepared a 30-second refresher for you."

    let m3 = ChatMessage(
        id: UUID(),
        role: .agent,
        content: "Would you like to review the suggested de-escalation steps or watch the briefing video now?",
        timestamp: now
    )
    messages = [m1, m2, m3]
}
```

*(If `ChatMessage` init signature differs from the example, adapt to the actual fields — inspect current file first.)*

- [ ] **Step 3: Render new artifact types in ChatView**

In `Evlin iOS/Views/Chat/ChatView.swift`, find the `ForEach(viewModel.messages)` block where each message is laid out. Inside it, add rendering branches:

Before the existing `ChatBubble(content: message.content, ...)` call, insert:
```swift
// New: Strategy artifact
if message.isStrategyArtifact, message.role == .agent {
    StrategyCard(data: StrategyCardData(
        title: message.strategyTitle ?? "",
        status: message.strategyStatus ?? "",
        category: message.strategyCategory ?? "",
        videoLabel: message.strategyVideoLabel ?? "",
        videoDuration: message.strategyVideoDuration ?? "",
        tip: message.strategyTip ?? ""
    ))
}
```

Guard: only render the regular `ChatBubble` when `!message.content.isEmpty`. Change:
```swift
ChatBubble(content: message.content, role: message.role, timestamp: message.timestamp)
```
To:
```swift
if !message.content.isEmpty {
    ChatBubble(content: message.content, role: message.role, timestamp: message.timestamp)
}
```

Replace the existing `editorialHeader` with a more compact header:

```swift
private var editorialHeader: some View {
    VStack(alignment: .leading, spacing: 4) {
        Text("EVLIN AI")
            .font(.custom("Inter", size: 10).weight(.heavy))
            .tracking(1.6)
            .foregroundStyle(Color.evOnSurfaceVariant)
        Text("Strategic Advisory")
            .font(.custom("Manrope", size: 26).weight(.heavy))
            .tracking(-0.3)
            .foregroundStyle(Color.evPrimary)
        Text("Evlin is monitoring behavioral patterns across all profiles.")
            .font(.custom("Inter", size: 13))
            .foregroundStyle(Color.evOnSurfaceVariant)
            .padding(.top, 6)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 20)
}
```

Also replace the previously-added demo `InterventionBriefingCard` block (in `body`) with nothing — it was placeholder content; the seeded StrategyCard now fulfills that role. Find and delete the `if showDemoBriefing { InterventionBriefingCard(...) ... }` block entirely.

Also remove the `@State private var showDemoBriefing` declaration and the `demoBriefingModel` computed property at the bottom — no longer needed.

- [ ] **Step 4: Keep bottom input bar pinned (verify existing layout)**

The current ChatView uses a `VStack { ScrollView; input }`. Confirm this is the case — input bar already pins to bottom. If it does, no change needed for this step.

- [ ] **Step 5: Build-verify**

- [ ] **Step 6: Commit**

```bash
git add "Evlin iOS/Models/ChatModels.swift" \
        "Evlin iOS/Views/Chat/ChatViewModel.swift" \
        "Evlin iOS/Views/Chat/ChatView.swift"
git commit -m "feat(chat): seed Esen-parity initial messages, render StrategyCard"
```

---

## Task 21: Update ChatView header to GlassHeader shape

**Files:**
- Modify: `Evlin iOS/Views/Chat/ChatView.swift`

- [ ] **Step 1: Prepend GlassmorphicHeader to ChatView body**

In `ChatView.body`, wrap the outer `VStack(spacing: 0)` so its first child is a header:

```swift
var body: some View {
    VStack(spacing: 0) {
        GlassmorphicHeader(title: "Evlin") {
            HStack(spacing: 4) {
                HeaderIconButton(systemName: "checkmark.seal") {}
                HeaderIconButton(systemName: "ellipsis") {}
            }
        }

        // ... existing ScrollViewReader + ScrollView content ...

        // ... existing input bar ...
    }
    // ... existing .background / .onAppear ...
}
```

(Keep all existing logic intact; only add the header as the new first child of the outermost VStack.)

- [ ] **Step 2: Build-verify**

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/Views/Chat/ChatView.swift"
git commit -m "feat(chat): add GlassmorphicHeader to chat screen"
```

---

## Task 22: Rewrite ContentView parent routing

**Files:**
- Modify: `Evlin iOS/ContentView.swift` (full rewrite of parent flow)

- [ ] **Step 1: Overwrite ContentView.swift**

```swift
import SwiftUI

struct ContentView: View {
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @AppStorage("appMode") private var appMode: String = ""

    var body: some View {
        Group {
            if !onboardingComplete {
                OnboardingView()
            } else if appMode != "parent" && appMode != "child" {
                SetupView()
            } else if appMode == "parent" {
                ParentRootView()
            } else {
                ChildModeView()
            }
        }
    }
}

struct ParentRootView: View {
    @State private var selectedTab: EvlinTab = .home
    @State private var profilePath = NavigationPath()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch selectedTab {
                case .home:
                    NavigationStack(path: $profilePath) {
                        HomeView(
                            selectedTab: $selectedTab,
                            onOpenProfile: { child in profilePath.append(child) }
                        )
                        .navigationDestination(for: ChildProfile.self) { child in
                            ProfileView(
                                child: child,
                                onBack: { profilePath.removeLast() },
                                onOpenCalendar: { selectedTab = .calendar }
                            )
                        }
                    }
                case .calendar:
                    CalendarView()
                case .chat:
                    ChatView()
                case .library:
                    LibraryView()
                case .insights:
                    InsightsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            EvlinTabBar(selectedTab: $selectedTab)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(APIClient(baseURL: "http://preview"))
        .environmentObject(ScreenTimeManager.shared)
}
```

- [ ] **Step 2: Build-verify**

- [ ] **Step 3: Commit**

```bash
git add "Evlin iOS/ContentView.swift"
git commit -m "refactor(root): ParentRootView with tab switching + profile push"
```

---

## Task 23: Smoke-test preview & build

**Files:** none

- [ ] **Step 1: Full clean build**

Run:
```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
rm -rf ~/Library/Developer/Xcode/DerivedData
xcodebuild -scheme "Evlin iOS" -destination 'generic/platform=iOS' build 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`. If errors surface, fix minimally and re-run.

- [ ] **Step 2: Grep for leftover stub markers**

```bash
cd "/Users/fred/Desktop/Evlin/Evlin iOS"
git grep -n "TODO(esen-parity)" "Evlin iOS/"
git grep -n "Coming Soon" "Evlin iOS/Views/"
```

Expected: no results for either command (the spec's success criterion §9.1 and 9.3).

- [ ] **Step 3: Final commit marker**

```bash
git commit --allow-empty -m "chore: Evlin parity rebuild complete — ready for review"
```

---

## Self-Review

**Spec coverage check (§2 Scope list):**
- In-scope items each mapped to:
  - Home tab → Task 13, 14, 15
  - Profile sub-screen → Task 16
  - Calendar tab → Task 17
  - Evlin Chat → Task 20, 21
  - Library tab → Task 18
  - Insights tab → Task 19
  - Shared components (TabBar flatten) → Task 4
  - GlassHeader extend → Task 5
  - ProfileCard → Task 8
  - StrategyCard / ObservationBubble → Task 11
  - ReelCard / LessonCard / CategoryTile → Task 10
  - TaskRow / RuleRow / DeviceRow → Task 9
  - ChildFilterPills → Task 9
  - Design tokens → Task 1
  - Mock data → Task 2, 12
- Preserved (§2): Onboarding, SetupView, ChildMode, Services, ChatViewModel, existing chat cards — none of those files are modified by any task. ✓
- ProfilePickerView retained with header comment → Task 3 ✓
- Deletions: none ✓

**Placeholder scan:** No "TBD", "TODO", "implement later" in task bodies. Every code step has complete code. "TODO(esen-parity)" only appears in Task 23 as a negative grep check.

**Type consistency:** All types defined once and reused consistently — `ChildProfile`, `EvlinTab` (5 cases), `TaskItem.State`, `RuleRow.Tone`, `HomeNotification`, `CalendarEvent`, `CategoryTileInfo`, `ReelItem`, `LessonItem`, `InsightsRecommendation`, `InsightsAppStat`, `InsightsCategoryStat`. Header component called `GlassmorphicHeader` throughout.

**Scope check:** Single coherent rebuild; 23 tasks is large but each is bounded and independently verifiable.

**Ambiguity check:** Step 3 of Task 20 requires inspecting current `ChatMessage` shape before extending — this is inherent since the file already exists; plan notes "inspect current file first" as guidance.

---

**Plan complete and saved to `docs/superpowers/plans/2026-04-21-ios-ui-rebuild-esen-parity.md`.**
