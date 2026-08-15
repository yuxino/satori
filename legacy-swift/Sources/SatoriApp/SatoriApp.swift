import SwiftUI
import SatoriCore
import os

@main
struct SatoriApp: App {
    @StateObject private var store = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 960, minHeight: 720)
                .tint(SatoriTheme.accent)
        }
        .windowStyle(.automatic)

        Settings {
            QwenSettingsView()
        }
    }
}

/// 启动时恢复「上次打开的书」的反馈负载：课程 + 书名。
struct RestoredSessionFeedback: Equatable, Sendable {
    let courseID: UUID
    let documentName: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var plan = LearningPlan()
    @Published var selectedCourseID: UUID?
    @Published var selectedDocumentID: UUID?
    /// Non-nil while the persisted plan failed to load (e.g. a corrupt file).
    /// Surfaced in the UI so the failure is never silently overwritten.
    @Published private(set) var persistenceIssue: String?
    /// 启动时成功恢复「上次打开的书」后的反馈（书名等），由侧边栏短暂展示，
    /// 让恢复不是静默发生。仅在首次加载时设置一次，后续 load()（课程增删改等）
    /// 不会再次弹出。
    @Published private(set) var restoredSession: RestoredSessionFeedback?

    private let persistence = LearningPlanStore()
    private let logger = Logger(subsystem: "app.satori", category: "AppModel")
    private let defaults = UserDefaults.standard
    /// 恢复反馈只针对「本次启动」的首次恢复；之后的 load() 会重新恢复选择
    /// （课程增删改后），但不再重复弹出提示。
    private var hasSetRestoreFeedback = false
    private static let lastCourseKey = "satori.lastOpened.courseID"
    private static let lastDocumentKey = "satori.lastOpened.documentID"

    /// 记住用户上次打开的课程与 PDF，重启后自动回到同一本书同一页。
    func rememberOpenedDocument(courseID: UUID, documentID: UUID) {
        selectedCourseID = courseID
        selectedDocumentID = documentID
        defaults.set(courseID.uuidString, forKey: Self.lastCourseKey)
        defaults.set(documentID.uuidString, forKey: Self.lastDocumentKey)
    }

    /// 从上次记忆恢复选择。
    /// 1. 优先用 UserDefaults 里显式记住的「课程+书」（点书单菜单/打开书时写入）；
    /// 2. 没有记忆键（从未点过书单菜单就直接读书）时，按各书最近打开时间
    ///    `readingPosition.lastOpenedAt` 恢复，回到用户真正在读的那一本；
    /// 3. 都没有则回退到第一门课。
    private func restoreLastOpenedDocument() {
        var restoredCourseID: UUID?
        var restoredDocumentName: String?
        if let courseIDString = defaults.string(forKey: Self.lastCourseKey),
           let courseID = UUID(uuidString: courseIDString),
           let course = plan.courses.first(where: { $0.id == courseID }) {
            selectedCourseID = courseID
            if let documentIDString = defaults.string(forKey: Self.lastDocumentKey),
               let documentID = UUID(uuidString: documentIDString),
               let document = course.documents.first(where: { $0.id == documentID }) {
                selectedDocumentID = documentID
                restoredCourseID = courseID
                restoredDocumentName = document.displayName
            }
            // 记忆键在但书已被移除：继续走最近打开时间回退。
        }
        if restoredDocumentName == nil {
            var bestCourseID: UUID?
            var bestDocumentID: UUID?
            var bestDate = Date.distantPast
            for course in plan.courses {
                for document in course.documents where document.readingPosition.lastOpenedAt > bestDate {
                    bestDate = document.readingPosition.lastOpenedAt
                    bestCourseID = course.id
                    bestDocumentID = document.id
                    restoredDocumentName = document.displayName
                }
            }
            selectedCourseID = bestCourseID ?? plan.courses.first?.id
            selectedDocumentID = bestDocumentID
            restoredCourseID = bestCourseID
        }
        if !hasSetRestoreFeedback {
            hasSetRestoreFeedback = true
            if let restoredCourseID, let restoredDocumentName {
                restoredSession = RestoredSessionFeedback(courseID: restoredCourseID, documentName: restoredDocumentName)
            }
        }
    }

    /// Tail of the serialized save queue: every save waits for the previous
    /// one to finish, so rapid updates can't interleave or drop each other.
    private var saveChain: Task<Void, Never>?
    /// Debounce handle for high-frequency saves (reading position).
    private var debouncedSaveTask: Task<Void, Never>?
    private let saveDebounceDelay = Duration.milliseconds(750)

    init() {
        Task { await load() }
    }

