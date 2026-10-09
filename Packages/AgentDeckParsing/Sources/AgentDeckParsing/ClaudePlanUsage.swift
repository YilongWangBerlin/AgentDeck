import Foundation

/// One reading of the Claude plan's usage, as the Claude desktop app recorded it.
public struct ClaudePlanUsageSample: Equatable, Sendable {
    public var time: Date
    public var organization: String?
    /// The 5-hour window's percent used (0–100), whole numbers rounded down by Claude.
    public var fiveHourPercent: Double?
    /// The weekly window's percent used (0–100).
    public var sevenDayPercent: Double?

    public init(time: Date, organization: String?, fiveHourPercent: Double?, sevenDayPercent: Double?) {
        self.time = time
        self.organization = organization
        self.fiveHourPercent = fiveHourPercent
        self.sevenDayPercent = sevenDayPercent
    }
}

/// Reads `plan-usage-history.json`, where the Claude desktop app keeps the percentages its usage
/// card shows. It is the only local record of Claude's own numbers, and it covers use outside
/// Claude Code (claude.ai, other devices) too. See FORMATS.md section 3.4.
public enum ClaudePlanUsage {
    private struct File: Decodable {
        struct Sample: Decodable {
            struct Usage: Decodable {
                var fh: Double?
                var sd: Double?

                init(from decoder: Decoder) throws {
                    let c = try decoder.container(keyedBy: CodingKeys.self)
                    fh = c.lenient(Double.self, .fh)
                    sd = c.lenient(Double.self, .sd)
                }

                private enum CodingKeys: String, CodingKey { case fh, sd }
            }

            var t: Double?
            var org: String?
            var u: Usage?

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                t = c.lenient(Double.self, .t)
                org = c.lenient(String.self, .org)
                u = c.lenient(Usage.self, .u)
            }

            private enum CodingKeys: String, CodingKey { case t, org, u }
        }

        var samples: [Sample]?
    }

    /// Samples sorted by time. Empty when the file does not exist. Throws if it exists but cannot be read.
    public static func samples(from url: URL) throws -> [ClaudePlanUsageSample] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        return (file.samples ?? []).compactMap { sample in
            guard let t = sample.t, let usage = sample.u else { return nil }
            return ClaudePlanUsageSample(
                time: Date(timeIntervalSince1970: t / 1000), organization: sample.org,
                fiveHourPercent: usage.fh, sevenDayPercent: usage.sd
            )
        }
        .sorted { $0.time < $1.time }
    }
}
