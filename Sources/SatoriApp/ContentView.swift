import AppKit
import SwiftUI
import SatoriCore

/// The next useful thing to do with a selected passage. Keep this small and
/// reading-first: a selection is usually a request for understanding, not a
/// request to manage a note or open a code workspace.
enum ReaderSelectionIntent: String, Equatable, Sendable {
    case explain
    case context
    case example
    case experiment
}

/// A text selection the reader routed to the learning panel. `id` makes
/// repeated identical selections distinct so `onChange` consumers fire every
/// time the same passage is picked again.
struct ReaderSelectionRequest: Equatable, Sendable {
    let id = UUID()
    let documentID: UUID
    let text: String
    let pageIndex: Int
    /// 选中原文时的页内阅读位置；旧请求没有该值时仍可退回页首。
    let position: ReadingPosition?
    let url: URL?
    let intent: ReaderSelectionIntent
}

/// A cropped region from a scanned PDF page. It stays in memory only long
/// enough to become the next question's attachment; it is never persisted as
/// a note or a separate file.
struct ReaderPageRegionRequest: Equatable, Sendable {
    let id = UUID()
    let documentID: UUID
    let jpegData: Data
    let pageIndex: Int
    let url: URL?
}

/// ContentView-owned routing state for the reader ↔ panel channels (redesign
/// 4.1 / 4.3). AppModel lives in SatoriApp.swift (read-only for this team), so
/// the selection + layout channels live here instead, injected as an
/// environment object for any child to consume.
@MainActor
final class ReaderSelectionRouter: ObservableObject {
    static let shared = ReaderSelectionRouter()

    /// 划选即理解 channel: PDFReaderView's selection actions post
    /// .satoriAskSelectionRequested, ContentView stores the typed request here.
    @Published var pendingAskSelection: ReaderSelectionRequest?
    /// Same channel for「运行」: selected code should land in the run space.
    @Published var pendingRunSelection: ReaderSelectionRequest?
    /// Same reading loop for scanned-page region crops.
    @Published var pendingPageRegion: ReaderPageRegionRequest?
    /// True when the window is below the wide threshold (< 1240): the learning
    /// panel should float over the PDF instead of squeezing it.
    @Published var inspectorFloats = false

    /// Protect the reading flow by temporarily removing course chrome and the
    /// learning inspector while keeping the document, page position, and
    /// selection routing alive. This is intentionally session-scoped: opening
    /// the app should never strand a user in a mode with hidden navigation.
    @Published var isImmersiveReading = false
}

struct ContentView: View {
    @EnvironmentObject private var store: AppModel
    @StateObject private var router = ReaderSelectionRouter.shared
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            NavigationSplitView(columnVisibility: $columnVisibility) {
                PlanSidebar(selection: $store.selectedCourseID, isCompact: width < 1240)
            } detail: {
                if let course = store.plan.courses.first(where: { $0.id == store.selectedCourseID }) {
                    CourseOverview(course: course)
                        .id(course.id)
                } else {
                    ContentUnavailableView("选择一个阅读空间", systemImage: "books.vertical", description: Text("从左侧打开一本书，直接开始理解。"))
                }
            }
            .navigationSplitViewStyle(.balanced)
            .onChange(of: width) { _, newWidth in
                applyLayout(for: newWidth)
            }
            .onChange(of: router.isImmersiveReading) { _, _ in
                applyLayout(for: width)
            }
            .task(id: width) {
                applyLayout(for: width)
            }
        }
        .environmentObject(router)
        .onReceive(NotificationCenter.default.publisher(for: .satoriAskSelectionRequested)) { note in
            guard let documentID = note.userInfo?["documentID"] as? UUID,
                  let text = note.userInfo?["text"] as? String,
                  let pageIndex = note.userInfo?["pageIndex"] as? Int else { return }
            Task { @MainActor in
                router.pendingAskSelection = ReaderSelectionRequest(
                    documentID: documentID,
                    text: text,
                    pageIndex: pageIndex,
                    position: note.userInfo?["position"] as? ReadingPosition,
                    url: note.userInfo?["url"] as? URL,
                    intent: ReaderSelectionIntent(
                        rawValue: note.userInfo?["intent"] as? String ?? ""
                    ) ?? .explain
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .satoriRunSelectionRequested)) { note in
            guard let documentID = note.userInfo?["documentID"] as? UUID,
                  let text = note.userInfo?["text"] as? String,
                  let pageIndex = note.userInfo?["pageIndex"] as? Int else { return }
            Task { @MainActor in
                router.pendingRunSelection = ReaderSelectionRequest(
                    documentID: documentID,
                    text: text,
                    pageIndex: pageIndex,
                    position: note.userInfo?["position"] as? ReadingPosition,
                    url: note.userInfo?["url"] as? URL,
                    intent: .explain
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .satoriPageRegionCaptured)) { note in
            guard let documentID = note.userInfo?["documentID"] as? UUID,
                  let jpegData = note.userInfo?["jpegData"] as? Data,
                  let pageIndex = note.userInfo?["pageIndex"] as? Int else { return }
            let requestedURL = note.userInfo?["url"] as? URL
            Task { @MainActor in
                router.pendingPageRegion = ReaderPageRegionRequest(
                    documentID: documentID,
                    jpegData: jpegData,
                    pageIndex: pageIndex,
                    url: requestedURL
                )
            }
        }
        .background(WindowMinSizeAccessor(minWidth: 960))
    }

    /// Adaptive three-tier layout (redesign 4.1):
    /// - ≥ 1240: full sidebar + PDF + learning panel
    /// - 960…1240: sidebar collapses to an icon strip (PlanSidebar isCompact);
    ///   the learning panel should float (router.inspectorFloats = true) so the
    ///   PDF never gets squeezed below its 620pt minimum.
    /// - < 960: single column (sidebar hidden behind the system toggle).
    /// The float switch carries hysteresis: once floating, the panel stays
    /// floating until the window clearly widens (≥ 1300), so dragging the
    /// window around the 1240 boundary doesn't flip the whole workspace
    /// (horizontal ↔ vertical) back and forth.
    private static let floatThreshold: CGFloat = 1240
    private static let floatExitThreshold: CGFloat = 1300

    private func applyLayout(for width: CGFloat) {
        if router.inspectorFloats {
            if width >= Self.floatExitThreshold {
                router.inspectorFloats = false
            }
        } else if width < Self.floatThreshold {
            router.inspectorFloats = true
        }
        let visibility: NavigationSplitViewVisibility = router.isImmersiveReading || width < 960 ? .detailOnly : .all
        guard columnVisibility != visibility else { return }
        withAnimation(SatoriTheme.Motion.quick) {
            columnVisibility = visibility
        }
    }
}

