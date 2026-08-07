import Foundation

enum ChapterSequenceNormalizer {
    static func normalize(_ chapters: [BookChapter]) -> [BookChapter] {
        var seenURLs = Set<String>()
        var uniqueReversed: [BookChapter] = []

        for chapter in chapters.reversed() {
            let key = chapter.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, seenURLs.insert(key).inserted else { continue }
            uniqueReversed.append(chapter)
        }

        return uniqueReversed.reversed().enumerated().map { index, chapter in
            BookChapter(
                title: chapter.title,
                url: chapter.url,
                index: index,
                isVolume: chapter.isVolume
            )
        }
    }
}
