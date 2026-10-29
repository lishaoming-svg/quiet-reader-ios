import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Ask the provider for a local copy. Broad types keep mislabeled iCloud/QQ files selectable;
/// the importer validates the bytes and extension after selection.
struct DocumentImportPicker: UIViewControllerRepresentable {
    var multiple = true
    var completion: (Result<[URL], Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // File providers handle the file hierarchy (.data) more reliably than
        // the common parent of files and directories (.item). Explicit formats
        // also keep EPUB/Office packages visible on older provider databases.
        let types = LocalBookImporter.contentTypes + [.data, .zip, .json]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = multiple
        picker.delegate = context.coordinator
        picker.shouldShowFileExtensions = true
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--picker-fixtures") {
            picker.directoryURL = LibraryTestSeed.pickerDirectory
        }
        #endif
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (Result<[URL], Error>) -> Void
        init(completion: @escaping (Result<[URL], Error>) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            completion(.success(urls))
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion(.success([])) }
    }
}

/// Acquire access in the selection/open-URL callback, before hopping to a worker task.
final class ImportedFileAccess: @unchecked Sendable {
    let url: URL
    private let scoped: Bool
    init(_ url: URL) { self.url = url; scoped = url.startAccessingSecurityScopedResource() }
    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}

enum CoordinatedFileReader {
    static func read(_ url: URL, limit: Int) throws -> Data {
        var failure: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &failure) { coordinated in
            result = Result {
                let values = try coordinated.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                guard values.isDirectory != true else { throw LocalBookError.unsupported }
                guard (values.fileSize ?? 0) <= limit else { throw LocalBookError.tooLarge }
                let data = try Data(contentsOf: coordinated, options: .mappedIfSafe)
                guard data.count <= limit else { throw LocalBookError.tooLarge }
                return data
            }
        }
        if let failure { throw failure }
        guard let result else { throw LocalBookError.invalid }
        return try result.get()
    }
}
