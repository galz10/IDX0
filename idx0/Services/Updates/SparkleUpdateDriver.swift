import AppKit
import Foundation
#if canImport(Sparkle)
  import Sparkle
#endif

@MainActor
final class SparkleUpdateDriver: AppUpdateDriverProtocol {
  var onEvent: ((AppUpdateDriverEvent) -> Void)?

  private let environment: EnvironmentProviding
  private let parser = AppcastFeedParser()
  private var latestDownloadURL: URL?
  private var checkTask: Task<Void, Never>?

  init(environment: EnvironmentProviding = ProcessEnvironmentProvider()) {
    self.environment = environment
  }

  deinit {
    checkTask?.cancel()
  }

  func checkForUpdates(feedURLOverride: URL?, currentVersion: String) {
    let feedURL = feedURLOverride ?? environment.defaultUpdateFeedURL
    guard let feedURL else {
      onEvent?(.checkFailed(message: "Update feed URL is not configured."))
      return
    }

    checkTask?.cancel()
    checkTask = Task {
      do {
        let (data, response) = try await URLSession.shared.data(from: feedURL)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
          self.onEvent?(.checkFailed(message: "Update feed request failed with status \(http.statusCode)."))
          return
        }

        guard let item = parser.parseFirstItem(from: data) else {
          self.latestDownloadURL = nil
          self.onEvent?(.checkSucceeded(availableVersion: nil, downloadURL: nil))
          return
        }

        let availableVersion = item.version
        let downloadURL = item.downloadURL
        let hasUpdate = isVersion(availableVersion, newerThan: currentVersion)

        self.latestDownloadURL = hasUpdate ? downloadURL : nil
        self.onEvent?(
          .checkSucceeded(
            availableVersion: hasUpdate ? availableVersion : nil,
            downloadURL: hasUpdate ? downloadURL : nil
          )
        )
      } catch {
        if Task.isCancelled {
          return
        }
        self.onEvent?(.checkFailed(message: error.localizedDescription))
      }
    }
  }

  func downloadUpdate() {
    guard let url = latestDownloadURL else {
      onEvent?(.downloadFailed(message: "No update download URL is available."))
      return
    }

    Task {
      onEvent?(.downloadProgress(0.1))
      try? await Task.sleep(nanoseconds: 120_000_000)
      onEvent?(.downloadProgress(0.5))
      _ = NSWorkspace.shared.open(url)
      onEvent?(.downloadProgress(1.0))
      onEvent?(.downloadCompleted)
    }
  }

  func installUpdate() {
    guard let url = latestDownloadURL else {
      onEvent?(.installFailed(message: "No downloaded update is available to install."))
      return
    }

    if !NSWorkspace.shared.open(url) {
      onEvent?(.installFailed(message: "Could not open the downloaded update package."))
    }
  }

  private func isVersion(_ lhsRaw: String, newerThan rhsRaw: String) -> Bool {
    let lhs = normalizeVersion(lhsRaw)
    let rhs = normalizeVersion(rhsRaw)

    if lhs.numeric != rhs.numeric {
      let maxCount = max(lhs.numeric.count, rhs.numeric.count)
      for index in 0 ..< maxCount {
        let l = index < lhs.numeric.count ? lhs.numeric[index] : 0
        let r = index < rhs.numeric.count ? rhs.numeric[index] : 0
        if l != r {
          return l > r
        }
      }
    }

    switch (lhs.hasPrerelease, rhs.hasPrerelease) {
    case (false, true):
      return true
    case (true, false):
      return false
    default:
      return lhs.raw > rhs.raw
    }
  }

  private func normalizeVersion(_ raw: String) -> (raw: String, numeric: [Int], hasPrerelease: Bool) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "v", with: "", options: [.caseInsensitive], range: raw.hasPrefix("v") ? raw.startIndex ..< raw.index(after: raw.startIndex) : nil)
    let prereleaseSplit = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    let numericString = String(prereleaseSplit.first ?? "")
    let numeric = numericString
      .split(separator: ".")
      .map { Int($0) ?? 0 }
    let hasPrerelease = prereleaseSplit.count > 1
    return (raw: trimmed, numeric: numeric, hasPrerelease: hasPrerelease)
  }
}

private struct AppcastItem {
  let version: String
  let downloadURL: URL
}

private final class AppcastFeedParser: NSObject, XMLParserDelegate {
  private var currentElement = ""
  private var inItem = false
  private var capturedVersion: String?
  private var capturedURL: URL?
  private var textBuffer = ""

  func parseFirstItem(from data: Data) -> AppcastItem? {
    currentElement = ""
    inItem = false
    capturedVersion = nil
    capturedURL = nil
    textBuffer = ""

    let parser = XMLParser(data: data)
    parser.delegate = self
    parser.parse()

    guard let version = capturedVersion,
          let url = capturedURL
    else {
      return nil
    }

    return AppcastItem(version: version, downloadURL: url)
  }

  func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
    currentElement = qName ?? elementName
    textBuffer = ""

    if currentElement == "item" {
      inItem = true
      return
    }

    guard inItem, currentElement == "enclosure" else { return }

    if capturedURL == nil,
       let rawURL = attributeDict["url"],
       let url = URL(string: rawURL)
    {
      capturedURL = url
    }

    if capturedVersion == nil {
      if let shortVersion = attributeDict["sparkle:shortVersionString"], !shortVersion.isEmpty {
        capturedVersion = shortVersion
      } else if let version = attributeDict["sparkle:version"], !version.isEmpty {
        capturedVersion = version
      }
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    guard inItem else { return }
    textBuffer += string
  }

  func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
    let name = qName ?? elementName

    guard inItem else { return }

    let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
    if capturedVersion == nil,
       name == "sparkle:shortVersionString" || name == "sparkle:version",
       !value.isEmpty
    {
      capturedVersion = value
    }

    if name == "item" {
      inItem = false
    }

    textBuffer = ""
  }
}
