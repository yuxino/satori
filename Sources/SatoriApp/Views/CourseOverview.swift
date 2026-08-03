import AppKit
import SwiftUI
import SatoriCore

struct CourseOverview: View {
    @EnvironmentObject private var store: AppModel
    let course: CourseWorkspace
    @State private var selectedDocumentID: UUID?

    var selectedDocument: StudyDocument? {
        if let selectedID = selectedDocumentID ?? store.selectedDocumentID,
           let selected = course.documents.first(where: { $0.id == selectedID }) {
            return selected
        }
        return course.documents.last
    }

    var body: some View {
        Group {
            if let document = selectedDocument,
               let url = DocumentBookmarkStore.resolveURL(for: document) {
                HStack(spacing: 0) {
                    PDFReaderView(url: url, initialPosition: document.readingPosition) { pageIndex, offset in
                        store.updateReadingPosition(courseID: course.id, documentID: document.id, pageIndex: pageIndex, normalizedOffset: offset)
                    }
                    Divider()
                    LearningPanel(pageIndex: document.readingPosition.pageIndex, directory: course.learningDirectory)
                        .frame(width: 320)
                }
            } else {
                emptyState
            }
        }
        .navigationTitle(course.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("导入 PDF", systemImage: "plus") { choosePDF() }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text(course.title)
                .font(.title2.weight(.semibold))
            Text(course.subtitle)
                .foregroundStyle(.secondary)
            Button("导入主教材 PDF", systemImage: "folder") { choosePDF() }
                .buttonStyle(.borderedProminent)
            Text("Satori 会识别文字版、扫描版或混合 PDF，并在下次打开时回到你读到的位置。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 450)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func choosePDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            store.importPDF(url, into: course.id)
        }
    }
}

private struct LearningPanel: View {
    let pageIndex: Int
    let directory: [LearningDirectoryItem]
    private let assistant = UnconfiguredLearningAssistant()
    @State private var question = ""
    @State private var response: LearningResponse?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("学习目录", systemImage: "list.bullet.rectangle")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(directory) { item in
                        Label(item.title, systemImage: item.isComplete ? "checkmark.circle.fill" : "circle")
                            .font(.caption)
                            .foregroundStyle(item.isComplete ? .secondary : .primary)
                    }
                }
            }
            .frame(maxHeight: 150)
            Divider()
            Label("理解助手", systemImage: "sparkles")
                .font(.headline)
            Text("优先基于当前 PDF 第 \(pageIndex + 1) 页解释；联网与外部知识会明确标注来源。")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $question)
                .font(.body)
                .frame(minHeight: 100)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            Button("帮我理解", systemImage: "arrow.up.circle.fill") {
                Task { response = await assistant.explain(request: question, pageIndex: pageIndex) }
            }
            .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let response {
                Divider()
                Text(response.sourceKind.localizedTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(response.text)
                    .font(.callout)
            }
            Spacer()
        }
        .padding(18)
    }
}