    func load() async {
        do {
            plan = try await persistence.load()
            persistenceIssue = nil
            restoreLastOpenedDocument()
        } catch {
            // Do NOT overwrite a corrupt file with a fresh default: the store
            // layer backs the bad file up (`.corrupt-<ts>`) so the data can be
            // recovered. We surface the problem instead of hiding it.
            logger.error("加载学习计划失败：\(error.localizedDescription, privacy: .public)")
            persistenceIssue = "学习计划文件无法读取，已自动备份损坏文件并重建。若你记得之前的进度，可到应用支持目录找回。"
            restoreLastOpenedDocument()
        }
    }

    func acknowledgePersistenceIssue() {
        persistenceIssue = nil
    }

    func dismissRestoredSessionFeedback() {
        restoredSession = nil
    }

    /// Immediate, serialized save for discrete user actions (import/replace/
    /// remove). The snapshot is captured on the main actor, writes are chained.
    func save() {
        enqueueSave(plan)
    }

    /// Debounced, serialized save for high-frequency updates (reading
    /// position), so rapid scrolling doesn't trigger a write per page turn.
    private func saveDebounced() {
        debouncedSaveTask?.cancel()
        let snapshot = plan
        let delay = saveDebounceDelay
        debouncedSaveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.enqueueSave(snapshot)
        }
    }

    /// Appends one snapshot write to the serialized save queue.
    private func enqueueSave(_ snapshot: LearningPlan) {
        let previous = saveChain
        saveChain = Task { [weak self, persistence] in
            await previous?.value
            guard let self else { return }
            await self.persist(snapshot, attempt: 1)
        }
    }

    /// Writes one snapshot; on failure, retries with backoff so an update is
    /// not silently dropped, and logs every failure.
    private func persist(_ snapshot: LearningPlan, attempt: Int) async {
        do {
            try await persistence.save(snapshot)
        } catch {
            logger.error("保存学习计划失败（第 \(attempt) 次）：\(error.localizedDescription, privacy: .public)")
            guard attempt < 3 else { return }
            try? await Task.sleep(for: .seconds(Double(attempt) * 2))
            guard !Task.isCancelled else { return }
            await persist(snapshot, attempt: attempt + 1)
        }
    }

    func importPDF(_ url: URL, into courseID: UUID) async {
        guard let courseIndex = plan.courses.firstIndex(where: { $0.id == courseID }) else { return }
        guard let document = await makeDocumentOffMain(from: url) else { return }
        plan.courses[courseIndex].documents.append(document)
        rememberOpenedDocument(courseID: courseID, documentID: document.id)
        save()
    }

    func replacePDF(_ url: URL, in courseID: UUID, documentID: UUID) async {
        guard let courseIndex = plan.courses.firstIndex(where: { $0.id == courseID }),
              let documentIndex = plan.courses[courseIndex].documents.firstIndex(where: { $0.id == documentID }) else { return }
        guard let replacement = await makeDocumentOffMain(from: url) else { return }
        plan.courses[courseIndex].documents[documentIndex] = replacement
        rememberOpenedDocument(courseID: courseID, documentID: replacement.id)
        save()
    }

    /// PDF inspection (page count + text/scanned classification) runs off the
    /// main actor so importing a large PDF doesn't freeze the UI.
    private func makeDocumentOffMain(from url: URL) async -> StudyDocument? {
        let logger = logger
        return await Task.detached(priority: .userInitiated) {
            do {
                return try DocumentBookmarkStore.makeDocument(from: url)
            } catch {
                logger.error("PDF 导入失败：\(error.localizedDescription, privacy: .public)")
                return nil
            }
        }.value
    }

    func removeDocument(courseID: UUID, documentID: UUID) {
        guard let courseIndex = plan.courses.firstIndex(where: { $0.id == courseID }) else { return }
        plan.courses[courseIndex].documents.removeAll { $0.id == documentID }
        if selectedDocumentID == documentID {
            if let next = plan.courses[courseIndex].documents.last {
                rememberOpenedDocument(courseID: courseID, documentID: next.id)
            } else {
                selectedDocumentID = nil
                defaults.removeObject(forKey: Self.lastDocumentKey)
            }
        }
        save()
    }

    func updateReadingPosition(courseID: UUID, documentID: UUID, pageIndex: Int, normalizedOffset: Double = 0) {
        guard let courseIndex = plan.courses.firstIndex(where: { $0.id == courseID }),
              let documentIndex = plan.courses[courseIndex].documents.firstIndex(where: { $0.id == documentID }) else { return }
        plan.courses[courseIndex].documents[documentIndex].readingPosition = ReadingPosition(
            pageIndex: pageIndex,
            normalizedPageOffset: normalizedOffset,
            lastOpenedAt: .now
        )
        saveDebounced()
    }
}
