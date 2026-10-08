import Foundation

/// Where AgentDeck keeps its own data. Everything lives under `~/.agentdeck` so it is easy to find,
/// back up, or delete.
public enum AgentDeckPaths {
    public static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agentdeck")
    }

    public static var database: URL { home.appendingPathComponent("agentdeck.sqlite") }
    /// AgentDeck's own clones of the repositories it publishes to.
    public static var publishWorkspace: URL { home.appendingPathComponent("publish") }
}
