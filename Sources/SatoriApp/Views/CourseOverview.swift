import AppKit
import SwiftUI
import SatoriCore

struct CourseOverview: View {
    @EnvironmentObject private var store: AppModel
    let course: CourseWorkspace
    @State private var selectedDocumentID: UUID?
    @State private var showsRemoveConfirmation = false

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
                DocumentWorkspace(course: course, document: document, url: url)
                    .id(document.id)
            } else {
                emptyState
            }
        }
        .navigationTitle(course.title)
        .toolbar {
            if let document = selectedDocument {
                ToolbarItem {
                    documentMenu(document)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("导入 PDF", systemImage: "plus") { choosePDF() }
            }
        }
        .alert("移除“\(selectedDocument?.displayName ?? "这份 PDF")”？", isPresented: $showsRemoveConfirmation) {
            Button("取消", role: .cancel) {}
            Button("移除引用", role: .destructive) {
                guard let document = selectedDocument else { return }
                store.removeDocument(courseID: course.id, documentID: document.id)
                selectedDocumentID = nil
            }
        } message: {
            Text("它只会从这个学习项目中移除，电脑上的原始 PDF 不会被删除。")
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

    private func documentMenu(_ currentDocument: StudyDocument) -> some View {
        Menu {
            Section("这门课的 PDF") {
                ForEach(course.documents) { document in
                    Button {
                        selectedDocumentID = document.id
                        store.selectedDocumentID = document.id
                    } label: {
                        if document.id == currentDocument.id {
                            Label(document.displayName, systemImage: "checkmark")
                        } else {
                            Text(document.displayName)
                        }
                    }
                }
            }
            Divider()
            Button("替换当前 PDF…", systemImage: "arrow.triangle.2.circlepath") {
                choosePDF(replacing: currentDocument)
            }
            Button("移除当前 PDF", systemImage: "trash", role: .destructive) {
                showsRemoveConfirmation = true
            }
        } label: {
            Label(currentDocument.displayName, systemImage: "doc.text")
                .lineLimit(1)
        }
        .help("切换、替换或移除 PDF")
    }

    private func choosePDF(replacing document: StudyDocument? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            if let document {
                store.replacePDF(url, in: course.id, documentID: document.id)
                selectedDocumentID = nil
            } else {
                store.importPDF(url, into: course.id)
                selectedDocumentID = nil
            }
        }
    }
}

private struct DocumentWorkspace: View {
    @EnvironmentObject private var store: AppModel
    let course: CourseWorkspace
    let document: StudyDocument
    let url: URL
    @State private var currentPageIndex: Int
    @State private var pageInput = ""

    init(course: CourseWorkspace, document: StudyDocument, url: URL) {
        self.course = course
        self.document = document
        self.url = url
        _currentPageIndex = State(initialValue: document.readingPosition.pageIndex)
    }

    private var pageCount: Int { max(document.pageCount, 1) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                pageBar
                Divider()
                PDFReaderView(
                    url: url,
                    initialPosition: document.readingPosition,
                    currentPageIndex: $currentPageIndex
                ) { pageIndex, offset in
                    store.updateReadingPosition(
                        courseID: course.id,
                        documentID: document.id,
                        pageIndex: pageIndex,
                        normalizedOffset: offset
                    )
                }
            }
            Divider()
            LearningPanel(pageIndex: currentPageIndex, directory: course.learningDirectory)
                .frame(width: 320)
        }
    }

    private var pageBar: some View {
        HStack(spacing: 10) {
            Button("上一页", systemImage: "chevron.left") {
                currentPageIndex = max(0, currentPageIndex - 1)
            }
            .labelStyle(.iconOnly)
            .disabled(currentPageIndex == 0)

            Text("第 \(currentPageIndex + 1) / \(pageCount) 页")
                .font(.callout.monospacedDigit().weight(.medium))
                .frame(minWidth: 100)
                .accessibilityLabel("第 \(currentPageIndex + 1) 页，共 \(pageCount) 页")

            Button("下一页", systemImage: "chevron.right") {
                currentPageIndex = min(pageCount - 1, currentPageIndex + 1)
            }
            .labelStyle(.iconOnly)
            .disabled(currentPageIndex >= pageCount - 1)

            Divider()
                .frame(height: 18)

            TextField("页码", text: $pageInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 62)
                .onSubmit(jumpToPage)
            Button("跳转", action: jumpToPage)
                .disabled(Int(pageInput) == nil)

            Spacer()
            Text(document.contentKind.localizedTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(.bar)
    }

    private func jumpToPage() {
        guard let requestedPage = Int(pageInput) else { return }
        currentPageIndex = min(max(requestedPage - 1, 0), pageCount - 1)
        pageInput = ""
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
