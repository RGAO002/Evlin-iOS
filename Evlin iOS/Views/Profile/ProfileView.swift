import SwiftUI

struct ProfileView: View {
    let child: ChildProfile
    var initialTaskId: Int? = nil
    var onBack: () -> Void = {}
    var onOpenCalendar: () -> Void = {}
    /// Called when the user opens a task. The parent stack should push a
    /// `.taskDetail` route — Task Detail is now a navigation push (right-
    /// to-left, edge-swipe back), no longer a fullScreenCover sheet.
    var onOpenTaskDetail: (TaskItem) -> Void = { _ in }
    /// Called when the user taps an enrolled device row. Same deal as
    /// `onOpenTaskDetail`: the parent stack pushes a `.deviceDetail`
    /// route so the per-device app-limits screen slides in from the
    /// right and supports edge-swipe back.
    var onOpenDevice: (DeviceItem) -> Void = { _ in }

    @State private var rules: [RuleItem] = []
    @State private var tasks: [TaskItem] = []
    @State private var events: [ProfileEvent] = []
    @State private var devices: [DeviceItem] = []
    @State private var editingRule: RuleItem? = nil
    @State private var showProfileMenu = false
    @State private var showEditProfile = false
    @State private var showDeleteConfirm = false
    @State private var devicesExpanded = true
    @State private var rulesExpanded = true
    @State private var addMode: AddBottomMode? = nil

    // Local mutable status so the Lock/Unlock button can flip the avatar
    // and pills without requiring a global mutation. See HTML 1029-1034.
    @State private var localStatus: ChildProfile.Status = .unlocked
    // Local mutable copy of the child's display fields so Edit Profile
    // can show changes within the session.
    @State private var localName: String = ""
    @State private var localAge: Int = 0
    @State private var localSubtitle: String = ""
    @State private var localAvatarURL: String? = nil

