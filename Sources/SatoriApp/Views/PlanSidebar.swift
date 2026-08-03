import SwiftUI
import SatoriCore

struct PlanSidebar: View {
    @EnvironmentObject private var store: AppModel
    @Binding var selection: UUID?

    var body: some View {
        List(selection: $selection) {
            Section("计算机自学计划") {
                ForEach(store.plan.courses) { course in
                    Label(course.title, systemImage: course.documents.isEmpty ? "book.closed" : "book")
                        .tag(course.id)
                }
            }
        }
        .navigationTitle("Satori")
        .safeAreaInset(edge: .bottom) {
            Text("理解优先，不强制记笔记")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
        }
    }
}
