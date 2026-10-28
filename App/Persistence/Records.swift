import Foundation
import SwiftData

@Model
final class BookSourceRecord {
    @Attribute(.unique) var sourceID: String
    var sourceURL: String
    var sourceName: String
    var sourceGroup: String
    var enabled: Bool
    var lastUpdateTime: Int64
    @Attribute(.externalStorage) var rawJSON: Data
    var importedAt: Date

    init(definition: BookSourceDefinition) throws {
        sourceID = definition.id
        sourceURL = definition.bookSourceUrl
        sourceName = definition.bookSourceName
        sourceGroup = definition.groupName
        enabled = definition.isEnabled
        lastUpdateTime = definition.updateTimestamp
        rawJSON = try JSONEncoder.sourceEncoder.encode(definition)
        importedAt = .now
    }

    var definition: BookSourceDefinition? {
        guard var value = try? JSONDecoder().decode(BookSourceDefinition.self, from: rawJSON) else {
            return nil
        }
        value.bookSourceName = sourceName
        value.bookSourceGroup = sourceGroup
        value.enabled = enabled
        return value
    }

    func apply(_ definition: BookSourceDefinition, preserveLocalSettings: Bool) throws {
        sourceURL = definition.bookSourceUrl
        if !preserveLocalSettings {
            sourceName = definition.bookSourceName
            sourceGroup = definition.groupName
            enabled = definition.isEnabled
        }
        lastUpdateTime = definition.updateTimestamp
        rawJSON = try JSONEncoder.sourceEncoder.encode(definition)
        importedAt = .now
    }
}

@Model
final class BookRecord {
    @Attribute(.unique) var bookID: String
    var sourceID: String
    var sourceName: String
    var name: String
    var author: String
    var intro: String
    var kind: String
    var coverURL: String
    var bookURL: String
    var tocURL: String
    var addedAt: Date
    var lastReadAt: Date

    init(book: SearchBook) {
        bookID = book.id
        sourceID = book.sourceID
        sourceName = book.sourceName
        name = book.name
        author = book.author
        intro = book.intro
        kind = book.kind
        coverURL = book.coverURL
        bookURL = book.bookURL
        tocURL = book.tocURL
        addedAt = .now
        lastReadAt = .now
    }

    var searchBook: SearchBook {
        SearchBook(
            sourceID: sourceID,
            sourceName: sourceName,
            name: name,
            author: author,
            intro: intro,
            kind: kind,
            lastChapter: "",
            updateTime: "",
            bookURL: bookURL,
            coverURL: resolvedCoverURL,
            tocURL: tocURL
        )
    }

    func update(from book: SearchBook) {
        sourceName = book.sourceName
        name = book.name
        author = book.author
        intro = book.intro
        kind = book.kind
        coverURL = book.coverURL
        tocURL = book.tocURL
    }
}

@Model
final class ReadingProgressRecord {
    @Attribute(.unique) var bookID: String
    var chapterURL: String
    var chapterTitle: String
    var chapterIndex: Int
    var locatorOffset: Int = 0
    var chapterProgress: Double = 0
    var pageIndex: Int = 0
    var readingMode: String = "scroll"
    var publicationLocator: String? = nil
    var bookProgress: Double? = nil
    var updatedAt: Date

    init(bookID: String, chapter: BookChapter) {
        self.bookID = bookID
        chapterURL = chapter.url
        chapterTitle = chapter.title
        chapterIndex = chapter.index
        updatedAt = .now
    }

    func update(
        chapter: BookChapter,
        locatorOffset: Int = 0,
        chapterProgress: Double = 0,
        pageIndex: Int = 0,
        readingMode: String = "scroll"
    ) {
        chapterURL = chapter.url
        chapterTitle = chapter.title
        chapterIndex = chapter.index
        self.locatorOffset = max(0, locatorOffset)
        self.chapterProgress = min(max(chapterProgress, 0), 1)
        self.pageIndex = max(0, pageIndex)
        self.readingMode = readingMode
        updatedAt = .now
    }
}

@Model
final class ChapterCacheRecord {
    @Attribute(.unique) var cacheKey: String
    var chapterURL: String
    var bookID: String
    var title: String
    var content: String
    var cachedAt: Date