    private var displayChild: ChildProfile {
        ChildProfile(
            id: child.id,
            name: localName.isEmpty ? child.name : localName,
            age: localAge == 0 ? child.age : localAge,
            avatarURL: localAvatarURL ?? child.avatarURL,
            accentColor: child.accentColor,
            status: localStatus,
            timeLeft: child.timeLeft,
            timePct: child.timePct,
            subtitle: localSubtitle.isEmpty ? child.subtitle : localSubtitle
        )
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
        VStack(spacing: 0) {
            GlassmorphicHeader(title: "\(displayChild.name)'s Space", onBack: onBack) {
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
                    // Summary card with Lock/Unlock CTA
                    summaryCard

                    // Current Tasks (HTML 1058-1063)
                    VStack(spacing: 0) {
                        SectionHead(title: "Current Tasks") {
                            tasksDonePill
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
                                    onOpen: { onOpenTaskDetail(t) }
                                )
                            }
                        }
                    }

                    // NOTE: "Today's Schedule" section was removed because the
                    // latest design HTML (Evlin Parent Dashboard (1).html) no
                    // longer includes it on the kid profile screen. Keeping
                    // the implementation commented in case we want to bring
                    // it back. To restore, uncomment `todaysScheduleSection`
                    // (defined below) and add it here between Tasks and
                    // Devices.
                    //
                    // todaysScheduleSection

                    // Enrolled Devices (collapsible — HTML 1064-1085)
                    devicesSection

                    // Active Rules (collapsible) — moved to bottom per HTML 1086-1121
                    activeRulesSection
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
        // Task Detail is now a NavigationStack push handled by the parent
        // stack (see `appNavigationDestination`). Edit Task lives inside
        // TaskDetailView itself.
        //
        // Custom modal overlays — see EvlinSheetCard. We use these
        // instead of native `.sheet` because the system sheet inherits a
        // dark background under dark mode and this app explicitly stays
        // on the light palette.
        .overlay {
            EvlinSheetCardItem(item: $editingRule) { rule in
                EditRuleForm(
                    rule: rule,
                    onSave: { updated in
                        if let i = rules.firstIndex(where: { $0.id == updated.id }) {
                            rules[i] = updated
                        }
                        editingRule = nil
                    },
                    onDelete: {
                        rules.removeAll(where: { $0.id == rule.id })
                        editingRule = nil
                    },
                    onCancel: { editingRule = nil }
                )
            }
        }
        .alert("Delete \(displayChild.name)?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                onBack()
            }
        } message: {
            Text("This will remove the profile and all associated data.")
        }
        .fullScreenCover(isPresented: $showEditProfile) {
            ProfileEditSheet(
                name: $localName,
                age: $localAge,
                subtitle: $localSubtitle,
                avatarURL: $localAvatarURL,
                isNew: false,
                onClose: { showEditProfile = false },
                onSave: { showEditProfile = false }
            )
        }
        .overlay {
            EvlinSheetCardItem(item: $addMode) { _ in
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
                    onCreateCalendar: { event in
                        var todays = CalendarMockData.runtimeEventsByOffset[0] ?? []
                        todays.append(event)
                        CalendarMockData.runtimeEventsByOffset[0] = todays
                        addMode = nil
                    },
                    onCreateDevice: { newDevice in
                        devices.append(newDevice)
                        addMode = nil
                    }
                )
            }
        }
        .onAppear {
            rules = ProfileMockData.rules(for: child.id)
            tasks = ProfileMockData.tasks(for: child.id)
            events = ProfileMockData.events(for: child.id)
            devices = ProfileMockData.devices(for: child.id)
            // Initialise local mutables from the source profile.
            localStatus = child.status
            if localName.isEmpty { localName = child.name }
            if localAge == 0    { localAge = child.age }
            if localSubtitle.isEmpty { localSubtitle = child.subtitle }
            if localAvatarURL == nil { localAvatarURL = child.avatarURL }
            // Deep-link from notifications: if a taskId was supplied,
            // jump straight to its detail screen.
            if let id = initialTaskId, let task = tasks.first(where: { $0.id == id }) {
                DispatchQueue.main.async { onOpenTaskDetail(task) }
            }
        }
    }

    // MARK: - Subsections (broken out so the body type-checks fast)

    /// Green pill with `doneCount/total` per HTML 1059.
    private var tasksDonePill: some View {
        let done = tasks.filter { $0.state == .done }.count
        return Text("\(done)/\(tasks.count)")
            .font(.custom("Manrope", size: 11).weight(.heavy))
            .foregroundStyle(Color.evSecondary)
            .padding(.horizontal, 10)
            .frame(minWidth: 44, minHeight: 24)
            .background(Capsule().fill(Color.evSecondaryContainer))
    }

    private var devicesSection: some View {
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
                        text: "\(devices.count) \(localStatus == .unlocked ? "active" : "locked")",
                        tone: localStatus == .unlocked ? .success : .danger,
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
                // Make the entire header row hit-test as one rectangle.
                // Without this the Spacer between the pill and the chevron
                // is "empty" and a tap there does nothing — the user would
                // have to land on the chevron itself to expand/collapse.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if devicesExpanded {
                VStack(spacing: 0) {
                    ForEach(Array(devices.enumerated()), id: \.element.id) { idx, d in
                        DeviceRow(
                            iconSystemName: d.iconSystemName,
                            name: d.name,
                            detail: d.detail,
                            locked: localStatus != .unlocked,
                            timeLeft: child.timeLeft,
                            timePct: child.timePct,
                            isLast: idx == devices.count - 1,
                            onPress: { onOpenDevice(d) }
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

    // Keep this helper around (commented out) so we can flip the section
    // back on without rebuilding it. Mirror of pre-pixel-perfect-pass impl.
    //
    // private var todaysScheduleSection: some View {
    //     VStack(spacing: 0) {
    //         SectionHead(title: "Today's Schedule") {
    //             Button { onOpenCalendar() } label: {
    //                 Text("OPEN CALENDAR")
    //                     .font(.custom("Inter", size: 10).weight(.heavy))
    //                     .tracking(1.4)
    //                     .foregroundStyle(Color.evPrimary)
    //             }
    //         }
    //         VStack(spacing: 0) {
    //             ForEach(events) { e in
    //                 HStack(spacing: 14) {
    //                     Text(e.time)
    //                         .font(.custom("Inter", size: 11).weight(.bold))
    //                         .tracking(0.6)
    //                         .foregroundStyle(Color.evOnSurfaceVariant)
    //                         .frame(width: 72, alignment: .leading)
    //                     Circle().fill(child.accentColor).frame(width: 6, height: 6)
    //                     VStack(alignment: .leading, spacing: 1) {
    //                         Text(e.title)
    //                             .font(.custom("Manrope", size: 14).weight(.bold))
    //                             .foregroundStyle(Color.evPrimary)
    //                         if let loc = e.location {
    //                             Text(loc)
    //                                 .font(.custom("Inter", size: 11))
    //                                 .foregroundStyle(Color.evOnSurfaceVariant)
    //                         }
    //                     }
    //                     Spacer()
    //                 }
    //                 .padding(.vertical, 12)
    //                 .padding(.horizontal, 14)
    //                 .overlay(
    //                     Rectangle().fill(Color.evOutlineVariant.opacity(0.4)).frame(height: 1),
    //                     alignment: .bottom
    //                 )
    //             }
    //         }
    //         .background(
    //             RoundedRectangle(cornerRadius: 18, style: .continuous)
    //                 .fill(Color.evSurfaceContainerLowest)
    //         )
    //         .overlay(
    //             RoundedRectangle(cornerRadius: 18, style: .continuous)
    //                 .stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
    //         )
    //     }
    // }

    private var activeRulesSection: some View {
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
                // Same reasoning as Enrolled Devices — Spacer hit-testing
                // requires an explicit content shape on the label.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if rulesExpanded {
                VStack(spacing: 0) {
                    ForEach($rules) { $rule in
                        RuleRow(iconSystemName: rule.iconSystemName,
                                title: rule.title, detail: rule.detail,
                                isOn: $rule.on, tone: rule.tone,
                                onEdit: { editingRule = rule })
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
    }

    private var summaryCard: some View {
        let isUnlocked = localStatus == .unlocked
        return VStack(spacing: 16) {
            HStack(spacing: 18) {
                EvlinAvatarView(
                    url: displayChild.avatarURL,
                    name: displayChild.name,
                    size: 64,
                    status: localStatus
                )
                VStack(alignment: .leading, spacing: 6) {
                    Text(displayChild.name)
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

            // Lock/Unlock big CTA — toggles localStatus. HTML 1036-1056.
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    localStatus = isUnlocked ? .locked : .unlocked
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isUnlocked ? "lock" : "lock.open")
                        .font(.system(size: 18, weight: .semibold))
                    Text(isUnlocked
                         ? "Lock \(displayChild.name)'s devices"
                         : "Unlock \(displayChild.name)'s devices")
                        .font(.custom("Manrope", size: 14).weight(.heavy))
                        .tracking(0.2)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isUnlocked
                              ? AnyShapeStyle(Color.evSecondaryGradient)
                              : AnyShapeStyle(Color.evError))
                )
                .shadow(color: (isUnlocked ? Color.evSecondary : Color.evError).opacity(0.32),
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
