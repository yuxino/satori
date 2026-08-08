import AppKit
import SwiftUI
import SatoriCore

struct PlanSidebar: View {
    @EnvironmentObject private var store: AppModel
    @Binding var selection: UUID?
    /// Compact (icon-strip) mode for the 960…1240 window tier.
    var isCompact = false

    @State private var courseToRename: CourseWorkspace?
    @State private var renameText = ""
    @State private var courseToRemove: CourseWorkspace?

    var body: some View {
        List(selection: $selection) {
            Section(isCompact ? "" : "学习计划") {
                if store.plan.courses.isEmpty {
                    emptyStateRow
                }
                ForEach(store.plan.courses) { course in
                    CourseRow(course: course, isCompact: isCompact)
                        .tag(course.id)
                        .contextMenu {
                            Button("重命名…", systemImage: "pencil") {
                                courseToRename = course
                                renameText = course.title
                            }
                            Button("删除课程", systemImage: "trash", role: .destructive) {
                                courseToRemove = course
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(
            min: isCompact ? 56 : 210,
            ideal: isCompact ? 56 : 232,
            max: isCompact ? 56 : 280
        )
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                brandHeader
                if let session = store.restoredSession {
                    restoredSessionBanner(session)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            newCourseButton
        }
        .alert("重命名课程", isPresented: Binding(
            get: { courseToRename != nil },
            set: { if !$0 { courseToRename = nil } }
        )) {
            TextField("课程名称", text: $renameText)
            Button("取消", role: .cancel) { courseToRename = nil }
            Button("保存") {
                if let course = courseToRename {
                    let title = renameText
                    Task { await store.renameCourse(id: course.id, title: title) }
                }
                courseToRename = nil
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("修改后学习计划会同步更新。")
        }
        .alert("删除「\(courseToRemove?.title ?? "这门课程")」？", isPresented: Binding(
            get: { courseToRemove != nil },
            set: { if !$0 { courseToRemove = nil } }
        )) {
            Button("取消", role: .cancel) { courseToRemove = nil }
            Button("删除", role: .destructive) {
                if let course = courseToRemove {
                    let id = course.id
                    Task { await store.removeCourse(id: id) }
                }
                courseToRemove = nil
            }
        } message: {
            Text("课程及其 PDF 引用、学习记录会一并移除；电脑上的原始 PDF 不会删除。")
        }
        .alert("学习计划加载失败", isPresented: Binding(
            get: { store.persistenceIssue != nil },
            set: { if !$0 { store.acknowledgePersistenceIssue() } }
        )) {
            Button("知道了") { store.acknowledgePersistenceIssue() }
        } message: {
            Text(store.persistenceIssue ?? "")
        }
    }

    private var brandHeader: some View {
        HStack(spacing: 11) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: isCompact ? 34 : 38, height: isCompact ? 34 : 38)
            if !isCompact {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Satori")
                        .font(.headline)
                    Text("理解你的下一页")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, isCompact ? 10 : 14)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// 空计划（用户删光课程）时的起步引导，避免列表区一片空白。
    private var emptyStateRow: some View {
        Group {
            if isCompact {
                Image(systemName: "books.vertical")
                    .font(.system(size: 18))
                    .foregroundStyle(SatoriTheme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .help("还没有课程：点下方 + 新建")
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 20))
                        .foregroundStyle(SatoriTheme.accent)
                    Text("还没有课程")
                        .font(.callout.weight(.medium))
                    Text("点下方「新建课程」，导入第一本教材。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .padding(.trailing, 4)
            }
        }
    }

    /// 「已回到上次阅读的书」的一次性反馈：带关闭按钮，5 秒后自动消失。
    @ViewBuilder
    private func restoredSessionBanner(_ session: RestoredSessionFeedback) -> some View {
        if isCompact {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 13))
                .foregroundStyle(SatoriTheme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(SatoriTheme.accentWash.opacity(0.6))
                .overlay(alignment: .bottom) { Divider() }
                .help("已回到上次阅读的《\(session.documentName)》")
                .task(id: session.documentName) {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    store.dismissRestoredSessionFeedback()
                }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SatoriTheme.accent)
                Text("已回到上次阅读的《\(session.documentName)》")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Button {
                    store.dismissRestoredSessionFeedback()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭提示")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(SatoriTheme.accentWash.opacity(0.6))
            .overlay(alignment: .bottom) { Divider() }
            .task(id: session.documentName) {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                store.dismissRestoredSessionFeedback()
            }
        }
    }

    private var newCourseButton: some View {
        Button {
            Task {
                if let id = await store.addCourse() {
                    selection = id
                }
            }
        } label: {
            if isCompact {
                Image(systemName: "plus")
                    .frame(maxWidth: .infinity)
            } else {
                Label("新建课程", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderless)
        .font(.callout.weight(.medium))
        .foregroundStyle(SatoriTheme.accent)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .help("新建课程")
    }
}

private struct CourseRow: View {
    let course: CourseWorkspace
    var isCompact = false

    @State private var stats: LearningStats?

    private var aggregateProgress: Double {
        guard let stats, !course.documents.isEmpty else { return 0 }
        var pagesRead = 0
        var totalPages = 0
        for document in course.documents {
            let activity = stats.documentCounts[document.id]
            pagesRead += activity?.pagesRead.count ?? 0
            totalPages += max(document.pageCount, activity?.pageCount ?? 0)
        }
        guard totalPages > 0 else { return 0 }
        return min(Double(pagesRead) / Double(totalPages), 1)
    }

    private var pagesReadText: String {
        guard let stats, !course.documents.isEmpty else { return "尚未导入教材" }
        var pagesRead = 0
        var totalPages = 0
        for document in course.documents {
            let activity = stats.documentCounts[document.id]
            pagesRead += activity?.pagesRead.count ?? 0
            totalPages += max(document.pageCount, activity?.pageCount ?? 0)
        }
        guard totalPages > 0 else { return "尚未导入教材" }
        return "已读 \(pagesRead) / \(totalPages) 页"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SatoriTheme.Spacing.sm) {
            HStack(spacing: SatoriTheme.Spacing.sm + 1) {
                Image(systemName: course.documents.isEmpty ? "book.closed" : "book.pages")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                if !isCompact {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(course.title)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(pagesReadText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if !course.documents.isEmpty {
                        Text("\(Int(aggregateProgress * 100))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            if !isCompact, !course.documents.isEmpty {
                ProgressView(value: aggregateProgress)
                    .tint(SatoriTheme.accent)
                    .controlSize(.mini)
            }
        }
        .padding(.vertical, SatoriTheme.Spacing.xs + 2)
        .contentShape(Rectangle())
        .help(isCompact ? "\(course.title) · \(Int(aggregateProgress * 100))%" : "")
        .task(id: course.id) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .learningStatsDidChange)) { _ in
            Task { await load() }
        }
    }

    /// Course-level progress uses LearningStatsStore's deduplicated
    /// pages-read accounting, aggregated across ALL of the course's documents
    /// (not just the last book). The primary course list stays reading-first;
    /// review scheduling remains available to future, explicitly opened flows
    /// instead of becoming a sidebar task badge.
    private func load() async {
        stats = try? await LearningStatsStore.shared.current()
    }
}

extension Notification.Name {
    static let learningStatsDidChange = Notification.Name("satori.learningStatsDidChange")
}
