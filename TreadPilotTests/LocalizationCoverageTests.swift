import Foundation
import XCTest

/// Guards spec section 6: every user-facing string literal in the UI sources has a
/// String Catalog entry with a translated Hungarian value, except the format-only keys
/// that legitimately have none. Filled in by the localization pass.
///
/// Scope is deliberately narrow: only literals passed directly to `String(localized:)`
/// or `Text("...")` are extracted (see `extractedKeys(from:)`). A literal reaching the
/// catalog through SwiftUI's implicit `LocalizedStringKey` conversion — a bare
/// `Button("...")` title, a `.confirmationDialog("...")` title — is not walked by this
/// test. Widening the regex to those call sites was not part of this pass; the keys
/// still belong in the catalog (and are added by hand), this guard just does not
/// independently re-verify that subset.
final class LocalizationCoverageTests: XCTestCase {

    /// Format-only keys that legitimately have no Hungarian value: bare units and
    /// format placeholders with nothing to translate. Verified against the catalog's
    /// actual hu-less set at the time this test was written — any *other* key found
    /// with no translated hu value is a real gap, not a format key.
    static let allowedWithoutHu: Set<String> = [
        "%.1f", "%lld", "%lld bpm", "%lld dBm", "%lld+ bpm", "%lld/%lld · %@",
        "%lld–%lld bpm", ".", "TREADPILOT", "bpm", "km/h", "■",
    ]

    /// `TreadPilot/` next to `TreadPilotTests/`, resolved from this file's own path
    /// (via `#filePath`) rather than a hardcoded absolute path, so the test still
    /// finds its sources if the repo is checked out somewhere else.
    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../TreadPilotTests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("TreadPilot")
    }

    private var catalogURL: URL {
        sourceRoot.appendingPathComponent("Resources/Localizable.xcstrings")
    }

    private func swiftFiles() -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: sourceRoot,
                                              includingPropertiesForKeys: [.isRegularFileKey],
                                              options: [.skipsHiddenFiles]) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files
    }

    /// Conservative on purpose (no false positives): only a plain literal with no
    /// `\(...)` interpolation and no escaped quote is extracted. An interpolated
    /// literal's real catalog key is the runtime's own `%lld`/`%@`-substituted form,
    /// which a textual scan cannot reconstruct, so it is left untested rather than
    /// guessed at — that key is still real and still lives in the catalog, this test
    /// simply does not independently derive it from the source text.
    private static let literalPatterns: [NSRegularExpression] = [
        #"String\(localized:\s*"([^"\\\n]*)"\)"#,
        #"Text\("([^"\\\n]*)"\)"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private func extractedKeys(from source: String) -> Set<String> {
        var keys: Set<String> = []
        let range = NSRange(source.startIndex..., in: source)
        for regex in Self.literalPatterns {
            regex.enumerateMatches(in: source, range: range) { match, _, _ in
                guard let match, let literalRange = Range(match.range(at: 1), in: source) else { return }
                keys.insert(String(source[literalRange]))
            }
        }
        return keys
    }

    private func loadCatalogStrings() throws -> [String: Any] {
        let data = try Data(contentsOf: catalogURL)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any], let strings = dict["strings"] as? [String: Any] else {
            throw NSError(domain: "LocalizationCoverageTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not parse \(catalogURL.path) as a String Catalog"])
        }
        return strings
    }

    private func hasTranslatedHu(_ entry: Any) -> Bool {
        guard let entry = entry as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any],
              let hu = localizations["hu"] as? [String: Any],
              let stringUnit = hu["stringUnit"] as? [String: Any],
              let state = stringUnit["state"] as? String,
              let value = stringUnit["value"] as? String else {
            return false
        }
        return state == "translated" && !value.isEmpty
    }

    func testEveryExtractedLiteralHasATranslatedCatalogEntry() throws {
        let files = swiftFiles()
        XCTAssertFalse(files.isEmpty, "expected to find .swift sources under \(sourceRoot.path)")

        var allKeys: Set<String> = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            allKeys.formUnion(extractedKeys(from: source))
        }
        XCTAssertFalse(allKeys.isEmpty, "expected to extract at least one literal from \(sourceRoot.path)")

        let strings = try loadCatalogStrings()

        let missing = allKeys.sorted().filter { key in
            guard !Self.allowedWithoutHu.contains(key) else { return false }
            guard let entry = strings[key] else { return true }
            return !hasTranslatedHu(entry)
        }

        XCTAssertTrue(missing.isEmpty,
                      "missing a translated hu String Catalog entry for \(missing.count) key(s): "
                      + missing.map { "\"\($0)\"" }.joined(separator: ", "))
    }
}
