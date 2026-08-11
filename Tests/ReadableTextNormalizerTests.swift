import XCTest
@testable import QuietReader

final class ReadableTextNormalizerTests: XCTestCase {
    func testRestoresFullPinyinPhrasesWithToneMarks() {
        let input = "她达到gāo cháo，文字写成yin dao、xìng ài、rǔ fáng和qíng yù。"

        XCTAssertEqual(
            ReadableTextNormalizer.normalize(input),
            "她达到高潮，文字写成阴道、性爱、乳房和情欲。"
        )
    }

    func testRestoresMixedChineseAndPinyinCensorship() {
        let input = "高chao、呻yin、yin荡、情yu、yin道、ru房、xiong部、tun部、luo体、she精、强jian、装bi、cao你"

        XCTAssertEqual(
            ReadableTextNormalizer.normalize(input),
            "高潮、呻吟、淫荡、情欲、阴道、乳房、胸部、臀部、裸体、射精、强奸、装逼、操你"
        )
    }

    func testRemovesMaskingSymbolsAndInvisibleCharacters() {
        let input = "性*感，高＊chao，正\u{200B}常，敏＿感"

        XCTAssertEqual(
            ReadableTextNormalizer.normalize(input),
            "性感，高潮，正常，敏感"
        )
    }

    func testRestoresWholeCharacterPinyinInsideChineseContext() {
        let input = "没心qíng，查清qíng况，保持jīng神并进行jiāo流。"

        XCTAssertEqual(
            ReadableTextNormalizer.normalize(input),
            "没心情，查清情况，保持精神并进行交流。"
        )
    }

    func testRestoresSampledWholeCharacterPinyinFromPagedSource() {
        let input = "勉qiáng下chuáng，gāngān净净的土huáng被子，海làng被风chuī动，猛shòu用ròu眼可见。"

        XCTAssertEqual(
            ReadableTextNormalizer.normalize(input),
            "勉强下床，干干净净的土黄被子，海浪被风吹动，猛兽用肉眼可见。"
        )
    }

    func testKeepsOrdinaryEnglishAndUnrelatedPinyin() {
        let input = "打开 App 查看 AI 技术，人物名为 Cao，拼音 qíng、jīng、sheng yin 保持原样。"

        XCTAssertEqual(ReadableTextNormalizer.normalize(input), input)
    }

    func testNormalizationIsIdempotent() {
        let once = ReadableTextNormalizer.normalize("她达到gāo cháo，性*感。")

        XCTAssertEqual(ReadableTextNormalizer.normalize(once), once)
    }

    func testRemovesWhitespaceInsideChineseProse() {
        let input = "入。  其实 就算 不会。 接下来 AI 模型继续。"

        XCTAssertEqual(
            ReadableTextNormalizer.normalize(input),
            "入。其实就算不会。接下来 AI 模型继续。"
        )
    }
}
