import XCTest

/// Folio's French and Chinese, in Localization: both have every English the other has, each translation takes the values
/// its English takes, and every English is still Folio's own.
final class LocalizationTests: XCTestCase {
    func testTranslationsMatchTheirEnglish() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("Sources/Folio")
        let sources = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        func table(_ language: String) throws -> [String: String] {
            let data = try Data(contentsOf: root.appendingPathComponent("Localization/\(language).lproj/Localizable.strings"))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }
        let french = try table("fr"), chinese = try table("zh-Hans")
        XCTAssertEqual(Set(french.keys), Set(chinese.keys))
        let specifier = #/%(?:\d+\$)?(lld|@)/#
        let values = { (text: String) in text.matches(of: specifier).map { String($0.output.1) }.sorted() }
        for (english, translated) in Array(french) + Array(chinese) {
            XCTAssertEqual(values(translated), values(english), translated)
        }
        for english in french.keys {
            for part in english.split(separator: specifier) {
                XCTAssertNotNil(sources.range(of: part), "“\(english)” isn't in Folio's code")
            }
        }
    }
}
