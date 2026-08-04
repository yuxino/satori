import AppKit
import SwiftUI
import SatoriCore

struct CourseOverview: View {
    @EnvironmentObject private var store: AppModel
    let course: CourseWorkspace
    @State private var selectedDocumentID: UUID?
    @State private var showsRemoveConfirmation = false

    private var selectedDocument: StudyDocument? {
        if let selectedID = selectedDocumentID ?? store.selectedDocumentID,
           let selected = course.documents.first(where: { $0.id == selectedID }) {
            return selected
        }
        return course.documents.last
    }

    var body: some View {
        Group {
            if let document = selectedDocument {
                if let url = DocumentBookmarkStore.resolveURL(for: document) {
                    DocumentWorkspace(
                        course: course,
                        document: document,
                        url: url,
                        onSelectDocument: selectDocument,
                        onImport: { choosePDF() },
                        onReplace: { choosePDF(replacing: document) },
                        onRemove: { showsRemoveConfirmation = true }
                    )
                    .id(document.id)
                } else {
                    missingDocumentState(document)
                }
            } else {
                emptyState
            }
        }
        .navigationTitle(course.title)
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
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(SatoriTheme.accentWash)
                    .frame(width: 96, height: 96)
                Image(systemName: "book.pages.fill")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(SatoriTheme.accent)
            }
            VStack(spacing: 8) {
                Text("从一本教材开始")
                    .font(.title2.weight(.semibold))
                Text("导入 PDF 后，Satori 会记住阅读位置，并让理解助手围绕你正在看的页工作。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            Button("选择 PDF", systemImage: "plus") { choosePDF() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(SatoriTheme.accent)
            Text("支持文字版、扫描版与混合 PDF · 文件保留在本机")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func missingDocumentState(_ document: StudyDocument) -> some View {
        ContentUnavailableView {
            Label("找不到 \(document.displayName)", systemImage: "doc.badge.ellipsis")
        } description: {
            Text("原文件可能被移动或改名。可以重新选择这份教材，不会影响其他课程。")
        } actions: {
            Button("重新选择 PDF") { choosePDF(replacing: document) }
                .buttonStyle(.borderedProminent)
                .tint(SatoriTheme.accent)
            Button("移除引用", role: .destructive) { showsRemoveConfirmation = true }
        }
    }

    private func selectDocument(_ documentID: UUID) {
        selectedDocumentID = documentID
        store.selectedDocumentID = documentID
    }

    private func choosePDF(replacing document: StudyDocument? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = document == nil ? "选择要加入 \(course.title) 的 PDF" : "选择用来替换 \(document?.displayName ?? "当前教材") 的 PDF"
        if panel.runModal() == .OK, let url = panel.url {
            if let document {
                store.replacePDF(url, in: course.id, documentID: document.id)
            } else {
                store.importPDF(url, into: course.id)
            }
            selectedDocumentID = nil
        }
    }
}

private struct DocumentWorkspace: View {
    @EnvironmentObject private var store: AppModel
    let course: CourseWorkspace
    let document: StudyDocument
    let url: URL
    let onSelectDocument: (UUID) -> Void
    let onImport: () -> Void
    let onReplace: () -> Void
    let onRemove: () -> Void
    @State private var currentPageIndex: Int
    @State private var pageInput = ""
    @State private var showsInspector = true
    @State private var panelWidth: CGFloat = 430
    @State private var isDraggingDivider = false

    init(
        course: CourseWorkspace,
        document: StudyDocument,
        url: URL,
        onSelectDocument: @escaping (UUID) -> Void,
        onImport: @escaping () -> Void,
        onReplace: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.course = course
        self.document = document
        self.url = url
        self.onSelectDocument = onSelectDocument
        self.onImport = onImport
        self.onReplace = onReplace
        self.onRemove = onRemove
        _currentPageIndex = State(initialValue: document.readingPosition.pageIndex)
    }

    private var pageCount: Int { max(document.pageCount, 1) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                readingBar
                Divider()
                PDFReaderView(
                    url: url,
                    initialPosition: document.readingPosition,
                    currentPageIndex: $currentPageIndex,
                    onPositionChanged: { pageIndex, offset in
                        store.updateReadingPosition(
                            courseID: course.id,
                            documentID: document.id,
                            pageIndex: pageIndex,
                            normalizedOffset: offset
                        )
                        // Feed the progress bar: record this page as read.
                        Task {
                            try? await LearningStatsStore.shared.recordPageRead(
                                documentID: document.id,
                                pageIndex: pageIndex,
                                pageCount: document.pageCount
                            )
                            NotificationCenter.default.post(name: .learningStatsDidChange, object: nil)
                        }
                    }
                )
            }
            .frame(minWidth: 620)
            .frame(maxWidth: .infinity)

            if showsInspector {
                divider
                LearningInspector(
                    documentID: document.id,
                    pageIndex: currentPageIndex,
                    documentURL: url,
                    onNavigateToPage: { targetPage in
                        currentPageIndex = min(max(targetPage, 0), pageCount - 1)
                    },
                    onClose: { showsInspector = false }
                )
                .frame(minWidth: 360, maxWidth: 620)
                .frame(width: panelWidth)
            }
        }
    }