// MARK: - AppModel course management + reader jump API

/// AppModel itself is defined in SatoriApp.swift, whose `plan` setter is
/// `private(set)` — extensions in this file cannot mutate it directly. The
/// redesign 4.5 course API therefore persists an updated plan through a fresh
/// LearningPlanStore and reloads it into AppModel via `load()` (write →
/// reload), which keeps AppModel as the single source of truth.
@MainActor
extension AppModel {
    /// Creates a reading space (default title「阅读空间 N」) and selects it.
    @discardableResult
    func addCourse(title: String? = nil) async -> UUID? {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var updated = plan
        let course = CourseWorkspace(
            title: trimmed.isEmpty ? "阅读空间 \(plan.courses.count + 1)" : trimmed,
            subtitle: "个人阅读"
        )
        updated.courses.append(course)
        do {
            try await LearningPlanStore().save(updated)
            await load()
            selectedCourseID = course.id
            save()
            return course.id
        } catch {
            return nil
        }
    }

    func removeCourse(id: UUID) async {
        guard plan.courses.contains(where: { $0.id == id }) else { return }
        let wasSelected = selectedCourseID == id
        let previousSelection = selectedCourseID
        var updated = plan
        updated.courses.removeAll { $0.id == id }
        do {
            try await LearningPlanStore().save(updated)
            await load()
            // load() selects the first course; restore the previous selection
            // unless the removed course was the one selected.
            selectedCourseID = wasSelected ? plan.courses.first?.id : previousSelection
            save()
        } catch {
            // Keep the in-memory plan unchanged on failure.
        }
    }

    func renameCourse(id: UUID, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = plan.courses.firstIndex(where: { $0.id == id }) else { return }
        var updated = plan
        updated.courses[index].title = trimmed
        do {
            try await LearningPlanStore().save(updated)
            await load()
            save()
        } catch {
            // Keep the in-memory plan unchanged on failure.
        }
    }

    /// Asks the active reader (whose document URL matches) to jump to a page
    /// at a normalized in-page offset. LearningInspector's「回看原文」can call
    /// this with the stored ReadingPosition of a source card.
    func requestReaderJump(to position: ReadingPosition, in url: URL) {
        NotificationCenter.default.post(
            name: .satoriReaderJumpRequested,
            object: nil,
            userInfo: ["url": url, "position": position]
        )
    }
}

/// Lowers the window's minimum content width to ~960 so the adaptive tiers can
/// actually be reached. SatoriApp.swift still declares `.frame(minWidth: 1120)`
/// on the root content — that SwiftUI minimum is re-asserted here at the AppKit
/// level (on attach and after every resize) so the user can shrink past it.
private struct WindowMinSizeAccessor: NSViewRepresentable {
    let minWidth: CGFloat
    let minHeight: CGFloat = 640

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.observe(view, minWidth: minWidth, minHeight: minHeight)
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            apply(to: view)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: NSView) {
        guard let window = view.window else { return }
        window.minSize = NSSize(width: minWidth, height: minHeight)
    }

    final class Coordinator: NSObject {
        private var resizeToken: NSObjectProtocol?

        func observe(_ view: NSView, minWidth: CGFloat, minHeight: CGFloat) {
            resizeToken = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: nil,
                queue: .main
            ) { [weak view] _ in
                guard let window = view?.window else { return }
                window.minSize = NSSize(width: minWidth, height: minHeight)
            }
        }

        deinit {
            if let resizeToken {
                NotificationCenter.default.removeObserver(resizeToken)
            }
        }
    }
}
