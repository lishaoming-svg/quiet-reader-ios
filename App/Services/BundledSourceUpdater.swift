import Foundation
import SwiftData

@MainActor
enum BundledSourceUpdater {
    // These bundled sources return incomplete books or incompatible page-based directories.
    // A rule refresh must retire them even when the user previously enabled them.
    private static let retiredSourceIDs: Set<String> = [
        "archive.870ca07aea94fc8c54d0ef9e",
        "archive.a184d924d4a2bcfac86e52a8"
    ]

    @discardableResult
    static func refreshExistingSources(
        in modelContext: ModelContext,
        bundle: Bundle = .main
    ) throws -> Int {
        let definitions = try bundledDefinitions(bundle: bundle)
        return try refreshExistingSources(in: modelContext, definitions: definitions)
    }

    static func bundledDefinitions(bundle: Bundle = .main) throws -> [BookSourceDefinition] {
        guard let url = bundle.url(forResource: "community-sources", withExtension: "json") else {
            return []
        }
        return try SourceImporter().decodeSources(Data(contentsOf: url)).sources
    }

    @discardableResult
    static func refreshExistingSources(
        in modelContext: ModelContext,
        definitions: [BookSourceDefinition]
    ) throws -> Int {
        let records = try modelContext.fetch(FetchDescriptor<BookSourceRecord>())
        let existing = Dictionary(uniqueKeysWithValues: records.map { ($0.sourceID, $0) })
        var updateCount = 0

        for definition in definitions {
            guard let record = existing[definition.id],
                  definition.updateTimestamp > record.lastUpdateTime else {
                continue
            }
            try record.apply(
                definition,
                preserveLocalSettings: !retiredSourceIDs.contains(definition.id)
            )
            updateCount += 1
        }

        if updateCount > 0 { try modelContext.save() }
        return updateCount
    }
}
