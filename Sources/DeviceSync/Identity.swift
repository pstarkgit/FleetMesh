import Foundation

enum FleetMeshBuildIdentity {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? DeviceSyncVersion.current
    }

    static var commit: String? {
        guard let value = (Bundle.main.object(forInfoDictionaryKey: "DSCommit") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    static var footerLabel: String { footerLabel(version: version) }

    static func footerLabel(version: String) -> String { "FleetMesh \(version)" }

    static var detail: String {
        commit.map { "FleetMesh \(version) · \($0)" } ?? footerLabel
    }
}

enum FleetComponentPaths {
    static func sourceCheckout(componentID: String, homeURL: URL) -> URL? {
        let relativePath: String
        switch componentID {
        case FleetMeshIdentity.componentID: relativePath = "code/device-sync"
        case "authbar": relativePath = "code/authbar"
        case "stow": relativePath = "code/Stow"
        case "murmr-voice": relativePath = "code/Murmur"
        case "model-bridge": relativePath = "code/ModelBridge"
        case "ai-continuum": relativePath = "code/ai-continuum"
        case "harness-sync": relativePath = "harness-sync"
        default: return nil
        }
        return homeURL.appendingPathComponent(relativePath, isDirectory: true)
    }
}

enum RevisionIdentity {
    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
    }

    static func provesSameBuild(_ observation: ComponentObservation) -> Bool {
        guard let installedRevision = observation.installedRevision,
              let sourceRevision = observation.sourceRevision else { return false }
        if matches(installedRevision.lowercased(), sourceRevision.lowercased()) { return true }
        guard let installedTree = fullObjectID(observation.installedTree),
              let sourceTree = fullObjectID(observation.sourceTree) else { return false }
        return installedTree == sourceTree
    }

    private static func fullObjectID(_ value: String?) -> String? {
        guard let value,
              value.count == 40,
              value.unicodeScalars.allSatisfy(
                CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains
              ) else { return nil }
        return value.lowercased()
    }
}

enum VersionIdentity {
    private static let pattern = #"(?<![A-Za-z0-9_])[vV]?\d+(?:\.\d+){1,3}(?:[-+][A-Za-z0-9.-]+)?\b"#
    private static let declarationPattern = #"^[vV]?\d+(?:\.\d+){1,3}(?:[-+][A-Za-z0-9.-]+)?$"#

    static func extract(from value: String, fallbackLimit: Int? = nil) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: trimmed,
                range: NSRange(trimmed.startIndex..., in: trimmed)
              ),
              let range = Range(match.range, in: trimmed) else {
            guard let fallbackLimit else { return trimmed }
            return String(trimmed.prefix(fallbackLimit))
        }
        var version = String(trimmed[range])
        if version.first == "v" || version.first == "V" {
            version.removeFirst()
        }
        return version
    }

    static func normalizedDeclaration(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.range(of: declarationPattern, options: .regularExpression) != nil else {
            return nil
        }
        return extract(from: trimmed)
    }

    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = normalizedDeclaration(lhs),
              let right = normalizedDeclaration(rhs) else { return false }
        return left == right
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let normalizedLeft = normalizedDeclaration(lhs),
              let normalizedRight = normalizedDeclaration(rhs),
              let left = ParsedVersion(normalizedLeft),
              let right = ParsedVersion(normalizedRight) else { return nil }
        return left.compare(to: right)
    }
}

private struct ParsedVersion {
    let numbers: [Int]
    let prerelease: String?

    init?(_ rawValue: String) {
        let withoutBuild = rawValue.split(separator: "+", maxSplits: 1).first.map(String.init)
            ?? rawValue
        let pieces = withoutBuild.split(separator: "-", maxSplits: 1).map(String.init)
        let numericPieces = pieces[0].split(separator: ".").map(String.init)
        guard (2...4).contains(numericPieces.count),
              numericPieces.allSatisfy({ Int($0) != nil }) else { return nil }
        numbers = numericPieces.compactMap(Int.init)
        prerelease = pieces.count > 1 ? pieces[1] : nil
    }

    func compare(to other: ParsedVersion) -> ComparisonResult {
        let width = max(numbers.count, other.numbers.count)
        for index in 0..<width {
            let lhs = index < numbers.count ? numbers[index] : 0
            let rhs = index < other.numbers.count ? other.numbers[index] : 0
            if lhs != rhs { return lhs < rhs ? .orderedAscending : .orderedDescending }
        }
        switch (prerelease, other.prerelease) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (lhs?, rhs?):
            return lhs.compare(rhs, options: [.numeric, .caseInsensitive])
        }
    }
}