    init(sourceID: String, bookID: String, chapter: BookChapter, content: String) {
        cacheKey = "\(sourceID)::\(chapter.url)"
        chapterURL = chapter.url
        self.bookID = bookID
        title = chapter.title
        self.content = content
        cachedAt = .now
    }
}

@Model
final class ChapterListCacheRecord {
    @Attribute(.unique) var bookID: String
    var sourceID: String
    @Attribute(.externalStorage) var rawChapters: Data
    var cachedAt: Date

    init(bookID: String, sourceID: String, chapters: [BookChapter]) throws {
        self.bookID = bookID
        self.sourceID = sourceID
        rawChapters = try JSONEncoder().encode(chapters)
        cachedAt = .now
    }

    var chapters: [BookChapter] {
        (try? JSONDecoder().decode([BookChapter].self, from: rawChapters)) ?? []
    }

    func update(sourceID: String, chapters: [BookChapter]) throws {
        self.sourceID = sourceID
        rawChapters = try JSONEncoder().encode(chapters)
        cachedAt = .now
    }
}

enum ChapterListCacheStore {
    static func record(bookID: String, in context: ModelContext) -> ChapterListCacheRecord? {
        let descriptor = FetchDescriptor<ChapterListCacheRecord>(
            predicate: #Predicate { $0.bookID == bookID }
        )
        return try? context.fetch(descriptor).first
    }

    static func save(
        chapters: [BookChapter],
        bookID: String,
        sourceID: String,
        in context: ModelContext
    ) throws {
        guard !chapters.isEmpty else { return }
        if let existing = record(bookID: bookID, in: context) {
            try existing.update(sourceID: sourceID, chapters: chapters)
        } else {
            context.insert(
                try ChapterListCacheRecord(
                    bookID: bookID,
                    sourceID: sourceID,
                    chapters: chapters
                )
            )
        }
        try context.save()
    }
}

@Model
final class ReadingSessionRecord {
    @Attribute(.unique) var sessionID: String
    var bookID: String
    var bookName: String
    var sourceID: String
    var startedAt: Date
    var endedAt: Date
    var activeSeconds: Double

    init(
        sessionID: String,
        bookID: String,
        bookName: String,
        sourceID: String,
        startedAt: Date = .now,
        endedAt: Date = .now,
        activeSeconds: Double = 0
    ) {
        self.sessionID = sessionID
        self.bookID = bookID
        self.bookName = bookName
        self.sourceID = sourceID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.activeSeconds = max(0, activeSeconds)
    }

    func update(endedAt: Date, activeSeconds: Double) {
        self.endedAt = endedAt
        self.activeSeconds = max(0, activeSeconds)
    }
}

@Model
final class BookmarkRecord {
    @Attribute(.unique) var bookmarkID: String
    var bookID: String
    var bookName: String
    var sourceID: String
    var chapterURL: String
    var chapterTitle: String
    var chapterIndex: Int
    var locatorOffset: Int
    var chapterProgress: Double
    var excerpt: String
    var publicationLocator: String? = nil
    var createdAt: Date

    init(
        book: SearchBook,
        chapter: BookChapter,
        locatorOffset: Int,
        chapterProgress: Double,
        excerpt: String
    ) {
        bookmarkID = UUID().uuidString
        bookID = book.id
        bookName = book.name
        sourceID = book.sourceID
        chapterURL = chapter.url
        chapterTitle = chapter.title
        chapterIndex = chapter.index
        self.locatorOffset = max(0, locatorOffset)
        self.chapterProgress = min(max(chapterProgress, 0), 1)
        self.excerpt = excerpt
        createdAt = .now
    }
}

@Model
final class SearchHistoryRecord {
    @Attribute(.unique) var normalizedKeyword: String
    var keyword: String
    var searchedAt: Date
    var useCount: Int

    init(keyword: String) {
        let cleaned = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        normalizedKeyword = cleaned.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        self.keyword = cleaned
        searchedAt = .now
        useCount = 1
    }

    func touch(keyword: String) {
        self.keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        searchedAt = .now
        useCount += 1
    }
}

extension JSONEncoder {
    static var sourceEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
