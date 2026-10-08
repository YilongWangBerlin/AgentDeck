import Foundation

/// A small line diff for previews (conflicting skill copies, files about to change). Not meant for
/// large inputs: both sides are cut to `limit` lines.
public enum LineDiff {
    public enum Line: Equatable, Sendable {
        case same(String), removed(String), added(String)
    }

    public static func lines(from old: String, to new: String, limit: Int = 600) -> [Line] {
        let a = Array(old.components(separatedBy: "\n").prefix(limit))
        let b = Array(new.components(separatedBy: "\n").prefix(limit))
        // Longest common subsequence table, filled from the end.
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [Line] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                result.append(.same(a[i])); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                result.append(.removed(a[i])); i += 1
            } else {
                result.append(.added(b[j])); j += 1
            }
        }
        result += a[i...].map(Line.removed) + b[j...].map(Line.added)
        return result
    }

    /// `-`/`+` lines with up to `context` unchanged lines around each change, like `diff -u` without
    /// headers. Empty when the texts are equal.
    public static func unified(from old: String, to new: String, context: Int = 2) -> String {
        let all = lines(from: old, to: new)
        let changed = all.indices.filter { if case .same = all[$0] { return false } else { return true } }
        guard !changed.isEmpty else { return "" }
        var keep = Set<Int>()
        for index in changed {
            keep.formUnion(max(0, index - context)...min(all.count - 1, index + context))
        }
        var output: [String] = []
        var previous: Int?
        for index in keep.sorted() {
            if let previous, index != previous + 1 { output.append("…") }
            switch all[index] {
            case .same(let text): output.append("  " + text)
            case .removed(let text): output.append("- " + text)
            case .added(let text): output.append("+ " + text)
            }
            previous = index
        }
        return output.joined(separator: "\n")
    }
}
