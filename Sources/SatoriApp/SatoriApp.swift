import SwiftUI
import SatoriCore

@main
struct SatoriApp: App {
    @StateObject private var store = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 980, minHeight: 680)
        }
        .windowStyle(.automatic)

        Settings {
            OpenAISettingsView()
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var plan = LearningPlan()
    @Published var selectedCourseID: UUID?
    @Published var selectedDocumentID: UUID?

    private let persistence = LearningPlanStore()

    init() {
        Task { await load() }
    }

    func load() async {
        do {
            plan = try await persistence.load()
            selectedCourseID = plan.courses.first?.id
        } catch {
            selectedCourseID = plan.courses.first?.id
        }
    }

    func save() {
        let snapshot = plan
        Task { try? await persistence.save(snapshot) }
    }

    func importPDF(_ url: URL, into courseID: UUID) {
        guard let index = plan.courses.firstIndex(where: { $0.id == courseID }),
              let document = try? DocumentBookmarkStore.makeDocument(from: url) else { return }
        plan.courses[index].documents.append(document)
        selectedDocumentID = document.id
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
        save()
    }
}
