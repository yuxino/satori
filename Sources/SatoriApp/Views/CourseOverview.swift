import AppKit
import PDFKit
import SwiftUI
import SatoriCore
import Vision

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
            Text("它只会从这个阅读空间中移除，电脑上的原始 PDF 不会被删除。")
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
                Text("从一本书开始")
                    .font(.title2.weight(.semibold))
                Text("打开 PDF 后，Satori 会记住阅读位置，并让理解助手围绕你正在看的页工作。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            Button("选择 PDF", systemImage: "plus") { choosePDF() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(SatoriTheme.accent)
            Text("支持文字版、扫描版与混合 PDF · 原文件保留在本机")
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
            Text("原文件可能被移动或改名。可以重新选择这本书，不会影响其他阅读空间。")
        } actions: {
            Button("重新选择 PDF") { choosePDF(replacing: document) }
                .buttonStyle(.borderedProminent)
                .tint(SatoriTheme.accent)
            Button("移除引用", role: .destructive) { showsRemoveConfirmation = true }
        }
    }

    private func selectDocument(_ documentID: UUID) {
        selectedDocumentID = documentID
        store.rememberOpenedDocument(courseID: course.id, documentID: documentID)
    }

    private func choosePDF(replacing document: StudyDocument? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = document == nil ? "选择要加入 \(course.title) 的 PDF" : "选择用来替换 \(document?.displayName ?? "当前教材") 的 PDF"
        if panel.runModal() == .OK, let url = panel.url {
            Task { @MainActor in
                if let document {
                    await store.replacePDF(url, in: course.id, documentID: document.id)
                } else {
                    await store.importPDF(url, into: course.id)
                }
                selectedDocumentID = nil
            }
        }
    }
}

/// 章节导览里的一章：标题 + 起始页（0 起）。id 用章节序号，避免同页多个标题冲突。
struct BookChapter: Identifiable, Equatable {
    let id: Int
    let title: String
    let pageIndex: Int
    /// outline 里的层级：0 为章，1 为节，2 为小节；课程目录回退时均为 0。
    let depth: Int
    /// Scanned books also carry the printed page shown in their table of
    /// contents. Native PDF outlines leave this nil because PDF and book page
    /// numbers are usually already the same.
    let printedPage: Int?
    /// 0…1 distance from the page top to the chapter title. Older caches and
    /// course-directory fallbacks may not have this geometry yet.
    let normalizedOffset: Double?

    /// 层级感知的页码范围（0 起、含两端）：从自己的起始页到**下一个同级或更高级**
    /// 条目的起始页前 1 页。这样选「第一章」得到整章（含其下所有节），
    /// 选「第一节」只得到这一节。
    static func pageRange(
        for chapter: BookChapter,
        in chapters: [BookChapter],
        pageCount: Int
    ) -> ClosedRange<Int>? {
        guard let index = chapters.firstIndex(where: { $0.id == chapter.id }) else { return nil }
        let start = chapter.pageIndex
        let end: Int
        if let nextSibling = chapters.dropFirst(index + 1).first(where: { $0.depth <= chapter.depth }) {
            end = max(start, nextSibling.pageIndex - 1)
        } else {
            end = pageCount - 1
        }
        return start...end
    }
}

