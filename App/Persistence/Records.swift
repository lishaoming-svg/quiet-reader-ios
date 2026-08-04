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
            coverURL: coverURL,
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
    var updatedAt: Date

    init(bookID: String, chapter: BookChapter) {
        self.bookID = bookID
        chapterURL = chapter.url
        chapterTitle = chapter.title
        chapterIndex = chapter.index
        updatedAt = .now
    }

    func update(chapter: BookChapter) {
        chapterURL = chapter.url
        chapterTitle = chapter.title
        chapterIndex = chapter.index
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

extension JSONEncoder {
    static var sourceEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
