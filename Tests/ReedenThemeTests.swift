import Foundation
import UIKit
import XCTest
import ZIPFoundation
@testable import QuietReader

final class ReedenThemeTests: XCTestCase {
    private let theme = Data(#"{"name":"海风","light":{"author":" 岛屿 ","backgroundColor":"#804488CC"},"dark":{"author":"另一个人"}}"#.utf8)

    func testLegacyPackageUsesEmbeddedWallpaperAndFilenameCreator() throws {
        let zip = try Archive(data: Data(), accessMode: .create)
        for (path, data) in [("theme.json", theme), ("light/theme_bg.img", testImage())] {
            try zip.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { offset, count in
                data.subdata(in: Int(offset)..<(Int(offset) + count))
            }
        }
        let bytes = try Data([0x52, 0x45, 0x44, 4]) + XCTUnwrap(zip.data)
        let package = try ReedenThemePackage.read(bytes, filename: "应用主题 - 上吊-海风.red")
        XCTAssertEqual(package.name, "海风")
        XCTAssertEqual(package.creator, "上吊")
        XCTAssertNil(try ReedenThemePackage.read(bytes, filename: "海风.red").creator)
        XCTAssertEqual(package.panels.map(\.title), ["浅色", "深色"])
        XCTAssertNotNil(package.panels[0].image)
        XCTAssertNil(package.panels[1].image)
        let color = ReedenThemePreview.color(package.panels[0].palette?.backgroundColor, fallback: .black)
        XCTAssertEqual(color.cgColor.alpha, 128.0 / 255.0, accuracy: 0.0001)
    }

    func testPrivateThemeReadsPlainArtworkOnlyAndUsesFilenameForCreator() throws {
        let header = Data(#"{"version":2,"resourceType":"themeBundle","assetMode":"plain-sequential","manifestLength":32}"#.utf8)
        var bytes = Data([0x52, 0x45, 0x44, 0x10, 0, 0, 0, UInt8(header.count)])
        bytes.append(header)
        bytes.append(Data(repeating: 0xAA, count: 32))
        bytes.append(testImage())
        let result = try ReedenThemePackage.read(bytes, filename: "应用主题 - 制作人 - 主题 - 夜色.red")
        XCTAssertEqual(result.kind, .privateTheme)
        XCTAssertEqual(result.creator, "制作人")
        XCTAssertEqual(result.name, "主题 - 夜色")
        XCTAssertEqual(result.panels.count, 1)
        XCTAssertNotNil(result.panels.first?.image)
        XCTAssertNil(result.panels.first?.palette)
        let unnamed = try ReedenThemePackage.read(bytes, filename: "应用主题 - 夜色.red")
        XCTAssertNil(unnamed.creator)
        XCTAssertEqual(unnamed.name, "夜色")
        XCTAssertThrowsError(try ReedenThemePackage.read(Data(bytes.prefix(9)), filename: "损坏.red"))
    }

    func testImportStoresOriginalAndPreviewWithoutDuplicatingFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = ReedenThemeLibrary(root: folder.appendingPathComponent("themes"))
        let input = folder.appendingPathComponent("测试.json")
        try theme.write(to: input)
        let access = ImportedFileAccess(input)
        let imported = try await library.importFile(access)
        let duplicate = try await library.importFile(access)
        XCTAssertTrue(imported)
        XCTAssertFalse(duplicate)
        let records = try await library.records()
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(try Data(contentsOf: library.original(record)), theme)
        XCTAssertNotNil(UIImage(contentsOfFile: library.preview(record).path))
        try await library.remove(record)
        let remaining = try await library.records()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
    }

    func testRejectsUnrelatedJSON() {
        XCTAssertThrowsError(try ReedenThemePackage.read(Data(#"{"name":"书源","url":"https://example.org"}"#.utf8),
                                                          filename: "书源.json"))
    }

    private func testImage() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 200, height: 180), format: format).pngData { renderer in
            renderer.cgContext.setFillColor(UIColor.blue.cgColor)
            renderer.cgContext.fill(CGRect(x: 0, y: 0, width: 200, height: 180))
        }
    }
}
