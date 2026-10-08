import Foundation

/// Runs the local `git`. Apps started from Finder get a minimal PATH, so the binary is looked up in
/// the usual places instead of relying on it.
public enum Git {
    public struct Failure: Error, CustomStringConvertible {
        public var arguments: [String]
        public var status: Int32
        public var output: String
        public var description: String { "git \(arguments.joined(separator: " ")) failed (\(status)): \(output)" }
    }

    static let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]

    public static var executable: URL? {
        candidates.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Runs `git <arguments>` in `directory` and returns its standard output, trimmed.
    @discardableResult
    public static func run(_ arguments: [String], in directory: URL) throws -> String {
        guard let executable else {
            throw Failure(arguments: arguments, status: -1, output: "git was not found")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0" // never hang waiting for a password prompt
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            let message = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(arguments: arguments, status: process.terminationStatus, output: message.isEmpty ? text : message)
        }
        return text
    }

    public static func isRepository(_ directory: URL) -> Bool {
        (try? run(["rev-parse", "--is-inside-work-tree"], in: directory)) == "true"
    }
}
