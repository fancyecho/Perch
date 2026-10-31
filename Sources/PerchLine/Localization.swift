import Foundation

/// The line's text, keyed by the English. Perch picks Chinese or English itself (not the system),
/// so it says which through `isChinese`; the Chinese comes from `Line-zh-Hans.strings` in the app.
public enum LineLanguage {
    @MainActor public static var isChinese: () -> Bool = { false }

    fileprivate static let chinese: [String: String] = {
        guard let url = Bundle.main.url(forResource: "Line-zh-Hans", withExtension: "strings"),
              let table = NSDictionary(contentsOf: url) as? [String: String] else { return [:] }
        return table
    }()
}

func L(_ english: String) -> String {
    let chinese = MainActor.assumeIsolated { LineLanguage.isChinese() }
    return chinese ? LineLanguage.chinese[english] ?? english : english
}
