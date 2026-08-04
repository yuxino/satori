import AppKit
import PDFKit
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
    @State private var showsInspector = true
    /// 最近一次上报的页内偏移（0…1），随 onPositionChanged 更新；布局切换
    /// 重建 PDFReaderView 时用它恢复位置，避免回落到持久化里的旧页码。
    @State private var currentOffset: Double
    /// 宽窗口下面板宽度、窄窗口下面板高度；分隔条可拖调整，互不遮挡。
    @State private var panelWidth: CGFloat
    @State private var panelHeight: CGFloat
    @State private var isDraggingDivider = false
    @State private var isDraggingHeightDivider = false

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
            // 打开 PDF 时把课程目录项关联到书内 outline 的真实页码。
            await linkDirectoryPages()
        }
        .task(id: document.id) {
            // 这本书一被打开就记住「课程 + 书」，重启后回到同一本；
            // 不依赖用户点书单菜单（只读书不切书时也要能记住）。
            store.rememberOpenedDocument(courseID: course.id, documentID: document.id)
        }
        .onChange(of: showsInspector) { _, visible in
            UserDefaults.standard.set(visible, forKey: Self.inspectorVisibleKey)
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

    private func persistPanelSize() {
        UserDefaults.standard.set(Double(panelWidth), forKey: "satori.workspace.panelWidth.\(document.id.uuidString)")
        UserDefaults.standard.set(Double(panelHeight), forKey: "satori.workspace.panelHeight.\(document.id.uuidString)")
    }

    /// 用当前 PDF 的 outline 补齐课程目录项缺失的页码并持久化。
    /// 全部已关联（此前已持久化）或 PDF 没有 outline 时直接跳过，保持现状。
    private func linkDirectoryPages() async {
        let directory = course.learningDirectory
        guard !directory.isEmpty,
              directory.contains(where: { $0.pageIndex == nil }),
              let resolvedURL = DocumentBookmarkStore.resolveURL(for: document) else { return }
        let titles = directory.map(\.title)
        let linked = await Task.detached(priority: .utility) {
            OutlinePageMatcher.linkedPageIndices(titles: titles, url: resolvedURL)
        }.value
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

    /// 窄窗口：PDF 在上，面板在下，横向分隔条可拖调高度；互不遮挡。
    private var verticalWorkspace: some View {
        VStack(spacing: 0) {
            readerColumn
            if showsInspector {
                panelHeightDivider
                LearningInspector(
                    documentID: document.id,
                    pageIndex: currentPageIndex,
                    documentURL: url,
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
            PDFReaderView(
                url: url,
                // 用实时位置而非持久化快照：窄/宽布局切换会重建 PDFReaderView，
                // 此时持久化值可能落后于用户当前页，回退到旧页会丢进度。
                initialPosition: ReadingPosition(
                    pageIndex: currentPageIndex,
                    normalizedPageOffset: currentOffset
                ),
                currentPageIndex: $currentPageIndex,
                onPositionChanged: { pageIndex, offset in
                    currentOffset = offset
                    store.updateReadingPosition(
                        courseID: course.id,
                        documentID: document.id,
                        pageIndex: pageIndex,
                        normalizedOffset: offset
                    )
                    // Feed the progress bar: record this page as read.
                    Task {
                        do {
                            try await LearningStatsStore.shared.recordPageRead(
                                documentID: document.id,
                                pageIndex: pageIndex,
                                pageCount: document.pageCount
                            )
                            NotificationCenter.default.post(name: .learningStatsDidChange, object: nil)
                        } catch {
                            print("recordPageRead failed: \(error)")
                        }
                    }
                }
            )
        }
        .frame(minWidth: 620)
        .frame(maxWidth: .infinity)
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

/// 从 PDF outline 提取「章节标题 → 页码」，把课程目录项关联到真实页码。
/// 标题按模糊包含匹配（去空白、忽略「第X章」等前缀）；匹配不到时按
/// outline 的书本顺序顺延到下一个节点。PDF 没有 outline 时返回全 nil。
private enum OutlinePageMatcher {
    /// 返回与输入目录标题一一对应的页索引；无匹配且无剩余 outline 节点时为 nil。
    static func linkedPageIndices(titles: [String], url: URL) -> [Int?] {
        let entries = extractOutlineEntries(url: url)
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

    private static func extractOutlineEntries(url: URL) -> [(title: String, pageIndex: Int)] {
        guard let pdf = PDFDocument(url: url), let root = pdf.outlineRoot else { return [] }
        var entries: [(title: String, pageIndex: Int)] = []
        collectOutline(root, in: pdf, into: &entries)
        return entries.sorted { $0.pageIndex < $1.pageIndex }
    }

    private static func collectOutline(_ node: PDFOutline, in pdf: PDFDocument, into entries: inout [(title: String, pageIndex: Int)]) {
        let page = node.destination?.page ?? firstPage(of: node)
        if let page {
            entries.append((node.label ?? "", pdf.index(for: page)))
        }
        for index in 0..<node.numberOfChildren {
            if let child = node.child(at: index) {
                collectOutline(child, in: pdf, into: &entries)
            }
        }
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
