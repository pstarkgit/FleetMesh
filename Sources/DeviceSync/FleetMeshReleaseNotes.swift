import Foundation

enum FleetMeshReleaseNotes {
    struct Entry: Equatable, Identifiable, Sendable {
        let version: String
        let date: String
        let title: String
        let changes: [String]

        var id: String { version }
    }

    static func parse(_ markdown: String) -> [Entry] {
        var entries: [Entry] = []
        var version: String?
        var date = ""
        var title = ""
        var changes: [String] = []
        var inFence = false
        var bulletOpen = false

        func flush() {
            guard let version else { return }
            entries.append(Entry(
                version: version,
                date: date,
                title: title,
                changes: changes
            ))
        }

        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                inFence.toggle()
                bulletOpen = false
                continue
            }
            if inFence { continue }
            if line.isEmpty {
                bulletOpen = false
                continue
            }
            if line.hasPrefix("## ") {
                flush()
                version = nil
                date = ""
                title = ""
                changes = []
                let heading = String(line.dropFirst(3))
                let separator = heading.contains("—") ? "—" : " - "
                var parts: [String] = []
                var remainder = Substring(heading)
                while parts.count < 2, let range = remainder.range(of: separator) {
                    parts.append(String(remainder[..<range.lowerBound]))
                    remainder = remainder[range.upperBound...]
                }
                parts.append(String(remainder))
                let fields = parts.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard let candidate = fields.first,
                      VersionIdentity.normalizedDeclaration(candidate) != nil else { continue }
                version = candidate
                date = fields.count > 1 ? fields[1] : ""
                title = fields.count > 2 ? fields[2] : ""
                bulletOpen = false
            } else if version != nil, line.hasPrefix("- ") || line.hasPrefix("* ") {
                changes.append(String(line.dropFirst(2)))
                bulletOpen = true
            } else if version != nil, bulletOpen, !changes.isEmpty {
                changes[changes.count - 1] += " " + line
            } else if version != nil, title.isEmpty, changes.isEmpty {
                title = line
            }
        }
        flush()
        return entries
    }

    static func loadBundled(
        path: String? = Bundle.main.path(forResource: "CHANGELOG", ofType: "md")
    ) -> [Entry] {
        guard let path,
              let markdown = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }
        return parse(markdown)
    }

    static func entry(for version: String, in entries: [Entry]) -> Entry? {
        entries.first { $0.version == version }
    }
}
