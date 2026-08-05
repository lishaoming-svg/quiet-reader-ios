import Foundation
import SwiftData

@MainActor
enum BundledSourceUpdater {
    @discardableResult
    static func refreshExistingSources(
        in modelContext: ModelContext,
        bundle: Bundle = .main
    ) throws -> Int {
        guard let url = bundle.url(forResource: "community-sources", withExtension: "json") else {
            return 0
        }
        let definitions = try SourceImporter().decodeSources(Data(contentsOf: url)).sources
        return try refreshExistingSources(in: modelContext, definitions: definitions)
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
            try record.apply(definition, preserveLocalSettings: true)
            updateCount += 1
        }

        if updateCount > 0 { try modelContext.save() }
        return updateCount
    }
}
