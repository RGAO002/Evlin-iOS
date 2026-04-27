import SwiftUI

struct ProfileView: View {
    let child: ChildProfile
    var initialTaskId: Int? = nil
    var onBack: () -> Void = {}
    var onOpenCalendar: () -> Void = {}

    @State private var rules: [RuleItem] = []
    @State private var tasks: [TaskItem] = []
    @State private var events: [ProfileEvent] = []
    @State private var devices: [DeviceItem] = []
    @State private var activeTask: TaskItem? = nil
    @State private var showProfileMenu = false
    @State private var showEditProfile = false
    @State private var showDeleteConfirm = false
    @State private var devicesExpanded = true
    @State private var rulesExpanded = true
    @State private var addMode: AddBottomMode? = nil

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
        VStack(spacing: 0) {
            GlassmorphicHeader(title: "\(child.name)'s Space", onBack: onBack) {
                Menu {
                    Button {
                        showEditProfile = true
                    } label: {
                        Label("Edit Profile", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete Profile", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.evOnSurface)
                        .frame(width: 40, height: 40)
                }
            }

            ScrollView {
                VStack(spacing: 26) {
                    // Summary card
                    summaryCard
                    // Active Rules (collapsible per HTML 1086-1121)
                    VStack(spacing: 0) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                rulesExpanded.toggle()
                            }
                        } label: {
                            HStack {
                                Text("Active Rules")
                                    .font(.custom("Manrope", size: 16).weight(.heavy))
                                    .tracking(-0.16)
                                    .foregroundStyle(Color.evOnSurface)
                                EvlinPill(
                                    text: "\(rules.filter(\.on).count)/\(rules.count)",
                                    tone: .success, size: .xs
                                )
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.evOutline)
                                    .rotationEffect(.degrees(rulesExpanded ? 180 : 0))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }
                        .buttonStyle(.plain)

                        if rulesExpanded {
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

                    // Tasks
                    VStack(spacing: 0) {
                        SectionHead(title: "Current Tasks") {
                            Text("\(tasks.filter { $0.state == .done }.count)/\(tasks.count) done")
                                .font(.custom("Inter", size: 11).weight(.bold))
                                .tracking(1.2)
                                .textCase(.uppercase)
                                .foregroundStyle(Color.evOnSurfaceVariant)
                        }
                        VStack(spacing: 10) {
                            ForEach(tasks) { t in
                                TaskRow(
                                    task: t,
                                    onApprove: {
                                        if let i = tasks.firstIndex(where: { $0.id == t.id }) {
                                            tasks[i].state = (t.state == .bypass) ? .bypassed : .done
                                        }
                                    },
                                    onRedo: {
                                        if let i = tasks.firstIndex(where: { $0.id == t.id }) {
                                            tasks[i].state = .pending
                                        }
                                    },
                                    onOpen: { activeTask = t }
                                )
                            }
                        }
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

                    // Devices (collapsible per HTML 1064-1085)
                    VStack(spacing: 0) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                devicesExpanded.toggle()
                            }
                        } label: {
                            HStack {
                                Text("Enrolled Devices")
                                    .font(.custom("Manrope", size: 16).weight(.heavy))
                                    .tracking(-0.16)
                                    .foregroundStyle(Color.evOnSurface)
                                EvlinPill(
                                    text: "\(devices.count) \(child.status == .unlocked ? "active" : "locked")",
                                    tone: child.status == .unlocked ? .success : .danger,
                                    size: .xs
                                )
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.evOutline)
                                    .rotationEffect(.degrees(devicesExpanded ? 180 : 0))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }
                        .buttonStyle(.plain)

                        if devicesExpanded {
                            VStack(spacing: 0) {
                                ForEach(Array(devices.enumerated()), id: \.element.id) { idx, d in
                                    DeviceRow(
                                        iconSystemName: d.iconSystemName, name: d.name,
                                        detail: d.detail, locked: d.locked,
                                        isLast: idx == devices.count - 1
                                    )
                                }
                            }
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
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
        }

            // Floating + FAB (HTML 1124-1130)
            Button {
                addMode = .menu
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Color.evPrimary))
                    .shadow(color: Color.evPrimary.opacity(0.32), radius: 24, y: 8)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 20)
            .padding(.bottom, 24)
        }
        .background(Color.evSurfaceContainerLow)
        .navigationBarBackButtonHidden(true)
        .enableSwipeBack()
        .fullScreenCover(item: $activeTask) { task in
            NavigationStack {
                TaskDetailSheet(
                    task: task,
                    child: child,
                    onClose: { activeTask = nil },
                    onApprove: {
                        if let i = tasks.firstIndex(where: { $0.id == task.id }) {
                            tasks[i].state = (task.state == .bypass) ? .bypassed : .done
                        }
                        activeTask = nil
                    },
                    onRedo: {
                        if let i = tasks.firstIndex(where: { $0.id == task.id }) {
                            tasks[i].state = .pending
                        }
                        activeTask = nil
                    },
                    onEdit: {}    // wired in Phase 6
                )
            }
        }
        .alert("Delete \(child.name)?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                onBack()
            }
        } message: {
            Text("This will remove the profile and all associated data.")
        }
        .sheet(isPresented: $showEditProfile) {
            // Phase 4 stub: ChildEditSheet (HTML 307) full impl deferred to polish phase.
            NavigationStack {
                Text("Edit Profile (coming soon)")
                    .navigationTitle("Edit \(child.name)")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showEditProfile = false }
                        }
                    }
            }
        }
        .sheet(item: $addMode) { _ in
            AddBottomSheet(
                mode: $addMode,
                child: child,
                onCreateTask: { newTask in
                    tasks.append(newTask)
                    addMode = nil
                },
                onCreateRule: { newRule in
                    rules.append(newRule)
                    addMode = nil
                },
                onCreateCalendar: { _ in
                    addMode = nil  // Phase 8 will handle calendar event creation
                },
                onCreateDevice: { newDevice in
                    devices.append(newDevice)
                    addMode = nil
                }
            )
        }
        .onAppear {
            rules = ProfileMockData.rules(for: child.id)
            tasks = ProfileMockData.tasks(for: child.id)
            events = ProfileMockData.events(for: child.id)
            devices = ProfileMockData.devices(for: child.id)
            if let id = initialTaskId, let task = tasks.first(where: { $0.id == id }) {
                activeTask = task
            }
        }
    }

    private var summaryCard: some View {
        VStack(spacing: 16) {
            HStack(spacing: 18) {
                EvlinAvatarView(url: child.avatarURL, name: child.name, size: 64, status: child.status)
                VStack(alignment: .leading, spacing: 6) {
                    Text(child.name)
                        .font(.custom("Manrope", size: 22).weight(.heavy))
                        .tracking(-0.22)
                        .foregroundStyle(Color.evPrimary)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.evSecondaryContainer).frame(height: 5)
                            Capsule().fill(Color.evSecondary)
                                .frame(width: max(6, geo.size.width * child.timePct), height: 5)
                        }
                    }
                    .frame(height: 5)
                    HStack(spacing: 4) {
                        Text(child.timeLeft)
                            .font(.custom("Inter", size: 11).weight(.heavy))
                            .foregroundStyle(Color.evSecondary)
                        Text("left today")
                            .font(.custom("Inter", size: 11).weight(.heavy))
                            .foregroundStyle(Color.evOnSurfaceVariant)
                    }
                }
            }

            // Lock/Unlock big button (HTML 1036-1056)
            Button {
                // Phase 4: visual only. Backend hookup is out of scope here.
                print("[Profile] Lock/Unlock tapped for \(child.id)")
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: child.status == .unlocked ? "lock" : "lock.open")
                        .font(.system(size: 18, weight: .semibold))
                    Text(child.status == .unlocked
                         ? "Lock \(child.name)'s devices"
                         : "Unlock \(child.name)'s devices")
                        .font(.custom("Manrope", size: 14).weight(.heavy))
                        .tracking(0.2)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(child.status == .unlocked ? Color.evSecondary : Color.evError)
                )
                .shadow(color: (child.status == .unlocked ? Color.evSecondary : Color.evError).opacity(0.32),
                        radius: 14, y: 4)
            }
            .buttonStyle(.plain)
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

#Preview("Liam") {
    NavigationStack {
        ProfileView(child: .liam)
    }
}

#Preview("Maya") {
    NavigationStack {
        ProfileView(child: .maya)
    }
}

#Preview("Emma (locked)") {
    NavigationStack {
        ProfileView(child: .emma)
    }
}
