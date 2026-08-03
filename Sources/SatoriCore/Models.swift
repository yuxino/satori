import Foundation

public struct LearningPlan: Codable, Sendable {
    public var title: String
    public var courses: [CourseWorkspace]

    public init(title: String = "计算机自学计划", courses: [CourseWorkspace] = CourseWorkspace.initialCourses) {
        self.title = title
        self.courses = courses
    }
}

public struct CourseWorkspace: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var subtitle: String
    public var learningDirectory: [LearningDirectoryItem]
    public var documents: [StudyDocument]
    public var relatedResources: [RelatedResource]

    public init(
        id: UUID = UUID(),
        title: String,
        subtitle: String,
        learningDirectory: [LearningDirectoryItem] = [],
        documents: [StudyDocument] = [],
        relatedResources: [RelatedResource] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.learningDirectory = learningDirectory
        self.documents = documents
        self.relatedResources = relatedResources
    }

    public static let initialCourses = [
        CourseWorkspace(title: "高级语言程序设计", subtitle: "理解程序结构、数据与算法", learningDirectory: defaultDirectory(for: "高级语言程序设计")),
        CourseWorkspace(title: "软件工程", subtitle: "把软件做成可靠的系统", learningDirectory: defaultDirectory(for: "软件工程")),
        CourseWorkspace(title: "操作系统", subtitle: "理解进程、内存与文件系统", learningDirectory: defaultDirectory(for: "操作系统"))
    ]

    public static func defaultDirectory(for title: String) -> [LearningDirectoryItem] {
        let items: [String]
        switch title {
        case "高级语言程序设计": items = ["课程大纲与学习目标", "程序设计基础", "数据类型与表达式", "控制结构", "函数与模块", "数组、指针与结构", "文件与综合练习"]
        case "软件工程": items = ["软件工程概述", "需求工程", "软件设计", "实现与测试", "软件项目管理", "软件维护"]
        case "操作系统": items = ["操作系统概论", "运行环境与运行机制", "进程与线程模型", "进程与线程调度", "存储管理", "文件系统", "设备管理", "同步与死锁"]
        default: items = []
        }
        return items.map { LearningDirectoryItem(title: $0) }
    }
}

public struct LearningDirectoryItem: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var pageIndex: Int?
    public var isComplete: Bool

    public init(id: UUID = UUID(), title: String, pageIndex: Int? = nil, isComplete: Bool = false) {
        self.id = id
        self.title = title
        self.pageIndex = pageIndex
        self.isComplete = isComplete
    }
}

public enum DocumentContentKind: String, Codable, CaseIterable, Sendable {
    case text
    case scanned
    case mixed
    case unknown

    public var localizedTitle: String {
        switch self {
        case .text: "文字版"
        case .scanned: "扫描版"
        case .mixed: "混合版"
        case .unknown: "待分析"
        }
    }
}

public struct StudyDocument: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var displayName: String
    public var localPath: String
    public var bookmarkData: Data?
    public var pageCount: Int
    public var contentKind: DocumentContentKind
    public var readingPosition: ReadingPosition
    public var importedAt: Date

    public init(
        id: UUID = UUID(),
        displayName: String,
        localPath: String,
        bookmarkData: Data? = nil,
        pageCount: Int = 0,
        contentKind: DocumentContentKind = .unknown,
        readingPosition: ReadingPosition = .init(),
        importedAt: Date = .now
    ) {
        self.id = id
        self.displayName = displayName
        self.localPath = localPath
        self.bookmarkData = bookmarkData
        self.pageCount = pageCount
        self.contentKind = contentKind
        self.readingPosition = readingPosition
        self.importedAt = importedAt
    }
}

public struct ReadingPosition: Codable, Hashable, Sendable {
    public var pageIndex: Int
    public var normalizedPageOffset: Double
    public var lastOpenedAt: Date

    public init(pageIndex: Int = 0, normalizedPageOffset: Double = 0, lastOpenedAt: Date = .now) {
        self.pageIndex = max(0, pageIndex)
        self.normalizedPageOffset = min(max(normalizedPageOffset, 0), 1)
        self.lastOpenedAt = lastOpenedAt
    }
}

public enum RelatedResourceKind: String, Codable, Sendable {
    case web
    case document
    case code
}

public struct RelatedResource: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var location: String
    public var kind: RelatedResourceKind

    public init(id: UUID = UUID(), title: String, location: String, kind: RelatedResourceKind) {
        self.id = id
        self.title = title
        self.location = location
        self.kind = kind
    }
}
