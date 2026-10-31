import Foundation
import UIKit

/// Reads Word 97–2007 binary documents using MS-CFB streams and the MS-DOC piece table.
/// Text is reconstructed from logical character positions, never by scanning arbitrary binary bytes.
enum LegacyWordParser {
    static func text(from data: Data) throws -> String {
        if data.starts(with: Array("{\\rtf".utf8)) {
            return try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                          documentAttributes: nil).string
        }
        let compound = try CompoundDocument(data)
        if compound.entries.contains(where: { $0.name == "EncryptedPackage" }) { throw LocalBookError.encrypted }
        let word = try compound.stream(named: "WordDocument")
        guard try word.le16(0) == 0xA5EC, try word.le16(2) >= 0x00C1 else { throw LocalBookError.invalid }
        let flags = try word.le16(10)
        guard flags & 0x8100 == 0 else { throw LocalBookError.encrypted }
        let table = try compound.stream(named: flags & 0x0200 != 0 ? "1Table" : "0Table")
        var cursor = 32
        let words = try word.le16(cursor); cursor += 2 + Int(words) * 2
        let longs = try word.le16(cursor); cursor += 2
        guard longs >= 4 else { throw LocalBookError.invalid }
        let characterCount = Int(try word.le32(cursor + 12))
        cursor += Int(longs) * 4
        guard try word.le16(cursor) > 33 else { throw LocalBookError.invalid }
        cursor += 2
        let clxOffset = Int(try word.le32(cursor + 33 * 8))
        let clxSize = Int(try word.le32(cursor + 33 * 8 + 4))
        let clx = try table.checkedSlice(clxOffset, clxSize)
        cursor = 0
        while cursor < clx.count, clx[cursor] == 1 {
            cursor += 3 + Int(try clx.le16(cursor + 1))
        }
        guard cursor < clx.count, clx[cursor] == 2 else { throw LocalBookError.invalid }
        let pieceSize = Int(try clx.le32(cursor + 1))
        let pieces = try clx.checkedSlice(cursor + 5, pieceSize)
        guard pieceSize >= 4, (pieceSize - 4) % 12 == 0 else { throw LocalBookError.invalid }
        let count = (pieceSize - 4) / 12
        guard count <= 500_000, characterCount <= 32 * 1_024 * 1_024 else { throw LocalBookError.tooLarge }
        var result = ""
        for index in 0..<count {
            try Task.checkCancellation()
            let first = Int(try pieces.le32(index * 4))
            let next = Int(try pieces.le32((index + 1) * 4))
            guard next >= first else { throw LocalBookError.invalid }
            if first >= characterCount { break }
            let characters = min(next, characterCount) - first
            let position = try pieces.le32((count + 1) * 4 + index * 8 + 2)
            let compressed = position & 0x4000_0000 != 0
            let offset = Int(position & 0x3FFF_FFFF) / (compressed ? 2 : 1)
            let bytes = try word.checkedSlice(offset, characters * (compressed ? 1 : 2))
            guard let text = String(data: bytes, encoding: compressed ? .windowsCP1252 : .utf16LittleEndian)
            else { throw LocalBookError.invalid }
            result += text
        }
        // Word fields store instructions before a separator and their displayed result after it.
        var output = ""
        var fieldInstructions: [Bool] = []
        for scalar in result.unicodeScalars {
            switch scalar.value {
            case 0x13: fieldInstructions.append(true)
            case 0x14: if !fieldInstructions.isEmpty { fieldInstructions[fieldInstructions.count - 1] = false }
            case 0x15: if !fieldInstructions.isEmpty { fieldInstructions.removeLast() }
            default:
                guard !fieldInstructions.contains(true) else { continue }
                switch scalar.value {
                case 0x0D, 0x0B, 0x0C: output += "\n"
                case 0x07, 0x09: output += "\t"
                case 0..<32: break
                default: output.unicodeScalars.append(scalar)
                }
            }
        }
        return output
    }
}

private struct CompoundDocument {
    struct Entry { let name: String; let type: UInt8; let start: UInt32; let size: Int }
    let entries: [Entry]
    private let data: Data
    private let sectorSize: Int
    private let fat: [UInt32]
    private let miniFAT: [UInt32]
    private let miniStream: Data
    private let miniCutoff: Int

