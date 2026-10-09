import AgentDeckCore
import AgentDeckParsing
import AgentDeckWidgetData
import Foundation
import Observation
import WidgetKit

/// User settings, stored in UserDefaults.
struct AppSettings: Codable, Equatable {
    var budgets = SoftBudgets()
    var alertsEnabled = false
    var alertThresholdPercent = 80.0
    /// Overrides for `$CLAUDE_CONFIG_DIR` and `$CODEX_HOME`. A GUI app does not see variables set in
    /// shell profiles, so these are set here instead. Empty means the default location.
    var claudeConfigDirectory = ""
    var codexHome = ""
    var publish = PublishSettings()
    /// The menu bar shows only the AgentDeck icon unless this is on.
    var showUsageInMenuBar = false
    var theme = Theme.classic

    init() {}

    /// Every field is optional in stored data, so settings saved by an older version keep their values
    /// when fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        budgets = (try? c.decodeIfPresent(SoftBudgets.self, forKey: .budgets)) ?? defaults.budgets
        alertsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .alertsEnabled)) ?? defaults.alertsEnabled
        alertThresholdPercent = (try? c.decodeIfPresent(Double.self, forKey: .alertThresholdPercent)) ?? defaults.alertThresholdPercent
        claudeConfigDirectory = (try? c.decodeIfPresent(String.self, forKey: .claudeConfigDirectory)) ?? defaults.claudeConfigDirectory
        codexHome = (try? c.decodeIfPresent(String.self, forKey: .codexHome)) ?? defaults.codexHome
        publish = (try? c.decodeIfPresent(PublishSettings.self, forKey: .publish)) ?? defaults.publish
        showUsageInMenuBar = (try? c.decodeIfPresent(Bool.self, forKey: .showUsageInMenuBar)) ?? defaults.showUsageInMenuBar
        theme = (try? c.decodeIfPresent(Theme.self, forKey: .theme)) ?? defaults.theme
    }

    var logLocations: LogLocations {
        var environment = ProcessInfo.processInfo.environment
        if !claudeConfigDirectory.isEmpty { environment["CLAUDE_CONFIG_DIR"] = (claudeConfigDirectory as NSString).expandingTildeInPath }
        if !codexHome.isEmpty { environment["CODEX_HOME"] = (codexHome as NSString).expandingTildeInPath }
        return LogLocations.standard(environment: environment)
    }

    private static let key = "settings.v1"

    static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }
}

/// Runs scans one at a time. Requests that arrive during a scan are folded into one follow-up scan,
/// so a burst of FSEvents costs at most two passes.
actor ScanCoordinator {
    private let ingestor: Ingestor
    private var isScanning = false
    private var rescanRequested = false

    init(ingestor: Ingestor) {
        self.ingestor = ingestor
    }

    /// Returns nil when the request was folded into a scan already running.
    func scan() async -> Result<IngestReport, Error>? {
        guard !isScanning else {
            rescanRequested = true
            return nil
        }
        isScanning = true
        defer { isScanning = false }
        var outcome: Result<IngestReport, Error>
        repeat {
            rescanRequested = false
            let ingestor = self.ingestor
            outcome = await Task.detached(priority: .utility) { Result { try ingestor.ingest() } }.value
        } while rescanRequested
        return outcome
    }
}

