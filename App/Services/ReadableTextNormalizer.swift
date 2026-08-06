import Foundation

enum ReadableTextNormalizer {
    private struct ReplacementRule {
        let pattern: String
        let replacement: String
    }

    private static let tokenSeparator = #"[\s*＊·•・_＿~～]*"#

    private static let restorationRules: [ReplacementRule] = [
        phrase("yin", "dao", as: "阴道"),
        phrase("yin", "jing", as: "阴茎"),
        phrase("yin", "chun", as: "阴唇"),
        phrase("yin", "mao", as: "阴毛"),
        phrase("yin", "bu", as: "阴部"),
        phrase("yin", "hu", as: "阴户"),
        phrase("yin", "nang", as: "阴囊"),
        phrase("yin", "di", as: "阴蒂"),
        phrase("yin", "ye", as: "淫液"),
        phrase("xing", "ai", as: "性爱"),
        phrase("xing", "yu", as: "性欲"),
        phrase("xing", "jiao", as: "性交"),
        phrase("xing", "gan", as: "性感"),
        phrase("gao", "chao", as: "高潮"),
        phrase("ru", "fang", as: "乳房"),
        phrase("ru", "tou", as: "乳头"),
        phrase("ru", "gou", as: "乳沟"),
        phrase("ru", "feng", as: "乳峰"),
        phrase("ru", "yun", as: "乳晕"),
        phrase("ru", "zhi", as: "乳汁"),
        phrase("ru", "ye", as: "乳液"),
        phrase("she", "jing", as: "射精"),
        phrase("ji", "ba", as: "鸡巴"),
        phrase("gui", "tou", as: "龟头"),
        phrase("kou", "jiao", as: "口交"),
        phrase("rou", "yu", as: "肉欲"),
        phrase("qing", "yu", as: "情欲"),
        phrase("se", "yu", as: "色欲"),
        phrase("yu", "wang", as: "欲望"),
        phrase("luo", "ti", as: "裸体"),
        phrase("luo", "lu", as: "裸露"),

        mixed(#"高[\s*＊·•・_＿~～]*chao[1-5]?(?![a-z])"#, as: "高潮"),
        mixed(#"(?<![a-z])gao[1-5]?[\s*＊·•・_＿~～]*潮"#, as: "高潮"),
        mixed(#"呻[\s*＊·•・_＿~～]*yin[1-5]?(?![a-z])"#, as: "呻吟"),
        mixed(#"(?<![a-z])yin[1-5]?[\s*＊·•・_＿~～]*([荡靡乱])"#, as: "淫$1"),
        mixed(#"([情性肉色])[\s*＊·•・_＿~～]*yu[1-5]?(?![a-z])"#, as: "$1欲"),
        mixed(#"(?<![a-z])yu[1-5]?[\s*＊·•・_＿~～]*望"#, as: "欲望"),
        mixed(#"(?<![a-z])yin[1-5]?[\s*＊·•・_＿~～]*([道茎唇毛部户囊蒂])"#, as: "阴$1"),
        mixed(#"(?<![a-z])ru[1-5]?[\s*＊·•・_＿~～]*([房头沟峰晕汁液])"#, as: "乳$1"),
        mixed(#"(?<![a-z])xing[1-5]?[\s*＊·•・_＿~～]*([爱欲交感器])"#, as: "性$1"),
        mixed(#"(?<![a-z])xiong[1-5]?[\s*＊·•・_＿~～]*([部口前脯围罩])"#, as: "胸$1"),
        mixed(#"(?<![a-z])tun[1-5]?[\s*＊·•・_＿~～]*([部瓣])"#, as: "臀$1"),
        mixed(#"(?<![a-z])luo[1-5]?[\s*＊·•・_＿~～]*([体露身])"#, as: "裸$1"),
        mixed(#"(?<![a-z])she[1-5]?[\s*＊·•・_＿~～]*精"#, as: "射精"),
        mixed(#"阴[\s*＊·•・_＿~～]*jing[1-5]?(?![a-z])"#, as: "阴茎"),
        mixed(#"(?<![a-z])gui[1-5]?[\s*＊·•・_＿~～]*头"#, as: "龟头"),
        mixed(#"([强轮])[\s*＊·•・_＿~～]*jian[1-5]?(?![a-z])"#, as: "$1奸"),
        mixed(#"([牛装傻])[\s*＊·•・_＿~～]*bi[1-5]?(?![a-z])"#, as: "$1逼"),
        mixed(#"(?<![a-z])cao[1-5]?[\s*＊·•・_＿~～]*([你我他她])"#, as: "操$1"),

        // Some sites replace every occurrence of a filtered Han character, including
        // harmless compounds such as "事qíng" and "jīng神". Requiring an adjacent
        // Han character keeps ordinary English and standalone pinyin untouched.
        contextual("gangan", as: "干干"),
        contextual("dangdang", as: "荡荡"),
        contextual("qing", as: "情"),
        contextual("qiang", as: "强"),
        contextual("chuang", as: "床"),
        contextual("gan", as: "干"),
        contextual("jing", as: "精"),
        contextual("feng", as: "缝"),
        contextual("rou", as: "肉"),
        contextual("yin", as: "阴"),
        contextual("jiao", as: "交"),
        contextual("chui", as: "吹"),
        contextual("huang", as: "黄"),
        contextual("ji", as: "鸡"),
        contextual("bi", as: "逼"),
        contextual("lang", as: "浪"),
        contextual("shou", as: "兽"),
        contextual("yu", as: "欲")
    ]

    private static let compiledRules: [(regex: NSRegularExpression, replacement: String)] =
        restorationRules.compactMap { rule in
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { return nil }
            return (regex, rule.replacement)
        }

    private static let maskedSeparatorRegex = try? NSRegularExpression(
        pattern: #"(?<=\p{Han})[*＊_＿]{1,3}(?=\p{Han})"#
    )

    static func normalize(_ value: String) -> String {
        guard !value.isEmpty else { return value }
        var result = value.precomposedStringWithCanonicalMapping

        for marker in ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}"] {
            result = result.replacingOccurrences(of: marker, with: "")
        }
        if let maskedSeparatorRegex {
            result = replaceMatches(
                in: result,
                using: maskedSeparatorRegex,
                replacement: ""
            )
        }

        for rule in compiledRules {
            let folded = result.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "zh_CN")
            )
            guard (folded as NSString).length == (result as NSString).length else { continue }
            let matches = rule.regex.matches(
                in: folded,
                range: NSRange(location: 0, length: (folded as NSString).length)
            )
            guard !matches.isEmpty else { continue }

            let mutable = NSMutableString(string: result)
            for match in matches.reversed() {
                let replacement = rule.regex.replacementString(
                    for: match,
                    in: folded,
                    offset: 0,
                    template: rule.replacement
                )
                mutable.replaceCharacters(in: match.range, with: replacement)
            }
            result = mutable as String
        }

        return result.replacingOccurrences(of: "艹", with: "操")
    }

    private static func phrase(
        _ first: String,
        _ second: String,
        as replacement: String
    ) -> ReplacementRule {
        ReplacementRule(
            pattern: "(?<![a-z])\(first)[1-5]?\(tokenSeparator)\(second)[1-5]?(?![a-z])",
            replacement: replacement
        )
    }

    private static func mixed(_ pattern: String, as replacement: String) -> ReplacementRule {
        ReplacementRule(pattern: pattern, replacement: replacement)
    }

    private static func contextual(_ pinyin: String, as replacement: String) -> ReplacementRule {
        ReplacementRule(
            pattern: "(?:(?<=\\p{Han})\(pinyin)(?![a-z])|(?<![a-z])\(pinyin)(?=\\p{Han}))",
            replacement: replacement
        )
    }

    private static func replaceMatches(
        in value: String,
        using regex: NSRegularExpression,
        replacement: String
    ) -> String {
        regex.stringByReplacingMatches(
            in: value,
            range: NSRange(location: 0, length: (value as NSString).length),
            withTemplate: replacement
        )
    }
}
