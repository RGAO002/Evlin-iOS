import FamilyControls
import SwiftUI

struct BigKidHomeView: View {
    @Environment(BigKidState.self) private var state
    var onTaskTap: (BigKidTask) -> Void
    var onManageApps: (() -> Void)? = nil
    var onCommandDelivery: (() -> Void)? = nil

    // B3 production capture: tracks whether the measurement selection has been
    // saved. Initialized from EarnedTimeStore.shared at render time and updated
    // when the ScreenTimeCaptureView calls onDone so the card disappears without
    // requiring a full view rebuild.
    @State private var measurementSelectionCaptured: Bool =
        EarnedTimeStore.shared.hasMeasurableSelection

    private var doneCount: Int {
        state.tasks.filter { $0.status == .done || $0.bypass?.status == .approved }.count
    }
    private var allDone: Bool { state.allTasksDone }
    private var outOfTime: Bool { allDone && state.minutesLeft <= 0 }
    private var showTimeHero: Bool { allDone }
    private var displayChildName: String {
        BigKidDisplayName.resolve(
            server: state.childName,
            local: UserDefaults.standard.string(forKey: "evlin.childProfileName") ?? ""
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                greeting
                heroCard.padding(.bottom, 22)
                // B3: show the capture card until the all-category measurement
                // selection is present. Once saved, isEarnedTimeReady becomes
                // satisfiable (when a Locked-set id is also present) and the
                // earned-budget ladder arms on next foreground.
                if !measurementSelectionCaptured {
                    ScreenTimeCaptureView {
                        measurementSelectionCaptured = true
                    }
                    .padding(.bottom, 22)
                }
                if onManageApps != nil {
                    manageAppsCard.padding(.bottom, 22)
                }
                #if DEBUG
                if onCommandDelivery != nil {
                    commandDeliveryCard.padding(.bottom, 22)
                }
                #endif
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
        Text("Hi, \(displayChildName)")
            .font(.system(size: 22, weight: .heavy))
            .tracking(EvlinKidMetrics.Letter.mediumTitle)
            .foregroundStyle(EvlinKidColors.ink)
            .padding(.vertical, 8)
            .padding(.bottom, 10)
    }

    private var manageAppsCard: some View {
        Button {
            onManageApps?()
        } label: {
            EvKidCard(padding: 18) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14).fill(EvlinKidColors.green100)
                        Image(systemName: "lock.rectangle.stack.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(EvlinKidColors.green700)
                    }
                    .frame(width: 44, height: 44)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("PARENT")
                            .font(.system(size: 11, weight: .heavy))
                            .tracking(1)
                            .foregroundStyle(EvlinKidColors.green700)
                        Text("Parent controls")
                            .font(.system(size: 16, weight: .heavy))
                            .tracking(EvlinKidMetrics.Letter.body)
                            .foregroundStyle(EvlinKidColors.ink)
                        Text("Parent PIN required")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(EvlinKidColors.ink3)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(EvlinKidColors.ink3)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Manage locked apps")
    }

    #if DEBUG
    private var commandDeliveryCard: some View {
        Button {
            onCommandDelivery?()
        } label: {
            EvKidCard(padding: 18) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14).fill(Color.white)
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(EvlinKidColors.green700)
                    }
                    .frame(width: 44, height: 44)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("DEBUG")
                            .font(.system(size: 11, weight: .heavy))
                            .tracking(1)
                            .foregroundStyle(EvlinKidColors.green700)
                        Text("Command delivery")
                            .font(.system(size: 16, weight: .heavy))
                            .tracking(EvlinKidMetrics.Letter.body)
                            .foregroundStyle(EvlinKidColors.ink)
                        Text("APNs, poll, and ack diagnostics")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(EvlinKidColors.ink3)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(EvlinKidColors.ink3)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Command delivery diagnostics")
    }
    #endif

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
        // B11: countdown label uses the same 5-minute granularity as parent surfaces.
        let countdownLabel = EarnedDisplayFormatters.coarseCountdownLabel(remainingMinutes: state.minutesLeft)
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
                // B11: coarse primary label (honest framing for the child).
                Text(countdownLabel)
                    .font(.system(size: 22, weight: .heavy))
                    .tracking(-0.4)
                    .foregroundStyle(mode.fg)
                    .padding(.bottom, 4)
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
                startPoint: .topLeading, endPoint: .bottomTrailing
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

    /// Submitted, waiting for parent (not yet `.done`). Fills **after** done
    /// segments, still left-to-right — same as counting "available" slots.
    private var submittedAwaitingReviewCount: Int {
        state.tasks.filter { $0.status == .submitted }.count
    }

    private var questPips: some View {
        HStack(spacing: 5) {
            ForEach(0..<state.tasks.count, id: \.self) { index in
                Capsule()
                    .fill(questPipColor(at: index))
                    .frame(height: EvlinKidMetrics.Size.segPip)
            }
        }
        .padding(.horizontal, 4)
    }

    /// Left → right: `doneCount` deep green, then `submittedAwaitingReviewCount`
    /// light green, then neutral (todo / not yet submitted).
    private func questPipColor(at index: Int) -> Color {
        if index < doneCount { return EvlinKidColors.green500 }
        if index < doneCount + submittedAwaitingReviewCount { return EvlinKidColors.green300 }
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
            minutesLeft: 95, minutesMax: 120
        )))
}
#Preview("Out of time") {
    BigKidHomeView { _ in }
        .environment(BigKidState(snapshot: .fixture(
            tasks: [.fixture(status: .done)], minutesLeft: 0, minutesMax: 120
        )))
}
#endif