@MainActor @Observable
final class AppModel {
    private(set) var snapshot: LimitsSnapshot?
    private(set) var lastScanAt: Date?
    private(set) var lastReport: IngestReport?
    private(set) var problem: String?
    private(set) var now = Date()
    private(set) var notificationsDenied = false

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            Palette.theme = settings.theme
            if settings.logLocations != oldValue.logLocations { connectLogs() }
            if settings.alertsEnabled, !oldValue.alertsEnabled { Task { await enableNotifications() } }
            recompute()
        }
    }

    @ObservationIgnored private let store: UsageStore?
    @ObservationIgnored let dashboard: DashboardModel
    @ObservationIgnored let skills = SkillsModel()
    @ObservationIgnored let publishing: PublishModel
    var skillLocations: SkillLocations {
        home.map { SkillLocations.standard(logs: logLocations, homeDirectory: $0) } ?? SkillLocations.standard(logs: logLocations)
    }
    /// A stand-in home directory (`--render-menu --home`): logs, skills and the Claude app's record
    /// are read from there, and saved settings are ignored, so screenshots can use demo data.
    @ObservationIgnored let home: URL?
    var logLocations: LogLocations {
        home.map { LogLocations.standard(environment: [:], homeDirectory: $0) } ?? settings.logLocations
    }
    @ObservationIgnored private var scanner: ScanCoordinator?
    @ObservationIgnored private var watcher: LogWatcher?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var ledger = AlertLedger.load()
    /// Only the real database feeds the widget, not the scratch ones `--render-menu` uses.
    @ObservationIgnored private let feedsWidget: Bool
    @ObservationIgnored private var lastWidgetSnapshot: WidgetSnapshot?
    @ObservationIgnored private var lastWidgetReload = Date.distantPast

    init(databaseURL: URL = AgentDeckPaths.database, home: URL? = nil) {
        self.home = home
        let settings = home == nil ? AppSettings.load() : AppSettings()
        self.settings = settings
        Palette.theme = settings.theme
        feedsWidget = databaseURL == AgentDeckPaths.database
        do {
            store = try UsageStore(url: databaseURL)
        } catch {
            store = nil
            problem = "Could not open \(databaseURL.path): \(error.localizedDescription)"
        }
        dashboard = DashboardModel(store: store)
        publishing = PublishModel(store: store)
    }

    /// Scans on launch, then whenever the logs change, and refreshes countdowns every 30 seconds.
    func start() {
        connectLogs()
        ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recompute()
                await self?.runPublishScheduleIfDue()
            }
        }
    }

    private func connectLogs() {
        guard let store else { return }
        let locations = logLocations
        scanner = ScanCoordinator(ingestor: Ingestor(store: store, locations: locations))
        watcher?.stop()
        watcher = LogWatcher(directories: locations.claudeProjectDirectories + locations.codexSessionDirectories) { [weak self] in
            Task { @MainActor in await self?.scan() }
        }
        watcher?.start()
        Task { await scan() }
    }

    func scan() async {
        guard let scanner, let outcome = await scanner.scan() else { return }
        switch outcome {
        case .success(let report):
            lastReport = report
            lastScanAt = Date()
            problem = report.failures.isEmpty ? nil : "\(report.failures.count) log file(s) could not be read."
        case .failure(let error):
            problem = "Scan failed: \(error.localizedDescription)"
        }
        recompute()
        dashboard.reload()
    }

    /// For `--render-menu`: one blocking scan on the calling thread.
    func scanNow() {
        guard let store else { return }
        lastReport = try? Ingestor(store: store, locations: logLocations).ingest()
        lastScanAt = Date()
        recompute()
        dashboard.reload()
    }

    /// For `--render-menu --now`: render the menu as it looked at another moment.
    @ObservationIgnored var clockOverride: Date?

    func recompute() {
        now = clockOverride ?? Date()
        guard let store else { return }
        do {
            // Small (tens of KB), and rewritten by the Claude app on its own schedule, so read it each time.
            let planUsage = (try? logLocations.claudePlanUsageFile.map(ClaudePlanUsage.samples)) ?? []
            snapshot = try LimitsCalculator.snapshot(store: store, now: now, planUsage: planUsage)
        } catch {
            problem = "Could not read the database: \(error.localizedDescription)"
        }
        postDueAlerts()
        updateWidget()
    }

    // MARK: - Widget

    /// Writes what the desktop widget shows and asks WidgetKit to redraw, but only when something
    /// changed, and at most every few minutes: macOS rations reloads, and the widget also rereads
    /// the file on its own schedule. Countdowns run in the widget without reloads.
    private func updateWidget() {
        guard feedsWidget, let store, let snapshot else { return }
        let calendar = LocalCalendar()
        let interval = WidgetSnapshotBuilder.recordInterval(calendar: calendar, now: now)
        guard let records = try? store.usage(in: interval) else { return }
        let widget = WidgetSnapshotBuilder.make(limits: snapshot, budgets: settings.budgets, records: records,
                                                calendar: calendar, now: now)
        var comparable = widget
        comparable.generatedAt = .distantPast
        guard comparable != lastWidgetSnapshot else { return }
        do {
            try widget.write()
            lastWidgetSnapshot = comparable
            if now.timeIntervalSince(lastWidgetReload) >= 180 {
                lastWidgetReload = now
                WidgetCenter.shared.reloadTimelines(ofKind: "AgentDeckUsage")
            }
        } catch {
            problem = "Could not update the widget: \(error.localizedDescription)"
        }
    }

    private func runPublishScheduleIfDue() async {
        guard PublishModel.isScheduleDue(settings.publish) else { return }
        settings.publish.lastScheduledRun = Date()
        await scan()
        if await publishing.runSchedule(settings.publish) {
            settings.publish.lastPublished = Date()
        }
    }

    var gauges: [LimitGauge] {
        snapshot.map { LimitGauge.gauges(for: $0, budgets: settings.budgets) } ?? []
    }

    func gauge(_ kind: LimitGauge.Kind) -> LimitGauge? {
        gauges.first { $0.kind == kind }
    }

    // MARK: - Alerts

    private func enableNotifications() async {
        notificationsDenied = !(await Notifier.requestAuthorization())
    }

    private func postDueAlerts() {
        guard settings.alertsEnabled, let snapshot else { return }
        let due = ledger.due(gauges, threshold: settings.alertThresholdPercent / 100)
        ledger.save()
        for gauge in due {
            Notifier.post(MenuText.alert(for: gauge, snapshot: snapshot))
        }
    }

    // MARK: - Menu bar title

    /// `CC ~54M 2h47  CX 88% 3h05`. `~` marks Claude's estimate; a dash means no running window.
    var menuBarTitle: String {
        guard let snapshot else { return "AgentDeck" }
        var claude = "CC –"
        if let window = snapshot.claude.window, window.end > now {
            let used = gauge(.claudeFiveHour)?.fraction.map { "\(Int(($0 * 100).rounded()))%" }
                ?? "~" + Formatting.compactTokens(snapshot.claude.tokensInWindow)
            claude = "CC \(used) \(Formatting.shortDuration(window.end.timeIntervalSince(now)))"
        } else if let report = snapshot.claude.appFiveHour {
            // A window started outside Claude Code: Claude's percentage, reset time unknown.
            claude = "CC \(Int(report.usedPercent.rounded()))%"
        }
        var codex = "CX –"
        if let window = snapshot.codex.fiveHour, case .current(let percent) = window.status(at: now) {
            codex = "CX \(Int(percent.rounded()))% \(Formatting.shortDuration(window.resetsAt.timeIntervalSince(now)))"
        }
        return "\(claude)  \(codex)"
    }
}

extension AlertLedger {
    private static let key = "alertLedger.v1"

    static func load(from defaults: UserDefaults = .standard) -> AlertLedger {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(AlertLedger.self, from: $0) } ?? AlertLedger()
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }
}
