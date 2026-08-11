import SwiftData
import SwiftUI

@main
struct QuietReaderApp: App {
    private let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(
                for: BookSourceRecord.self,
                BookRecord.self,
                ReadingProgressRecord.self,
                ChapterCacheRecord.self,
                ChapterListCacheRecord.self,
                ReadingSessionRecord.self,
                BookmarkRecord.self,
                SearchHistoryRecord.self
            )
        } catch {
            fatalError("无法初始化本地数据库：\(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.light)
        }
        .modelContainer(modelContainer)
    }
}