    init(_ data: Data) throws {
        guard data.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]),
              try data.le16(28) == 0xFFFE else { throw LocalBookError.invalid }
        let version = try data.le16(26)
        let shift = try data.le16(30)
        guard (version == 3 && shift == 9) || (version == 4 && shift == 12),
              try data.le16(32) == 6 else { throw LocalBookError.invalid }
        let size = 1 << Int(shift)
        let sectorCount = data.count / size - 1
        guard sectorCount > 0 else { throw LocalBookError.invalid }
        func sector(_ id: UInt32) throws -> Data {
            guard id < sectorCount else { throw LocalBookError.invalid }
            return try data.checkedSlice((Int(id) + 1) * size, size)
        }
        var difat = try (0..<109).map { try data.le32(76 + $0 * 4) }.filter { $0 < 0xFFFF_FFFA }
        var next = try data.le32(68)
        let difatCount = Int(try data.le32(72))
        guard difatCount <= sectorCount else { throw LocalBookError.invalid }
        var visited = Set<UInt32>()
        for _ in 0..<difatCount {
            guard visited.insert(next).inserted else { throw LocalBookError.invalid }
            let block = try sector(next)
            difat += try (0..<(size / 4 - 1)).map { try block.le32($0 * 4) }.filter { $0 < 0xFFFF_FFFA }
            next = try block.le32(size - 4)
        }
        let fatCount = Int(try data.le32(44))
        guard fatCount <= sectorCount, difat.count >= fatCount else { throw LocalBookError.invalid }
        var fat: [UInt32] = []
        for id in difat.prefix(fatCount) {
            let block = try sector(id)
            fat += try (0..<(size / 4)).map { try block.le32($0 * 4) }
        }
        func chain(_ start: UInt32, limit: Int = 64 * 1_024 * 1_024) throws -> Data {
            var current = start
            var visited = Set<UInt32>()
            var output = Data()
            while current != 0xFFFF_FFFE {
                guard current < fat.count, visited.insert(current).inserted, output.count <= limit - size
                else { throw LocalBookError.invalid }
                output.append(try sector(current))
                current = fat[Int(current)]
            }
            return output
        }
        let directory = try chain(data.le32(48))
        var entries: [Entry] = []
        for offset in stride(from: 0, to: directory.count, by: 128) {
            let type = directory[offset + 66]
            guard type != 0 else { continue }
            let nameLength = Int(try directory.le16(offset + 64))
            guard (2...64).contains(nameLength), nameLength % 2 == 0 else { throw LocalBookError.invalid }
            let nameData = try directory.checkedSlice(offset, nameLength - 2)
            guard let name = String(data: nameData, encoding: .utf16LittleEndian) else { throw LocalBookError.invalid }
            let low = try directory.le32(offset + 120)
            let high = version == 4 ? try directory.le32(offset + 124) : 0
            guard high == 0, low <= 64 * 1_024 * 1_024 else { throw LocalBookError.tooLarge }
            entries.append(Entry(name: name, type: type, start: try directory.le32(offset + 116), size: Int(low)))
        }
        let miniCount = Int(try data.le32(64))
        guard miniCount <= sectorCount else { throw LocalBookError.invalid }
        let miniData = miniCount == 0 ? Data() : try chain(data.le32(60))
        self.miniFAT = try stride(from: 0, to: miniData.count, by: 4).map { try miniData.le32($0) }
        if let root = entries.first(where: { $0.type == 5 }), root.size > 0 {
            self.miniStream = try chain(root.start).checkedSlice(0, root.size)
        } else { self.miniStream = Data() }
        self.data = data; self.sectorSize = size; self.entries = entries; self.fat = fat
        self.miniCutoff = Int(try data.le32(56))
        guard miniCutoff == 4096 else { throw LocalBookError.invalid }
    }

    func stream(named name: String) throws -> Data {
        guard let entry = entries.first(where: { $0.name == name && $0.type == 2 }) else { throw LocalBookError.invalid }
        guard entry.size > 0 else { return Data() }
        let mini = entry.size < miniCutoff
        let table = mini ? miniFAT : fat
        let size = mini ? 64 : sectorSize
        var current = entry.start
        var visited = Set<UInt32>()
        var output = Data()
        while current != 0xFFFF_FFFE, output.count < entry.size {
            guard current < table.count, visited.insert(current).inserted else { throw LocalBookError.invalid }
            let block = mini ? try miniStream.checkedSlice(Int(current) * size, size)
                : try data.checkedSlice((Int(current) + 1) * size, size)
            output.append(block)
            current = table[Int(current)]
        }
        return try output.checkedSlice(0, entry.size)
    }
}

private extension Data {
    func checkedSlice(_ offset: Int, _ length: Int) throws -> Data {
        guard offset >= 0, length >= 0, length <= count, offset <= count - length else { throw LocalBookError.invalid }
        return subdata(in: offset..<(offset + length))
    }
    func le16(_ offset: Int) throws -> UInt16 {
        let bytes = try checkedSlice(offset, 2)
        return UInt16(bytes[0]) | UInt16(bytes[1]) << 8
    }
    func le32(_ offset: Int) throws -> UInt32 {
        let bytes = try checkedSlice(offset, 4)
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }
}
