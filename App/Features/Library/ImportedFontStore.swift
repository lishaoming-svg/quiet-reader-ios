import CoreText
import CryptoKit
import Foundation

struct ImportedFont: Codable, Identifiable {
    var id: String
    var name: String
    var postScriptName: String
}
enum ImportedFontStore {
    static var root: URL { LocalBookStorage.root.deletingLastPathComponent().appendingPathComponent("ImportedFonts") }
    static var fonts: [ImportedFont] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("index.json")) else { return [] }
        return (try? JSONDecoder().decode([ImportedFont].self, from: data)) ?? []
    }
    static func install(_ data: Data, name: String) throws {
        guard data.count <= 48 * 1_024 * 1_024,
              let provider = CGDataProvider(data: data as CFData), let font = CGFont(provider),
              let postScriptName = font.postScriptName as String? else { throw LocalBookError.invalid }
        let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(id + ".font")
        try data.write(to: path, options: .atomic)
        var registrationError: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(path as CFURL, .process, &registrationError),
           let error = registrationError?.takeRetainedValue(), CFErrorGetCode(error) != CTFontManagerError.alreadyRegistered.rawValue {
            throw error as Error
        }
        var values = fonts
        values.removeAll { $0.id == id }
        values.append(ImportedFont(id: id, name: name, postScriptName: postScriptName))
        try JSONEncoder().encode(values).write(to: root.appendingPathComponent("index.json"), options: .atomic)
    }
    static func registerAll() {
        for font in fonts { CTFontManagerRegisterFontsForURL(root.appendingPathComponent(font.id + ".font") as CFURL, .process, nil) }
    }
}
