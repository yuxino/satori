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
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Image(systemName: currentDocument == nil ? "book.closed" : "book.pages")
                    .foregroundStyle(currentDocument == nil ? .secondary : SatoriTheme.lavender)
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
            }
            if currentDocument != nil {
                ProgressView(value: progress)
                    .tint(SatoriTheme.lavender)
                    .controlSize(.mini)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private var rowDetail: String {
        guard let document = currentDocument else { return "尚未导入教材" }
        return "第 \(document.readingPosition.pageIndex + 1) / \(max(document.pageCount, 1)) 页"
    }
}
