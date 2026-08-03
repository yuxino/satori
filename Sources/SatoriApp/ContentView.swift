import SwiftUI
import SatoriCore

struct ContentView: View {
    @EnvironmentObject private var store: AppModel

    var body: some View {
        NavigationSplitView {
            PlanSidebar(selection: $store.selectedCourseID)
        } detail: {
            if let course = store.plan.courses.first(where: { $0.id == store.selectedCourseID }) {
                CourseOverview(course: course)
                    .id(course.id)
            } else {
                ContentUnavailableView("选择一门课程", systemImage: "books.vertical", description: Text("从左侧开始你的学习项目。"))
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}
