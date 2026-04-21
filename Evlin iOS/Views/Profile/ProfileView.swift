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
                        SectionHead("Device Permissions")
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
