import SwiftUI

/// Navigation-stack hosted Task Detail screen. Pushed from ProfileView,
/// NotificationPanel (Insights bell flow), or any other route. Uses the
/// project's standard edge-swipe back gesture (`.enableSwipeBack`) so
/// dragging from the screen's left edge pops it.
///
/// Keeps the heavy presentation in `TaskDetailSheet` (renamed for legacy
/// reasons but acts as a pure rendering view). This wrapper:
///   - resolves the live task from `ProfileMockData.runtimeTasks`
///   - mutates that store on Approve/Redo/Edit/Delete
///   - hosts the in-place EditTaskCard modal (no native sheet)
struct TaskDetailView: View {
    let childId: String
    let taskId: Int
    var onBack: () -> Void = {}

    @State private var task: TaskItem? = nil
    @State private var editingTask: TaskItem? = nil
    @State private var showFullscreenPhoto: Bool = false
    @State private var fullscreenStartIndex: Int = 0

    private var resolvedChild: ChildProfile {
        ChildProfile.all.first(where: { $0.id == childId }) ?? .liam
    }

    var body: some View {
        ZStack {
            if let liveTask = task {
                TaskDetailSheet(
                    task: liveTask,
                    child: resolvedChild,
                    onClose: onBack,
                    onApprove: {
                        approve(liveTask)
                    },
                    onRedo: {
                        redo(liveTask)
                    },
                    onEdit: {
                        editingTask = liveTask
                    },
                    onPhotoTap: { idx in
                        fullscreenStartIndex = idx
                        showFullscreenPhoto = true
                    }
                )
            } else {
                // Lost task (e.g. deleted from elsewhere): fall back to
                // a graceful empty screen with a back button.
                missingTaskFallback
            }
        }
        .background(Color.evSurface)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .enableSwipeBack()
        .onAppear { reloadTask() }
        // Edit Task lives inside TaskDetail itself (not on the parent
        // ProfileView) so the modal renders above this screen even
        // after we deep-link in via NotificationPanel.
        .overlay {
            EvlinSheetCardItem(item: $editingTask) { activeEdit in
                EditTaskForm(
                    task: activeEdit,
                    onSave: { updated in
                        ProfileMockData.updateTask(updated, for: childId)
                        editingTask = nil
                        reloadTask()
                    },
                    onDelete: {
                        ProfileMockData.deleteTask(activeEdit.id, for: childId)
                        editingTask = nil
                        onBack()
                    },
                    onCancel: { editingTask = nil }
                )
            }
        }
        .fullScreenCover(isPresented: $showFullscreenPhoto) {
            if let urls = task?.photos, !urls.isEmpty {
                PhotoGalleryViewer(
                    photos: urls,
                    startIndex: fullscreenStartIndex,
                    isPresented: $showFullscreenPhoto
                )
            }
        }
    }

    // MARK: - Mutations

    private func reloadTask() {
        let list = ProfileMockData.tasks(for: childId)
        task = list.first(where: { $0.id == taskId })
    }

    private func approve(_ t: TaskItem) {
        var copy = t
        copy.state = (t.state == .bypass) ? .bypassed : .done
        ProfileMockData.updateTask(copy, for: childId)
        // Stay on screen so the user sees the resolved status — most
        // pushed flows expect to be popped by the user, not implicitly.
        reloadTask()
    }

    private func redo(_ t: TaskItem) {
        var copy = t
        copy.state = .pending
        ProfileMockData.updateTask(copy, for: childId)
        reloadTask()
    }

    // MARK: - Fallback

    private var missingTaskFallback: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color.evOnSurfaceVariant)
            Text("This task is no longer available.")
                .font(.custom("Inter", size: 14))
                .foregroundStyle(Color.evOnSurfaceVariant)
            Button("Back", action: onBack)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
