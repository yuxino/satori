import AppKit
import SwiftUI
import SatoriCore

struct PlanSidebar: View {
    @EnvironmentObject private var store: AppModel
    @Binding var selection: UUID?

    var body: some View {
        List(selection: $selection) {
            Section("学习计划") {
                ForEach(store.plan.courses) { course in
                    CourseRow(course: course)
                        .tag(course.id)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 210, ideal: 232, max: 280)
        .safeAreaInset(edge: .top, spacing: 0) {
            brandHeader
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StreakCard()
        }
    }

    private var brandHeader: some View {
        HStack(spacing: 11) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text("Satori")
                    .font(.headline)
                Text("理解你的下一页")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct CourseRow: View {
    let course: CourseWorkspace

    private var currentDocument: StudyDocument? { course.documents.last }

    private var progress: Double {
        guard let document = currentDocument, document.pageCount > 0 else { return 0 }
        return min(Double(document.readingPosition.pageIndex + 1) / Double(document.pageCount), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SatoriTheme.Spacing.sm) {
            HStack(spacing: SatoriTheme.Spacing.sm + 1) {
                Image(systemName: currentDocument == nil ? "book.closed" : "book.pages")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(course.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(rowDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if currentDocument != nil {
                    Text("\(Int(progress * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            if currentDocument != nil {
                ProgressView(value: progress)
                    .tint(SatoriTheme.accent)
                    .controlSize(.mini)
            }
        }
        .padding(.vertical, SatoriTheme.Spacing.xs + 2)
        .contentShape(Rectangle())
    }

    private var rowDetail: String {
        guard let document = currentDocument else { return "尚未导入教材" }
        return "第 \(document.readingPosition.pageIndex + 1) / \(max(document.pageCount, 1)) 页"
    }
}

/// A compact progress card pinned to the sidebar's bottom: today's streak and
/// how many badges you've earned — visible every time the app opens, so the
/// sense of moving forward is always in view.
private struct StreakCard: View {
    @State private var stats: LearningStats?

    var body: some View {
        HStack(spacing: SatoriTheme.Spacing.sm) {
            // Flame: the current streak.
            HStack(spacing: 6) {
                Image(systemName: "flame.fill")
                    .foregroundStyle((stats?.streakDays ?? 0) > 0 ? SatoriTheme.gold : Color.secondary.opacity(0.5))
                    .font(.system(size: 15))
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(stats?.streakDays ?? 0) 天")
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                    Text("连续学习")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Badges earned count.
            HStack(spacing: 6) {
                Image(systemName: "medal.fill")
                    .foregroundStyle(SatoriTheme.accent)
                    .font(.system(size: 13))
                Text("\(stats?.unlockedBadges.count ?? 0) 徽章")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .learningStatsDidChange)) { _ in
            Task { await load() }
        }
    }

    private func load() async {
        stats = try? await LearningStatsStore.shared.current()
    }
}

extension Notification.Name {
    static let learningStatsDidChange = Notification.Name("satori.learningStatsDidChange")
}