    /// A wide, grabbable divider between the PDF and the panel. The system
    /// HSplitView handle is thin and fiddly; this one is ~7pt, highlights on
    /// hover, and drags the panel width with a live cursor.
    private var divider: some View {
        Rectangle()
            .fill(isDraggingDivider ? SatoriTheme.accent.opacity(0.35) : Color.primary.opacity(0.08))
            .frame(width: isDraggingDivider ? 7 : 5)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDraggingDivider = true
                        // PDF side takes the left region; grow/shrink the panel
                        // from its right edge. The drag location is in the
                        // divider's own coordinate space.
                        panelWidth = min(max(panelWidth - value.translation.width, 360), 720)
                    }
                    .onEnded { _ in
                        isDraggingDivider = false
                    }
            )
    }

    private var readingBar: some View {
        HStack(spacing: 14) {
            documentMenu

            Spacer(minLength: 8)

            HStack(spacing: 7) {
                Button("上一页", systemImage: "chevron.left") {
                    currentPageIndex = max(0, currentPageIndex - 1)
                }
                .labelStyle(.iconOnly)
                .disabled(currentPageIndex == 0)

                Text("\(currentPageIndex + 1)")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .frame(minWidth: 30, alignment: .trailing)
                Text("/ \(pageCount)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button("下一页", systemImage: "chevron.right") {
                    currentPageIndex = min(pageCount - 1, currentPageIndex + 1)
                }
                .labelStyle(.iconOnly)
                .disabled(currentPageIndex >= pageCount - 1)

                Divider().frame(height: 18)

                TextField("页码", text: $pageInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                    .onSubmit(jumpToPage)
                    .accessibilityLabel("跳转页码")
                Button("跳转", action: jumpToPage)
                    .disabled(Int(pageInput) == nil)
            }

            Spacer(minLength: 8)

            Button {
                showsInspector.toggle()
            } label: {
                Label(showsInspector ? "隐藏理解" : "打开理解", systemImage: "sparkles.rectangle.stack")
            }
            .help(showsInspector ? "隐藏理解面板" : "打开理解面板")
            .tint(SatoriTheme.accent)
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .background(.bar)
    }

    private var documentMenu: some View {
        Menu {
            Section("这门课的 PDF") {
                ForEach(course.documents) { item in
                    Button {
                        onSelectDocument(item.id)
                    } label: {
                        if item.id == document.id {
                            Label(item.displayName, systemImage: "checkmark")
                        } else {
                            Text(item.displayName)
                        }
                    }
                }
            }
            Divider()
            Button("添加另一份 PDF…", systemImage: "plus", action: onImport)
            Button("替换当前 PDF…", systemImage: "arrow.triangle.2.circlepath", action: onReplace)
            Button("移除当前 PDF", systemImage: "trash", role: .destructive, action: onRemove)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "doc.richtext")
                    .foregroundStyle(SatoriTheme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(document.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(document.contentKind.localizedTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(SatoriTheme.accentWash, in: RoundedRectangle(cornerRadius: 9))
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 210, alignment: .leading)
        .help("切换或管理这门课的 PDF")
    }

    private func jumpToPage() {
        guard let requestedPage = Int(pageInput) else { return }
        currentPageIndex = min(max(requestedPage - 1, 0), pageCount - 1)
        pageInput = ""
    }
}
