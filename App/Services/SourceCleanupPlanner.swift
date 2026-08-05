import Foundation

enum SourceCleanupPlanner {
    static func removableSourceIDs(
        allSourceIDs: Set<String>,
        enabledSourceIDs: Set<String>,
        curatedSourceIDs: Set<String>,
        bookshelfSourceIDs: Set<String>
    ) -> Set<String> {
        let protectedIDs = enabledSourceIDs
            .union(curatedSourceIDs)
            .union(bookshelfSourceIDs)
        return allSourceIDs.subtracting(protectedIDs)
    }
}
