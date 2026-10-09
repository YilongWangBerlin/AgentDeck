import AgentDeckCore
import Foundation
import Observation

/// Publishing settings, stored with the other settings. Publishing is off until the user turns it on.
struct PublishSettings: Codable, Equatable {
    var isEnabled = false
    var options = PublicExportOptions()
    /// One of each kind, with no repository until the user enters one.
    var targets: [PublishTarget] = [
        PublishTarget(kind: .profile, remote: "", folder: "assets/agentdeck", strategy: .amendOwnCommit, updateReadmeBlock: true),
        PublishTarget(kind: .pages, remote: "", folder: "agentdeck", strategy: .newCommit),
    ]
    var scheduleEnabled = false
    /// Minutes after local midnight.
    var scheduleMinute = 9 * 60 + 5
    /// When false, the daily run only prepares a preview and asks for review.
    var pushScheduledWithoutReview = false
    var lastScheduledRun: Date?
    var lastPublished: Date?
}

@MainActor @Observable
final class PublishModel {
    struct TargetPreview: Identifiable {
        var preview: PublishPreview?
        var target: PublishTarget
        var error: String?
        var result: PublishResult?
        var id: UUID { target.id }
    }

    private(set) var previews: [TargetPreview] = []
    private(set) var isWorking = false
    var message: String?
    /// Set when a scheduled run prepared changes that wait for review.
    private(set) var awaitingReview = false

    @ObservationIgnored private let store: UsageStore?
    @ObservationIgnored private let publisher = Publisher(workspace: AgentDeckPaths.publishWorkspace)

    init(store: UsageStore?) {
        self.store = store
    }

    var hasChanges: Bool { previews.contains { $0.preview?.hasChanges == true } }

    /// Prepares every enabled target in AgentDeck's clones. Nothing is committed or pushed.
    func prepare(_ settings: PublishSettings) async {
        guard let store else { return }
        isWorking = true
        message = nil
        let publisher = publisher
        let targets = settings.targets.filter { $0.isEnabled && !$0.remote.trimmingCharacters(in: .whitespaces).isEmpty }
        let options = settings.options
        previews = await Task.detached(priority: .userInitiated) {
            let export = try? PublicExporter.export(store: store, options: options)
            return targets.map { target in
                guard let export else { return TargetPreview(target: target, error: "Could not read the database.") }
                do {
                    return TargetPreview(preview: try publisher.prepare(target, export: export), target: target)
                } catch {
                    return TargetPreview(target: target, error: "\(error)")
                }
            }
        }.value
        isWorking = false
        if !hasChanges, previews.allSatisfy({ $0.error == nil }) { message = "Everything is already up to date." }
    }

    /// Pushes the prepared previews. Only call after the user saw them (or opted into unreviewed
    /// scheduled pushes). Returns true when something was pushed.
    func push() async -> Bool {
        isWorking = true
        let publisher = publisher
        let current = previews
        previews = await Task.detached(priority: .userInitiated) {
            current.map { item in
                var item = item
                guard let preview = item.preview else { return item }
                do { item.result = try publisher.publish(preview) } catch { item.error = "\(error)" }
                return item
            }
        }.value
        isWorking = false
        awaitingReview = false
        message = previews.map { "\($0.target.kind == .profile ? "Profile" : "Pages"): \($0.error ?? $0.result?.note ?? "-")" }
            .joined(separator: "\n")
        return previews.contains { $0.result?.pushed == true }
    }

    /// True once a day after the chosen time, when no run happened yet today.
    static func isScheduleDue(_ settings: PublishSettings, now: Date = Date()) -> Bool {
        guard settings.isEnabled, settings.scheduleEnabled else { return false }
        let calendar = Calendar.current
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        guard minute >= settings.scheduleMinute else { return false }
        return !(settings.lastScheduledRun.map { calendar.isDate($0, inSameDayAs: now) } ?? false)
    }

    /// The daily run: prepares, then pushes only if the user opted into unreviewed pushes; otherwise
    /// asks for review. Returns true when something was pushed.
    func runSchedule(_ settings: PublishSettings) async -> Bool {
        guard !isWorking else { return false }
        await prepare(settings)
        guard hasChanges else { return false }
        if settings.pushScheduledWithoutReview { return await push() }
        awaitingReview = true
        Notifier.post(.init(title: "AgentDeck: ready to publish",
                            body: "Today's usage update is prepared. Open AgentDeck › Publish to review and push it."))
        return false
    }
}
