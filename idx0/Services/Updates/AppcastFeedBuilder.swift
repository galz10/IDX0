import Foundation

struct AppcastReleaseEntry: Equatable {
    var version: String
    var downloadURL: URL
    var length: Int
    var publishedAt: Date
    var prerelease: Bool
    var signature: String?
    var minimumSystemVersion: String?
    var notesURL: URL?
}

enum AppcastFeedBuilder {
    static func buildXML(
        entries: [AppcastReleaseEntry],
        title: String = "IDX0",
        includePrerelease: Bool = false
    ) -> String {
        let filtered = entries
            .filter { includePrerelease || !$0.prerelease }
            .sorted(by: sortEntries)

        guard !filtered.isEmpty else {
            return """
            <?xml version=\"1.0\" encoding=\"utf-8\"?>
            <rss version=\"2.0\" xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\">
              <channel>
                <title>\(xmlEscape("\(title) Updates"))</title>
                <description>\(xmlEscape("Latest releases for \(title)"))</description>
              </channel>
            </rss>
            """
        }

        var items: [String] = []
        for entry in filtered {
            var enclosureAttributes: [String: String] = [
                "url": entry.downloadURL.absoluteString,
                "length": "\(entry.length)",
                "type": "application/octet-stream",
                "sparkle:version": buildVersion(from: entry.version),
                "sparkle:shortVersionString": entry.version,
            ]

            if let signature = entry.signature, !signature.isEmpty {
                enclosureAttributes["sparkle:edSignature"] = signature
            }
            if let minimumSystemVersion = entry.minimumSystemVersion, !minimumSystemVersion.isEmpty {
                enclosureAttributes["sparkle:minimumSystemVersion"] = minimumSystemVersion
            }

            let enclosureText = enclosureAttributes
                .sorted(by: { $0.key < $1.key })
                .map { key, value in "\(key)=\"\(xmlEscape(value))\"" }
                .joined(separator: " ")

            var itemLines: [String] = [
                "    <item>",
                "      <title>\(xmlEscape("\(title) \(entry.version)"))</title>",
                "      <pubDate>\(xmlEscape(httpDateFormatter.string(from: entry.publishedAt)))</pubDate>",
                "      <enclosure \(enclosureText) />",
            ]

            if let notesURL = entry.notesURL {
                itemLines.append("      <sparkle:releaseNotesLink>\(xmlEscape(notesURL.absoluteString))</sparkle:releaseNotesLink>")
            }

            itemLines.append("    </item>")
            items.append(itemLines.joined(separator: "\n"))
        }

        return """
        <?xml version=\"1.0\" encoding=\"utf-8\"?>
        <rss version=\"2.0\" xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\">
          <channel>
            <title>\(xmlEscape("\(title) Updates"))</title>
            <description>\(xmlEscape("Latest releases for \(title)"))</description>
        \(items.joined(separator: "\n"))
          </channel>
        </rss>
        """
    }

    private static func sortEntries(lhs: AppcastReleaseEntry, rhs: AppcastReleaseEntry) -> Bool {
        let l = semanticVersionComponents(lhs.version)
        let r = semanticVersionComponents(rhs.version)

        if l.numeric != r.numeric {
            for index in 0..<max(l.numeric.count, r.numeric.count) {
                let lv = index < l.numeric.count ? l.numeric[index] : 0
                let rv = index < r.numeric.count ? r.numeric[index] : 0
                if lv != rv {
                    return lv > rv
                }
            }
        }

        if l.isPrerelease != r.isPrerelease {
            return !l.isPrerelease
        }

        return lhs.publishedAt > rhs.publishedAt
    }

    private static func semanticVersionComponents(_ raw: String) -> (numeric: [Int], isPrerelease: Bool) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
        let parts = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numeric = parts.first?
            .split(separator: ".")
            .map { Int($0) ?? 0 } ?? []
        return (numeric: numeric, isPrerelease: parts.count > 1)
    }

    private static func buildVersion(from version: String) -> String {
        let digits = version.compactMap { char -> String? in
            char.isNumber ? String(char) : nil
        }
        let compact = digits.joined()
        return compact.isEmpty ? version : compact
    }

    private static func xmlEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()
}