private struct DocumentWorkspace: View {
    @EnvironmentObject private var store: AppModel
    @EnvironmentObject private var router: ReaderSelectionRouter
    let course: CourseWorkspace
    let document: StudyDocument
    let url: URL
    let onSelectDocument: (UUID) -> Void
    let onImport: () -> Void
    let onReplace: () -> Void
    let onRemove: () -> Void
    @State private var currentPageIndex: Int
    @State private var pageInput = ""
    @State private var isSearchPresented = false
    @State private var searchQuery = ""
    @State private var searchNotice = ""
    @State private var searchDirection = 1
    @State private var scannedSearchQuery = ""
    @State private var scannedSearchHasSearched = false
    @State private var isScannedSearching = false
    @State private var scannedSearchTask: Task<Void, Never>?
    @FocusState private var isSearchFieldFocused: Bool
    /// 这本书的章节导览（PDF outline 优先，扫描目录 OCR 次之，课程目录回退）；打开时一次性加载。
    @State private var chapters: [BookChapter] = []
    /// 扫描书的目录识别可能需要几秒；给读者一个低干扰的状态，而不是让目录按钮像坏掉了一样消失。
    @State private var isLoadingChapters = true
    /// 目录快速跳转浮层是否显示（⌘T 或点目录按钮）。
    @State private var showsTOC = false
    @State private var showsInspector = true
    /// 最近一次上报的页内偏移（0…1），随 onPositionChanged 更新；布局切换
    /// 重建 PDFReaderView 时用它恢复位置，避免回落到持久化里的旧页码。
    @State private var currentOffset: Double
    /// Text-native books can print a page number inside the page even when
    /// the PDF index includes front matter. Keep that mapping local so a
    /// textbook citation such as “书内第 180 页” lines up with PDF 第 187 页.
    @State private var nativePrintedPages: [Int: Int] = [:]
    /// 宽窗口下面板宽度、窄窗口下面板高度；分隔条可拖调整，互不遮挡。
    @State private var panelWidth: CGFloat
    @State private var panelHeight: CGFloat
    @State private var isDraggingDivider = false
    @State private var isDraggingHeightDivider = false
    /// Scanned pages have no PDFKit text selection; native pages can also need
    /// this for a diagram/table that is not meaningfully selectable. Keep the
    /// action contextual so ordinary prose does not gain another control.
    @State private var isRegionCaptureEnabled = false
    @State private var currentPageHasVisualEvidence = false

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
        _currentOffset = State(initialValue: document.readingPosition.normalizedPageOffset)
        _showsInspector = State(initialValue: Self.storedInspectorVisible)
        _panelWidth = State(initialValue: Self.storedPanelWidth(for: document.id))
        _panelHeight = State(initialValue: Self.storedPanelHeight(for: document.id))
    }

    private var pageCount: Int { max(document.pageCount, 1) }

    private static func pageHasVisualEvidence(at pageIndex: Int, in url: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }

            guard let pdf = PDFDocument(url: url),
                  let page = pdf.page(at: pageIndex) else { return false }
            let currentText = ExtractedTextNormalizer.normalize(page.string ?? "")
            let previousText = pageIndex > 0
                ? ExtractedTextNormalizer.normalize(pdf.page(at: pageIndex - 1)?.string ?? "")
                : ""
            return ReadingVisualEvidence.requiresPageImage(
                currentText: currentText,
                previousText: previousText
            )
        }.value
    }

    var body: some View {
        Group {
            // 自然分栏，永不遮挡：宽窗口左右（PDF | 面板），窄窗口上下（PDF 上 / 面板下）。
            if router.inspectorFloats {
                verticalWorkspace
            } else {
                horizontalWorkspace
            }
        }
        .task(id: document.id) {
            chapters = []
            isLoadingChapters = true
            defer {
                if !Task.isCancelled {
                    isLoadingChapters = false
                }
            }
            // 打开 PDF 时优先读取原生 outline；扫描版没有 outline 时，再在后台
            // OCR 前面的目录页并校正印刷页码偏移。两条路径都只在这里做一次，
            // 不把目录识别混进每次提问的等待。
            let outlineEntries = await Task.detached(priority: .utility) {
                OutlinePageMatcher.allEntries(url: url)
            }.value
            guard !Task.isCancelled else { return }
            if outlineEntries.isEmpty {
                // A text PDF without a native outline should not pay the
                // scanned-book OCR cost. Use the reading-space directory as a
                // local fallback; reserve bounded OCR for scan-like books.
                guard document.contentKind == .scanned || document.contentKind == .mixed else {
                    chapters = Self.makeChapters(entries: [], directory: course.learningDirectory)
                    return
                }
                let scannedEntries = await Task.detached(priority: .utility) {
                    await ScannedOutlineExtractor.entries(url: url)
                }.value
                guard !Task.isCancelled else { return }
                chapters = scannedEntries.isEmpty
                    ? Self.makeChapters(entries: [], directory: course.learningDirectory)
                    : Self.makeScannedChapters(entries: scannedEntries)
            } else {
                chapters = Self.makeChapters(entries: outlineEntries, directory: course.learningDirectory)
                await linkDirectoryPages(entries: outlineEntries)
            }
        }
        .task(id: "visual-\(url.standardizedFileURL.path)-\(currentPageIndex)") {
            let hasVisualEvidence = await Self.pageHasVisualEvidence(
                at: currentPageIndex,
                in: url
            )
            guard !Task.isCancelled else { return }
            currentPageHasVisualEvidence = hasVisualEvidence
        }
        .task(id: "printed-pages-\(url.standardizedFileURL.path)") {
            guard document.contentKind == .text else {
                nativePrintedPages = [:]
                return
            }
            let mapping = await Task.detached(priority: .utility) {
                NativePrintedPageExtractor.mapping(url: url)
            }.value
            guard !Task.isCancelled else { return }
            nativePrintedPages = mapping
        }
        .task(id: document.id) {
            // 这本书一被打开就记住「课程 + 书」，重启后回到同一本；
            // 不依赖用户点书单菜单（只读书不切书时也要能记住）。
            store.rememberOpenedDocument(courseID: course.id, documentID: document.id)
        }
        .onDisappear {
            scannedSearchTask?.cancel()
            scannedSearchTask = nil
        }
        .onChange(of: showsInspector) { _, visible in
            UserDefaults.standard.set(visible, forKey: Self.inspectorVisibleKey)
        }
        .onChange(of: currentPageIndex) { _, _ in
            isRegionCaptureEnabled = false
            currentPageHasVisualEvidence = false
        }
    }

    // MARK: 面板几何与开关的记忆

    private static let inspectorVisibleKey = "satori.workspace.inspectorVisible"
    private static let storedInspectorVisible = UserDefaults.standard.object(forKey: inspectorVisibleKey) as? Bool ?? true

    /// 每本书单独记住分隔条拖出来的面板宽/高；取不到时用默认值。
    private static func storedPanelWidth(for documentID: UUID) -> CGFloat {
        storedPanelSize(for: "satori.workspace.panelWidth.\(documentID.uuidString)", default: 430)
    }

    private static func storedPanelHeight(for documentID: UUID) -> CGFloat {
        storedPanelSize(for: "satori.workspace.panelHeight.\(documentID.uuidString)", default: 320)
    }

    private static func storedPanelSize(for key: String, default fallback: CGFloat) -> CGFloat {
        guard let stored = UserDefaults.standard.object(forKey: key) as? Double else { return fallback }
        return CGFloat(stored)
    }

    /// 章节来源：优先 PDF 自带 outline；没有 outline 时回退到这个阅读空间的目录里
    /// 已关联页码的章节项；两者都没有则返回空（阅读栏不显示目录）。
    private static func makeChapters(
        entries: [(title: String, pageIndex: Int, depth: Int, normalizedOffset: Double?)],
        directory: [LearningDirectoryItem]
    ) -> [BookChapter] {
        if !entries.isEmpty {
            return entries.enumerated().map {
                BookChapter(
                    id: $0.offset,
                    title: $0.element.title,
                    pageIndex: $0.element.pageIndex,
                    depth: $0.element.depth,
                    printedPage: nil,
                    normalizedOffset: $0.element.normalizedOffset
                )
            }
        }
        return directory.compactMap { item -> (title: String, pageIndex: Int)? in
            guard let pageIndex = item.pageIndex else { return nil }
            return (item.title, pageIndex)
        }
        .enumerated()
        .map {
            BookChapter(id: $0.offset, title: $0.element.title, pageIndex: $0.element.pageIndex, depth: 0, printedPage: nil, normalizedOffset: nil)
        }
    }

    private static func makeScannedChapters(
        entries: [(title: String, pageIndex: Int, depth: Int, printedPage: Int, normalizedOffset: Double?)]
    ) -> [BookChapter] {
        entries.enumerated().map {
            BookChapter(
                id: $0.offset,
                title: $0.element.title,
                pageIndex: $0.element.pageIndex,
                depth: $0.element.depth,
                printedPage: $0.element.printedPage,
                normalizedOffset: $0.element.normalizedOffset
            )
        }
    }

    /// 当前页所属的章节：最后一个起始页 ≤ 当前页的章节。
    private var currentChapter: BookChapter? {
        chapters.last { chapterIsAtOrBeforeCurrent($0) }
    }

    /// Keep the top-level chapter visible while a section title is selected.
    /// On a long textbook page, the section alone is not enough orientation.
    private var currentTopLevelChapter: BookChapter? {
        chapters.last { $0.depth == 0 && chapterIsAtOrBeforeCurrent($0) }
    }

    private func chapterIsAtOrBeforeCurrent(_ chapter: BookChapter) -> Bool {
        ReadingPositionOrdering.isAtOrBefore(
            pageIndex: chapter.pageIndex,
            normalizedOffset: chapter.normalizedOffset,
            currentPageIndex: currentPageIndex,
            currentNormalizedOffset: currentOffset
        )
    }

    /// Prefer a direct native-text mapping; scan-like books carry the
    /// printed-page number forward from the most recent mapped chapter/section.
    /// Front matter has no reliable printed body-page mapping, so it keeps the
    /// normal PDF-only indicator.
    private var currentPrintedPage: Int? {
        printedPage(for: currentPageIndex)
    }

    private func printedPage(for pageIndex: Int) -> Int? {
        if let nativePrintedPage = nativePrintedPages[pageIndex] {
            return nativePrintedPage
        }
        guard document.contentKind == .scanned || document.contentKind == .mixed,
              let anchor = chapters.last(where: {
                  $0.printedPage != nil && $0.pageIndex <= pageIndex
              }),
              let printedPage = anchor.printedPage else { return nil }
        return printedPage + (pageIndex - anchor.pageIndex)
    }

    private func persistPanelSize() {
        UserDefaults.standard.set(Double(panelWidth), forKey: "satori.workspace.panelWidth.\(document.id.uuidString)")
        UserDefaults.standard.set(Double(panelHeight), forKey: "satori.workspace.panelHeight.\(document.id.uuidString)")
    }

    /// 用当前 PDF 的 outline 补齐课程目录项缺失的页码并持久化。
    /// 全部已关联（此前已持久化）或 PDF 没有 outline 时直接跳过，保持现状。
    private func linkDirectoryPages(entries: [(title: String, pageIndex: Int, depth: Int, normalizedOffset: Double?)]) async {
        let directory = course.learningDirectory
        guard !directory.isEmpty,
              directory.contains(where: { $0.pageIndex == nil }),
              !entries.isEmpty else { return }
        let titles = directory.map(\.title)
        let linked = OutlinePageMatcher.linkedPageIndices(titles: titles, entries: entries)
        guard !linked.allSatisfy({ $0 == nil }), !Task.isCancelled else { return }

        var updated = store.plan
        guard let courseIndex = updated.courses.firstIndex(where: { $0.id == course.id }) else { return }
        let currentDirectory = updated.courses[courseIndex].learningDirectory
        guard currentDirectory.count == linked.count else { return }
        var changed = false
        let newDirectory = zip(currentDirectory, linked).map { item, pageIndex -> LearningDirectoryItem in
            guard let pageIndex, pageIndex != item.pageIndex else { return item }
            changed = true
            return item.withPageIndex(pageIndex)
        }
        guard changed else { return }
        updated.courses[courseIndex].learningDirectory = newDirectory
        do {
            try await LearningPlanStore().save(updated)
            await store.load()
            store.save()
        } catch {
            // 持久化失败只影响下次启动的恢复，不阻塞当前阅读。
        }
    }

    /// 宽窗口：PDF 在左，面板在右，中间分隔条可拖调宽度。
    private var horizontalWorkspace: some View {
        HStack(spacing: 0) {
            readerColumn
            if showsInspector && !router.isImmersiveReading {
                divider
                LearningInspector(
                    documentID: document.id,
                    pageIndex: currentPageIndex,
                    currentPageOffset: currentOffset,
                    pageCount: pageCount,
                    documentURL: url,
                    chapters: chapters,
                    printedPageForPage: { pageIndex in printedPage(for: pageIndex) },
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

    /// 窄窗口：PDF 在上，面板在下，横向分隔条可拖调高度；互不遮挡。
    private var verticalWorkspace: some View {
        VStack(spacing: 0) {
            readerColumn
            if showsInspector && !router.isImmersiveReading {
                panelHeightDivider
                LearningInspector(
                    documentID: document.id,
                    pageIndex: currentPageIndex,
                    currentPageOffset: currentOffset,
                    pageCount: pageCount,
                    documentURL: url,
                    chapters: chapters,
                    printedPageForPage: { pageIndex in printedPage(for: pageIndex) },
                    onNavigateToPage: { targetPage in
                        currentPageIndex = min(max(targetPage, 0), pageCount - 1)
                    },
                    onClose: { showsInspector = false }
                )
                .frame(height: panelHeight)
            }
        }
    }

    /// 阅读栏 + PDF，上下两种布局共用同一份阅读区。
    private var readerColumn: some View {
        VStack(spacing: 0) {
            readingBar
            Divider()
            ZStack {
                PDFReaderView(
                    documentID: document.id,
                    url: url,
                    // 用实时位置而非持久化快照：窄/宽布局切换会重建 PDFReaderView，
                    // 此时持久化值可能落后于用户当前页，回退到旧页会丢进度。
                    initialPosition: ReadingPosition(
                        pageIndex: currentPageIndex,
                        normalizedPageOffset: currentOffset
                    ),
                    currentPageIndex: $currentPageIndex,
                    isRegionCaptureEnabled: $isRegionCaptureEnabled,
                    onPositionChanged: { pageIndex, offset in
                        currentOffset = offset
                        store.updateReadingPosition(
                            courseID: course.id,
                            documentID: document.id,
                            pageIndex: pageIndex,
                            normalizedOffset: offset
                        )
                    },
                    onPageRegionCaptured: { jpegData, pageIndex, anchor in
                        isRegionCaptureEnabled = false
                        NotificationCenter.default.post(
                            name: .satoriPageRegionCaptured,
                            object: nil,
                            userInfo: [
                                "documentID": document.id,
                                "url": url,
                                "pageIndex": pageIndex,
                                "jpegData": jpegData,
                                "anchor": anchor
                            ]
                        )
                    },
                    onSearchResult: { matchIndex, matchCount in
                        if matchCount == 0 {
                            switch document.contentKind {
                            case .scanned:
                                startScannedSearch()
                            case .mixed:
                                startScannedSearch()
                            default:
                                searchNotice = "没有找到“\(searchQuery)”。"
                            }
                        } else {
                            searchNotice = "第 \(matchIndex) / \(matchCount) 处"
                        }
                    }
                )

                if showsTOC, !chapters.isEmpty {
                    TOCDrawer(
                        chapters: chapters,
                        currentChapterID: currentChapter?.id,
                        pageCount: pageCount,
                        printedPageForPage: { pageIndex in printedPage(for: pageIndex) },
                        onJump: { chapter in
                            jump(to: chapter)
                        },
                        onClose: { showsTOC = false }
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(2)
                }
            }
            .animation(SatoriTheme.Motion.quick, value: showsTOC)
        }
        .frame(minWidth: 620)
        .frame(maxWidth: .infinity)
    }

    private func jump(to chapter: BookChapter) {
        let targetPage = min(max(chapter.pageIndex, 0), pageCount - 1)
        let targetOffset = min(max(chapter.normalizedOffset ?? 0, 0), 1)
        currentPageIndex = targetPage
        currentOffset = targetOffset
        pageInput = ""
        NotificationCenter.default.post(
            name: .satoriReaderJumpRequested,
            object: nil,
            userInfo: [
                "documentID": document.id,
                "url": url,
                "position": ReadingPosition(
                    pageIndex: targetPage,
                    normalizedPageOffset: targetOffset
                )
            ]
        )
        showsTOC = false
    }

    /// 窄窗口面板高度分隔条：横向可拖，实时调整下面板高度（200-520pt）。
    private var panelHeightDivider: some View {
        Rectangle()
            .fill(isDraggingHeightDivider ? SatoriTheme.accent.opacity(0.35) : Color.primary.opacity(0.08))
            .frame(height: isDraggingHeightDivider ? 7 : 5)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDraggingHeightDivider = true
                        let proposed = panelHeight - value.translation.height
                        panelHeight = min(max(proposed, 200), 520)
                    }
                    .onEnded { _ in
                        isDraggingHeightDivider = false
                        persistPanelSize()
                    }
            )
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
                        persistPanelSize()
                    }
            )
    }

    private var readingBar: some View {
        HStack(spacing: 14) {
            if !router.isImmersiveReading {
                documentMenu
            }

            if !chapters.isEmpty {
                tocButton
            }

            if isLoadingChapters, !router.isImmersiveReading {
                Label(
                    document.contentKind == .scanned ? "正在识别目录" : "正在读取目录",
                    systemImage: "ellipsis.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .transition(.opacity)
            }

            Spacer(minLength: 8)

            HStack(spacing: 7) {
                Button("上一页", systemImage: "chevron.left") {
                    currentPageIndex = max(0, currentPageIndex - 1)
                }
                .labelStyle(.iconOnly)
                .disabled(currentPageIndex == 0)

                if let currentPrintedPage {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("PDF \(currentPageIndex + 1) / \(pageCount)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                        Text("书内 \(currentPrintedPage)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize()
                    .help("PDF 页码与教材印刷页码")
                } else {
                    Text("\(currentPageIndex + 1)")
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .frame(minWidth: 30, alignment: .trailing)
                        .fixedSize()
                    Text("/ \(pageCount)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }

                Button("下一页", systemImage: "chevron.right") {
                    currentPageIndex = min(pageCount - 1, currentPageIndex + 1)
                }
                .labelStyle(.iconOnly)
                .disabled(currentPageIndex >= pageCount - 1)

                Divider().frame(height: 18)

                TextField(currentPrintedPage == nil ? "页码" : "PDF页", text: $pageInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                    .onSubmit(jumpToPage)
                    .accessibilityLabel(currentPrintedPage == nil ? "跳转页码" : "跳转 PDF 页码")
                Button("跳转", action: jumpToPage)
                    .disabled(Int(pageInput) == nil)
            }

            Spacer(minLength: 8)

            Button {
                searchNotice = ""
                isSearchPresented = true
                isSearchFieldFocused = true
            } label: {
                if router.inspectorFloats {
                    Image(systemName: "magnifyingglass")
                } else {
                    Label("查找", systemImage: "magnifyingglass")
                }
            }
            .keyboardShortcut("f", modifiers: .command)
            .popover(isPresented: $isSearchPresented, arrowEdge: .bottom) {
                pdfSearchPopover
            }
            .accessibilityLabel("查找")
            .help("在这本书中查找（⌘F）")

            if !router.isImmersiveReading {
                Button {
                    showsInspector.toggle()
                } label: {
                    if router.inspectorFloats {
                        Image(systemName: "sparkles.rectangle.stack")
                    } else {
                        Label(showsInspector ? "隐藏理解" : "打开理解", systemImage: "sparkles.rectangle.stack")
                    }
                }
                .accessibilityLabel(showsInspector ? "隐藏理解" : "打开理解")
                .help(showsInspector ? "隐藏理解面板" : "打开理解面板")
                .tint(SatoriTheme.accent)
            }

            if document.contentKind == .scanned
                || document.contentKind == .mixed
                || currentPageHasVisualEvidence {
                Button {
                    isRegionCaptureEnabled.toggle()
                } label: {
                    if router.inspectorFloats {
                        Image(systemName: isRegionCaptureEnabled ? "xmark" : "viewfinder")
                    } else {
                        Label(
                            isRegionCaptureEnabled ? "取消框选" : "框选理解",
                            systemImage: isRegionCaptureEnabled ? "xmark" : "viewfinder"
                        )
                    }
                }
                .accessibilityLabel(isRegionCaptureEnabled ? "取消框选" : "框选理解")
                .help(isRegionCaptureEnabled ? "取消框选（Esc）" : "拖住图、表或公式的一块区域，直接问 Satori")
                .tint(isRegionCaptureEnabled ? SatoriTheme.gold : SatoriTheme.accent)
            }

            Button {
                router.isImmersiveReading.toggle()
            } label: {
                if router.inspectorFloats {
                    Image(systemName: router.isImmersiveReading ? "arrow.down.right.and.arrow.up.left" : "viewfinder")
                } else {
                    Label(
                        router.isImmersiveReading ? "退出沉浸" : "沉浸阅读",
                        systemImage: router.isImmersiveReading ? "arrow.down.right.and.arrow.up.left" : "viewfinder"
                    )
                }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .accessibilityLabel(router.isImmersiveReading ? "退出沉浸" : "沉浸阅读")
            .help(router.isImmersiveReading ? "退出沉浸阅读（⌘⇧F）" : "进入沉浸阅读（⌘⇧F）")
            .tint(router.isImmersiveReading ? SatoriTheme.gold : SatoriTheme.accent)
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .background(router.isImmersiveReading ? SatoriTheme.paper : Color(nsColor: .windowBackgroundColor))
    }

    private var pdfSearchPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("在这本书中查找")
                .font(.headline)
            HStack(spacing: 6) {
                TextField("术语、标题或文件名", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .focused($isSearchFieldFocused)
                    .onSubmit { requestSearch(direction: 1) }
                Button("上一个", systemImage: "chevron.up") {
                    requestSearch(direction: -1)
                }
                .labelStyle(.iconOnly)
                .help("上一个匹配")
                Button("下一个", systemImage: "chevron.down") {
                    requestSearch(direction: 1)
                }
                .labelStyle(.iconOnly)
                .help("下一个匹配")
            }
            if !searchNotice.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(
                        searchNotice,
                        systemImage: isScannedSearching
                            ? "hourglass"
                            : (searchNotice.hasPrefix("没有") || searchNotice.hasPrefix("整本书")
                               ? "info.circle" : "text.magnifyingglass")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    if isScannedSearching {
                        Button("取消") { cancelScannedSearch() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
            Text(document.contentKind == .scanned
                 ? "扫描书会在普通查找失败后，用本地 OCR 找文字；找图、公式或代码请用“框选理解”。"
                 : "Enter 查找下一处 · 从当前页继续查找")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 330)
        .onAppear {
            DispatchQueue.main.async {
                isSearchFieldFocused = true
            }
        }
        .onDisappear {
            if isScannedSearching { cancelScannedSearch() }
        }
    }

    private func requestSearch(direction: Int) {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchNotice = "先输入要查找的内容。"
            return
        }
        searchDirection = direction < 0 ? -1 : 1
        scannedSearchTask?.cancel()
        isScannedSearching = false
        if scannedSearchQuery != query {
            scannedSearchQuery = query
            scannedSearchHasSearched = false
        }
        searchNotice = "正在查找…"
        NotificationCenter.default.post(
            name: .satoriReaderSearchRequested,
            object: nil,
            userInfo: [
                "documentID": document.id,
                "url": url,
                "query": query,
                "direction": direction
            ]
        )
    }

    /// PDFKit has no index for scanned pages. Start local OCR only after the
    /// native search path misses, and keep the result in memory for the next
    /// “上一个/下一个” action. The first query includes the current page;
    /// repeated searches continue one page past the last hit.
    private func startScannedSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isScannedSearching else { return }

        let direction = searchDirection
        let isFirstSearch = !scannedSearchHasSearched || scannedSearchQuery != query
        let startPage = isFirstSearch
            ? currentPageIndex
            : currentPageIndex + (direction > 0 ? 1 : -1)
        scannedSearchQuery = query
        scannedSearchHasSearched = true
        isScannedSearching = true
        searchNotice = "扫描书没有文字索引，正在本地查找…"

        scannedSearchTask?.cancel()
        let targetURL = url
        scannedSearchTask = Task { @MainActor in
            let result = await ScannedPDFSearch.find(
                query: query,
                in: targetURL,
                startingAt: startPage,
                direction: direction
            )
            guard !Task.isCancelled else { return }
            isScannedSearching = false
            if let result {
                currentPageIndex = result.pageIndex
                let wrapText = result.wrapped ? "（已从头继续查找）" : ""
                let printedText = printedPage(for: result.pageIndex).map { " · 书内第 \($0) 页" } ?? ""
                searchNotice = "找到 PDF 第 \(result.pageIndex + 1) 页\(printedText) · 本地 OCR\(wrapText)"
            } else {
                searchNotice = "整本书暂时没有找到“\(query)”；可以换个词，或用“框选理解”。"
            }
        }
    }

    private func cancelScannedSearch() {
        scannedSearchTask?.cancel()
        scannedSearchTask = nil
        isScannedSearching = false
        searchNotice = "已取消查找。"
    }

    /// 目录按钮：常驻显示当前章节，点击（或按 ⌘T）呼出可跳转任意章节/小节的浮层。
    private var tocButton: some View {
        Button {
            showsTOC.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "list.bullet.indent")
                    .foregroundStyle(SatoriTheme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(currentTopLevelChapter?.title ?? currentChapter?.title ?? "目录")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if let section = currentChapter,
                       section.id != currentTopLevelChapter?.id {
                        Text(section.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(SatoriTheme.accentWash, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("t", modifiers: .command)
        .frame(maxWidth: 180, alignment: .leading)
        .help(currentTopLevelChapter.map { chapter in
            let section = currentChapter.map { " · \($0.title)" } ?? ""
            return "目录（⌘T）· 当前章节：\(chapter.title)\(section)"
        } ?? "目录（⌘T）")
    }

    private var documentMenu: some View {
        Menu {
            Section("这个阅读空间里的 PDF") {
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
        .help("切换或管理这个阅读空间里的 PDF")
    }

    private func jumpToPage() {
        guard let requestedPage = Int(pageInput) else { return }
        currentPageIndex = min(max(requestedPage - 1, 0), pageCount - 1)
        pageInput = ""
    }
}

/// 目录快速跳转浮层：右侧抽屉列出全书章节/小节（按大纲层级缩进），
/// 当前所在位置高亮并自动滚动到视野内；点击任意一项跳转并关闭，点遮罩或 Esc 关闭。
private struct TOCDrawer: View {
    let chapters: [BookChapter]
    let currentChapterID: Int?
    let pageCount: Int
    let printedPageForPage: (Int) -> Int?
    let onJump: (BookChapter) -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // 左侧遮罩：点击 PDF 区域关闭浮层。
            Color.black.opacity(0.10)
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)

            VStack(spacing: 0) {
                header
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(chapters) { chapter in
                                row(chapter)
                                    .id(chapter.id)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .onAppear {
                        if let currentChapterID {
                            withAnimation(SatoriTheme.Motion.quick) {
                                proxy.scrollTo(currentChapterID, anchor: .center)
                            }
                        }
                    }
                }
            }
            .frame(width: 300)
            .background(SatoriTheme.paperRaised)
            .overlay(alignment: .leading) { Divider() }
        }
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        HStack(spacing: SatoriTheme.Spacing.sm) {
            Text("目录")
                .font(.headline)
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭目录（Esc）")
        }
        .padding(.horizontal, SatoriTheme.Spacing.md)
        .padding(.vertical, SatoriTheme.Spacing.sm)
    }

    private func row(_ chapter: BookChapter) -> some View {
        let isCurrent = chapter.id == currentChapterID
        return Button {
            onJump(chapter)
        } label: {
            HStack(spacing: 7) {
                if isCurrent {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(SatoriTheme.accent)
                        .frame(width: 12)
                } else {
                    Color.clear.frame(width: 12, height: 1)
                }
                Text(chapter.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isCurrent ? SatoriTheme.accent : Color.primary)
                Spacer(minLength: 4)
                Text(pageRangeLabel(chapter))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 10 + CGFloat(min(chapter.depth, 4)) * 14)
            .padding(.trailing, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(isCurrent ? SatoriTheme.accentWash.opacity(0.65) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private func pageRangeLabel(_ chapter: BookChapter) -> String {
        let mappedPrintedPage = printedPageForPage(chapter.pageIndex)
        if let range = BookChapter.pageRange(for: chapter, in: chapters, pageCount: pageCount) {
            let pdfLabel = "\(range.lowerBound + 1)–\(range.upperBound + 1)"
            if let printedPage = mappedPrintedPage ?? chapter.printedPage {
                return "PDF \(pdfLabel) · 书内 \(printedPage)"
            }
            return pdfLabel
        }
        if let printedPage = mappedPrintedPage ?? chapter.printedPage {
            return "PDF \(chapter.pageIndex + 1) · 书内 \(printedPage)"
        }
        return "\(chapter.pageIndex + 1)"
    }
}

/// Native textbook PDFs often keep the printed page number as a standalone
/// text line while PDFKit's page index also counts covers and front matter.
/// Read only edge lines and accept a map only after several pages agree on a
/// one-page-to-one-page progression; equations and numbered lists stay out.
private enum NativePrintedPageExtractor {
    static func mapping(url: URL) -> [Int: Int] {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        guard let document = PDFDocument(url: url), document.pageCount > 0 else { return [:] }
        let candidates = (0..<document.pageCount).map { pageIndex in
            candidate(from: document.page(at: pageIndex)?.string ?? "")
        }
        return PrintedPageMapping.map(from: candidates)
    }

    private static func candidate(from text: String) -> Int? {
        let lines = text.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !lines.isEmpty else { return nil }

        let edgeLines = lines.enumerated().filter { index, _ in
            index < 4 || index >= max(0, lines.count - 4)
        }
        return edgeLines.compactMap { entry -> Int? in
            let line = entry.element
            guard let number = Int(line), (1...4_000).contains(number) else { return nil }
            return number
        }.first
    }
}

/// Scanned books often have a usable table of contents but no PDF outline.
/// Read only the front matter plus a bounded body window to discover the
/// printed-to-PDF page offset; this keeps opening a scanned book local and
/// bounded instead of sending its whole book to Qwen just to build navigation.
private enum ScannedOutlineExtractor {
    private struct RecognizedLine: Sendable {
        let text: String
        let normalizedOffset: Double
    }

    private struct RecognizedPage: Sendable {
        let pageIndex: Int
        let text: String
        let lines: [RecognizedLine]
    }

    private struct CachedEntry: Codable {
        let title: String
        let pageIndex: Int
        let depth: Int
        let printedPage: Int
        let normalizedOffset: Double?

        init(title: String, pageIndex: Int, depth: Int = 0, printedPage: Int, normalizedOffset: Double? = nil) {
            self.title = title
            self.pageIndex = pageIndex
            self.depth = depth
            self.printedPage = printedPage
            self.normalizedOffset = normalizedOffset
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decode(String.self, forKey: .title)
            pageIndex = try container.decode(Int.self, forKey: .pageIndex)
            depth = try container.decodeIfPresent(Int.self, forKey: .depth) ?? 0
            printedPage = try container.decodeIfPresent(Int.self, forKey: .printedPage) ?? 0
            normalizedOffset = try container.decodeIfPresent(Double.self, forKey: .normalizedOffset)
        }

        private enum CodingKeys: String, CodingKey {
            case title, pageIndex, depth, printedPage, normalizedOffset
        }
    }

    static func entries(url: URL) async -> [(title: String, pageIndex: Int, depth: Int, printedPage: Int, normalizedOffset: Double?)] {
        let cacheKey = cacheKey(for: url)
        if let cached = cachedEntries(for: cacheKey) {
            return cached.map { ($0.title, $0.pageIndex, $0.depth, $0.printedPage, $0.normalizedOffset) }
        }

        guard let document = PDFDocument(url: url), document.pageCount > 0 else { return [] }
        let tocEnd = min(document.pageCount, 20)
        let tocPages = await recognizePages(document: document, indices: Array(0..<tocEnd))
        let parsed = ScannedOutlineParser.keepCoherentChapterRun(
            ScannedOutlineParser.parseHierarchy(
            lines: tocPages.flatMap { $0.text.split(whereSeparator: \.isNewline).map(String.init) }
            )
        )
        guard let first = parsed.first(where: { $0.depth == 0 }) else { return [] }

        // The first numbered chapter is usually within the first 50 pages,
        // but keep a little headroom for long prefaces and exam outlines.
        let searchEnd = min(document.pageCount, max(48, min(96, first.printedPage + 40)))
        guard searchEnd > tocEnd else { return [] }
        let bodyPages = await recognizePages(
            document: document,
            indices: Array(tocEnd..<searchEnd)
        )
        let titleToken = searchable(first.title)
        let chapterToken = searchable("第\(first.chapterNumber)章")
        // OCR may drop a heading's title (the real scanned language textbook
        // does this on its first chapter), while still recognizing the chapter
        // marker. Prefer a line that starts with that marker so a preface
        // sentence such as “全书共分为十章。第一章……” is not mistaken for
        // the actual chapter page.
        let firstChapterPage = bodyPages.first(where: { page in
            page.text
                .split(whereSeparator: \.isNewline)
                .map { searchable(String($0)) }
                .contains { $0.hasPrefix(chapterToken) }
        })?.pageIndex ?? bodyPages.first(where: {
            titleToken.count >= 2 && searchable($0.text).contains(titleToken)
        })?.pageIndex
        guard let firstChapterPage else {
            return []
        }

        // Printed page 25 on PDF page 30 means the body offset is +5. Apply
        // that stable offset to every chapter number recovered from the TOC.
        let bodyPrintedPage = bodyPages.first(where: { $0.pageIndex == firstChapterPage })
            .flatMap { printedPageNumber(in: $0.lines) }
        let offset = bodyPrintedPage.map {
            firstChapterPage - ($0 - 1)
        } ?? firstChapterPage - (first.printedPage - 1)
        // The OCR window may contain chapter summaries from a preface. Once
        // the first real body page gives us a stable PDF/printed-page offset,
        // discard every heading that would still land before that page.
        let bodyEntries = ScannedOutlineParser.keepMappedEntries(
            parsed,
            printedPageOffset: offset,
            minimumPageIndex: firstChapterPage
        )
        let bodyPagesByIndex = Dictionary(uniqueKeysWithValues: bodyPages.map { ($0.pageIndex, $0) })
        let mapped = bodyEntries.compactMap { entry -> CachedEntry? in
            let pageIndex = entry.printedPage - 1 + offset
            guard (0..<document.pageCount).contains(pageIndex) else { return nil }
            let title: String
            if let sectionNumber = entry.sectionNumber {
                title = "第\(sectionNumber)节 \(entry.title)"
            } else {
                title = "第\(entry.chapterNumber)章 \(entry.title)"
            }
            let titleOffset = bodyPagesByIndex[pageIndex].flatMap {
                normalizedOffset(for: title, in: $0.lines)
            }
            return CachedEntry(
                title: title,
                pageIndex: pageIndex,
                depth: entry.depth,
                printedPage: entry.printedPage,
                normalizedOffset: titleOffset
            )
        }
        guard !mapped.isEmpty else { return [] }
        save(mapped, for: cacheKey)
        return mapped.map { ($0.title, $0.pageIndex, $0.depth, $0.printedPage, $0.normalizedOffset) }
    }

    /// Vision OCR is CPU-heavy but each page is independent. Keep a small
    /// bounded window so opening a scanned book is materially faster without
    /// flooding the machine or changing the recovered reading order.
    private static func recognizePages(
        document: PDFDocument,
        indices: [Int]
    ) async -> [RecognizedPage] {
        guard !indices.isEmpty else { return [] }
        let documentBox = ScannedPDFDocumentBox(document: document)
        var results: [RecognizedPage] = []
        results.reserveCapacity(indices.count)

        await withTaskGroup(of: RecognizedPage?.self) { group in
            var iterator = indices.makeIterator()
            let concurrency = min(4, indices.count)

            func addNext() {
                guard let index = iterator.next() else { return }
                group.addTask {
                    guard let page = documentBox.document.page(at: index),
                          let recognized = recognize(page: page),
                          !recognized.text.isEmpty else {
                        return nil
                    }
                    return RecognizedPage(pageIndex: index, text: recognized.text, lines: recognized.lines)
                }
            }

            for _ in 0..<concurrency {
                addNext()
            }
            while let result = await group.next() {
                if let result {
                    results.append(result)
                }
                addNext()
            }
        }
        return results.sorted { $0.pageIndex < $1.pageIndex }
    }

    private static func recognize(page: PDFPage) -> (text: String, lines: [RecognizedLine])? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = 1_600 / max(bounds.width, bounds.height)
        let image = page.thumbnail(
            of: NSSize(width: bounds.width * scale, height: bounds.height * scale),
            for: .mediaBox
        )
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        let observations = request.results ?? []
        // A scanned table of contents is commonly two columns. Sorting the
        // whole page by y/x interleaves “第一章 …” with “第四章 …”; split
        // columns first, then rebuild reading lines inside each column.
        func lines(in column: [VNRecognizedTextObservation]) -> [RecognizedLine] {
            let sorted = column.sorted { lhs, rhs in
                let dy = lhs.boundingBox.midY - rhs.boundingBox.midY
                return abs(dy) > 0.02 ? dy > 0 : lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            var result: [RecognizedLine] = []
            var currentY: CGFloat?
            for observation in sorted {
                guard let candidate = observation.topCandidates(1).first?.string,
                      !candidate.isEmpty else { continue }
                // At this render scale adjacent OCR rows are about 0.02 apart,
                // while fragments from one row stay within roughly 0.001.
                // A wider threshold silently glues a chapter to its first
                // section and makes the chapter disappear from the parser.
                let normalizedOffset = min(max(1 - Double(observation.boundingBox.midY), 0), 1)
                if let currentY, abs(observation.boundingBox.midY - currentY) <= 0.01,
                   !result.isEmpty {
                    let previous = result[result.count - 1]
                    result[result.count - 1] = RecognizedLine(
                        text: previous.text + " " + candidate,
                        normalizedOffset: (previous.normalizedOffset + normalizedOffset) / 2
                    )
                } else {
                    result.append(RecognizedLine(text: candidate, normalizedOffset: normalizedOffset))
                    currentY = observation.boundingBox.midY
                }
            }
            return result
        }

        let left = observations.filter { $0.boundingBox.midX < 0.5 }
        let right = observations.filter { $0.boundingBox.midX >= 0.5 }
        let recognizedLines = lines(in: left) + lines(in: right)
        let text = recognizedLines.map(\.text).joined(separator: "\n")
        let normalized = ExtractedTextNormalizer.normalize(text)
        return normalized.isEmpty ? nil : (normalized, recognizedLines)
    }

    private static func normalizedOffset(for title: String, in lines: [RecognizedLine]) -> Double? {
        let target = searchable(title)
        guard target.count >= 2 else { return nil }
        let candidates = lines.filter { line in
            let value = searchable(line.text)
            return value.contains(target) || (target.contains(value) && value.count >= 2)
        }
        return candidates.min { lhs, rhs in
            abs(searchable(lhs.text).count - target.count)
                < abs(searchable(rhs.text).count - target.count)
        }?.normalizedOffset
    }

    private static func printedPageNumber(in lines: [RecognizedLine]) -> Int? {
        lines
            .filter { $0.normalizedOffset < 0.12 || $0.normalizedOffset > 0.88 }
            .compactMap { line -> Int? in
                let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let digits = trimmed.filter(\.isNumber)
                guard digits.count == trimmed.count,
                      let number = Int(digits), (1...4_000).contains(number) else { return nil }
                return number
            }
            .first
    }

    private static func searchable(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    private static func cacheKey(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modification = values?.contentModificationDate?.timeIntervalSince1970 ?? -1
        let size = values?.fileSize ?? -1
        return "satori.scanned-outline.v5|\(url.standardizedFileURL.path)|\(modification)|\(size)"
    }

    private static func cachedEntries(for key: String) -> [CachedEntry]? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode([CachedEntry].self, from: data)
    }

    private static func save(_ entries: [CachedEntry], for key: String) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// PDFKit is read-only in this path; the wrapper lets the bounded OCR tasks
/// access independent pages without pretending PDFDocument itself is Sendable.
private final class ScannedPDFDocumentBox: @unchecked Sendable {
    let document: PDFDocument

    init(document: PDFDocument) {
        self.document = document
    }
}

/// 从 PDF outline 提取「章节标题 → 页码」，把课程目录项关联到真实页码。
/// 标题按模糊包含匹配（去空白、忽略「第X章」等前缀）；匹配不到时按
/// outline 的书本顺序顺延到下一个节点。PDF 没有 outline 时返回全 nil。
private enum OutlinePageMatcher {
    /// PDF outline 的全部章节条目（按页码升序）；没有 outline 时返回空数组。
    static func allEntries(url: URL) -> [(title: String, pageIndex: Int, depth: Int, normalizedOffset: Double?)] {
        extractOutlineEntries(url: url)
    }

    /// 返回与输入目录标题一一对应的页索引；无匹配且无剩余 outline 节点时为 nil。
    static func linkedPageIndices(titles: [String], url: URL) -> [Int?] {
        linkedPageIndices(titles: titles, entries: extractOutlineEntries(url: url))
    }

    /// 返回与输入目录标题一一对应的页索引；无匹配且无剩余 outline 节点时为 nil。
    static func linkedPageIndices(
        titles: [String],
        entries: [(title: String, pageIndex: Int, depth: Int, normalizedOffset: Double?)]
    ) -> [Int?] {
        guard !entries.isEmpty else { return Array(repeating: nil, count: titles.count) }
        let normalized = entries.map { (normalize($0.title), $0.pageIndex) }
        var cursor = 0
        var result: [Int?] = []
        result.reserveCapacity(titles.count)
        for title in titles {
            let target = normalize(title)
            guard !target.isEmpty else {
                result.append(nil)
                continue
            }
            if let index = bestMatchIndex(for: target, in: normalized, from: cursor) {
                result.append(normalized[index].1)
                cursor = index + 1
            } else if cursor < normalized.count {
                // 退而求其次：按 outline 在书中的顺序映射到下一个节点。
                result.append(normalized[cursor].1)
                cursor += 1
            } else {
                result.append(nil)
            }
        }
        return result
    }

    private static func extractOutlineEntries(url: URL) -> [(title: String, pageIndex: Int, depth: Int, normalizedOffset: Double?)] {
        guard let pdf = PDFDocument(url: url), let root = pdf.outlineRoot else { return [] }
        var entries: [(title: String, pageIndex: Int, depth: Int, normalizedOffset: Double?)] = []
        collectOutline(root, in: pdf, depth: 0, into: &entries)
        return entries.enumerated().sorted { lhs, rhs in
            if lhs.element.pageIndex != rhs.element.pageIndex {
                return lhs.element.pageIndex < rhs.element.pageIndex
            }
            switch (lhs.element.normalizedOffset, rhs.element.normalizedOffset) {
            case let (left?, right?) where abs(left - right) > 0.001:
                return left < right
            default:
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    private static func collectOutline(
        _ node: PDFOutline,
        in pdf: PDFDocument,
        depth: Int,
        into entries: inout [(title: String, pageIndex: Int, depth: Int, normalizedOffset: Double?)]
    ) {
        let page = node.destination?.page ?? firstPage(of: node)
        if let page, let label = node.label, !label.isEmpty {
            let offset = normalizedOffset(for: label, page: page, in: pdf)
                ?? destinationOffset(node.destination, page: page)
            entries.append((label, pdf.index(for: page), depth, offset))
        }
        for index in 0..<node.numberOfChildren {
            if let child = node.child(at: index) {
                collectOutline(child, in: pdf, depth: depth + 1, into: &entries)
            }
        }
    }

    /// PDF outline destinations often point to the top of a page rather than
    /// the actual heading. Native text geometry is more useful for same-page
    /// sections, so prefer the heading's text bounds and fall back to the
    /// destination point when a publisher omitted the text layer match.
    private static func normalizedOffset(for label: String, page: PDFPage, in pdf: PDFDocument) -> Double? {
        let queries = [label, label.filter { !$0.isWhitespace }]
            .filter { !$0.isEmpty }
        var matches: [PDFSelection] = []
        let pageIndex = pdf.index(for: page)
        for query in queries {
            for match in pdf.findString(query, withOptions: [.literal])
                where match.pages.contains(where: { pdf.index(for: $0) == pageIndex }) {
                let isDuplicate = matches.contains { existing in
                    guard let existingPage = existing.pages.first,
                          let matchPage = match.pages.first else { return false }
                    return pdf.index(for: existingPage) == pdf.index(for: matchPage)
                        && existing.bounds(for: existingPage).insetBy(dx: -0.5, dy: -0.5)
                            .intersects(match.bounds(for: matchPage))
                }
                if !isDuplicate { matches.append(match) }
            }
        }
        guard let selection = matches.first,
              let matchPage = selection.pages.first else { return nil }
        let pageBounds = page.bounds(for: .mediaBox)
        let titleBounds = selection.bounds(for: matchPage)
        guard pageBounds.height > 0 else { return nil }
        return min(max((pageBounds.maxY - titleBounds.midY) / pageBounds.height, 0), 1)
    }

    private static func destinationOffset(_ destination: PDFDestination?, page: PDFPage) -> Double? {
        guard let destination, destination.page === page else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.height > 0 else { return nil }
        return min(max((bounds.maxY - destination.point.y) / bounds.height, 0), 1)
    }

    /// 没有 destination 的父节点取第一个带页码的后代页，保证「第X章」等父标题可匹配。
    private static func firstPage(of node: PDFOutline) -> PDFPage? {
        if let page = node.destination?.page { return page }
        for index in 0..<node.numberOfChildren {
            if let child = node.child(at: index), let page = firstPage(of: child) {
                return page
            }
        }
        return nil
    }

    /// 精确相等最优先，其次模糊包含；取标题最短的候选取代最贴合，保证书序单调。
    private static func bestMatchIndex(for target: String, in entries: [(title: String, pageIndex: Int)], from start: Int) -> Int? {
        var bestIndex: Int?
        var bestTitleLength = Int.max
        for index in start..<entries.count {
            let candidate = entries[index].title
            guard !candidate.isEmpty else { continue }
            if candidate == target {
                return index
            }
            let shorterSide = min(candidate.count, target.count)
            guard shorterSide >= 2,
                  candidate.contains(target) || target.contains(candidate),
                  candidate.count < bestTitleLength else { continue }
            bestIndex = index
            bestTitleLength = candidate.count
        }
        return bestIndex
    }

    /// 去空白、忽略「第X章/节/部分」等前缀，用于模糊标题匹配。
    private static func normalize(_ title: String) -> String {
        var result = title.lowercased().filter { !$0.isWhitespace }
        if result.hasPrefix("第") {
            var rest = result.dropFirst()
            while let first = rest.first, Self.isChapterNumber(first) {
                rest = rest.dropFirst()
            }
            if let first = rest.first, Self.isChapterUnit(first) {
                result = String(rest.dropFirst())
            }
        } else {
            for prefix in ["chapter", "chap", "unit", "part", "lesson", "ch"] {
                guard result.hasPrefix(prefix) else { continue }
                let rest = result.dropFirst(prefix.count)
                if let first = rest.first, Self.isChapterNumber(first) {
                    result = String(rest.drop(while: Self.isChapterNumber))
                    break
                }
            }
        }
        return result
    }

    private static func isChapterNumber(_ character: Character) -> Bool {
        character.isNumber || "一二三四五六七八九十百千万零〇两".contains(character)
    }

    private static func isChapterUnit(_ character: Character) -> Bool {
        "章节部分讲篇课".contains(character)
    }
}
