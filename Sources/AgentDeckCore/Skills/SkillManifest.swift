import Foundation

/// The YAML frontmatter of a SKILL.md, read with a deliberately small parser: top-level `key: value`
/// pairs, quoted scalars, and `|` / `>` block scalars. Nested values (such as `metadata`) are kept as
/// raw text. Enough to validate against both tools' rules without a YAML dependency.
public struct SkillManifest: Equatable, Sendable {
    /// Top-level keys in file order.
    public var keys: [String]
    public var values: [String: String]

    public var name: String? { values["name"].flatMap { $0.isEmpty ? nil : $0 } }
    public var description: String? { values["description"].flatMap { $0.isEmpty ? nil : $0 } }

    public enum ParseError: Error, Equatable {
        case noFrontmatter
        case unterminatedFrontmatter
    }

    public static func parse(_ text: String) throws -> SkillManifest {
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        if lines.first?.hasPrefix("\u{FEFF}") == true { lines[0].removeFirst() }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { throw ParseError.noFrontmatter }
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            throw ParseError.unterminatedFrontmatter
        }

        var manifest = SkillManifest(keys: [], values: [:])
        var index = 1
        while index < end {
            let line = lines[index]
            index += 1
            guard let first = line.first, first != " ", first != "\t", first != "#",
                  let colon = line.firstIndex(of: ":")
            else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            // Indented lines that follow belong to this key (block scalars or nested maps).
            var continuation: [String] = []
            while index < end, lines[index].first == " " || lines[index].first == "\t" || lines[index].isEmpty {
                continuation.append(lines[index])
                index += 1
            }
            while continuation.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { continuation.removeLast() }
            let trimmed = continuation.map { $0.trimmingCharacters(in: .whitespaces) }

            if value.hasPrefix("|") {
                value = trimmed.joined(separator: "\n")
            } else if value.hasPrefix(">") {
                value = trimmed.split(separator: "", omittingEmptySubsequences: false).map { $0.joined(separator: " ") }.joined(separator: "\n")
            } else if value.isEmpty {
                value = continuation.joined(separator: "\n")
            } else {
                value = unquote(([value] + trimmed).joined(separator: " "))
            }
            manifest.keys.append(key)
            manifest.values[key] = value
        }
        return manifest
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first else { return value }
        let inner = String(value.dropFirst().dropLast())
        return first == "'" ? inner.replacingOccurrences(of: "''", with: "'") : inner.replacingOccurrences(of: "\\\"", with: "\"")
    }
}

/// Which tool a finding is about.
public enum SkillTarget: String, CaseIterable, Sendable {
    case claudeCode = "Claude Code"
    case codex = "Codex"
}

public struct SkillIssue: Equatable, Sendable {
    public enum Severity: Int, Comparable, Sendable {
        case info, warning, error
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public var severity: Severity
    /// The tools the finding applies to.
    public var targets: Set<SkillTarget>
    public var message: String
}

/// Checks a manifest against each tool's rules (FORMATS.md section 4.2). Codex's own validator is
/// stricter than its loader, so its rules produce warnings, not errors.
public enum SkillValidator {
    public static let codexAllowedKeys: Set<String> = ["name", "description", "license", "allowed-tools", "metadata"]
    public static let claudeOnlyKeys: Set<String> = [
        "argument-hint", "disable-model-invocation", "user-invocable", "when_to_use", "model", "effort",
        "context", "agent", "hooks", "paths", "shell", "version",
    ]

    public static func issues(manifest: SkillManifest?, parseError: Error?, directoryName: String) -> [SkillIssue] {
        guard let manifest else {
            let reason = (parseError as? SkillManifest.ParseError) == .unterminatedFrontmatter
                ? "The frontmatter has no closing ---." : "SKILL.md has no frontmatter."
            return [SkillIssue(severity: .error, targets: Set(SkillTarget.allCases), message: reason)]
        }
        var issues: [SkillIssue] = []
        let both = Set(SkillTarget.allCases)
        if manifest.name == nil {
            issues.append(.init(severity: .error, targets: both, message: "Missing name."))
        }
        guard let description = manifest.description else {
            issues.append(.init(severity: .error, targets: both, message: "Missing description."))
            return issues
        }
        if let name = manifest.name {
            if name != directoryName {
                issues.append(.init(severity: .warning, targets: both, message: "The name \"\(name)\" differs from its folder \"\(directoryName)\"."))
            }
            if name.range(of: "^[a-z0-9-]+$", options: .regularExpression) == nil
                || name.hasPrefix("-") || name.hasSuffix("-") || name.contains("--") {
                issues.append(.init(severity: .warning, targets: [.codex], message: "Codex expects a hyphen-case name (lowercase letters, digits, single hyphens)."))
            }
            if name.count > 64 {
                issues.append(.init(severity: .warning, targets: [.codex], message: "The name is longer than 64 characters."))
            }
        }
        if description.count > 1024 {
            issues.append(.init(severity: .warning, targets: [.codex], message: "The description is \(description.count) characters; Codex allows 1024."))
        }
        if description.contains("<") || description.contains(">") {
            issues.append(.init(severity: .warning, targets: [.codex], message: "Codex rejects < or > in the description."))
        }
        let unexpected = manifest.keys.filter { !codexAllowedKeys.contains($0) }
        let claudeOnly = unexpected.filter(claudeOnlyKeys.contains)
        let unknown = unexpected.filter { !claudeOnlyKeys.contains($0) }
        if !claudeOnly.isEmpty {
            issues.append(.init(severity: .info, targets: [.codex], message: "Codex ignores \(claudeOnly.joined(separator: ", ")) (Claude Code only)."))
        }
        if !unknown.isEmpty {
            issues.append(.init(severity: .warning, targets: [.codex], message: "Keys outside Codex's allowed set: \(unknown.joined(separator: ", "))."))
        }
        return issues
    }
}
