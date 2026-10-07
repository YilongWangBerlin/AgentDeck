import AgentDeckCore
import AgentDeckParsing
import Foundation
import Observation

/// User settings, stored in UserDefaults.
struct AppSettings: Codable, Equatable {
    var budgets = SoftBudgets()
    var alertsEnabled = false
    var alertThresholdPercent = 80.0
    /// Overrides for `$CLAUDE_CONFIG_DIR` and `$CODEX_HOME`. A GUI app does not see variables set in
    /// shell profiles, so these are set here instead. Empty means the default location.
    var claudeConfigDirectory = ""
    var codexHome = ""

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
            if settings.logLocations != oldValue.logLocations { connectLogs() }
            if settings.alertsEnabled, !oldValue.alertsEnabled { Task { await enableNotifications() } }
            recompute()
        }
    }

    @ObservationIgnored private let store: UsageStore?
    @ObservationIgnored let dashboard: DashboardModel
    @ObservationIgnored private var scanner: ScanCoordinator?
    @ObservationIgnored private var watcher: LogWatcher?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var ledger = AlertLedger.load()

    init(databaseURL: URL = AgentDeckPaths.database) {
        settings = AppSettings.load()
        do {
            store = try UsageStore(url: databaseURL)
        } catch {
            store = nil
            problem = "Could not open \(databaseURL.path): \(error.localizedDescription)"
        }
        dashboard = DashboardModel(store: store)
    }

    /// Scans on launch, then whenever the logs change, and refreshes countdowns every 30 seconds.
    func start() {
        connectLogs()
        ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recompute() }
        }
    }

    private func connectLogs() {
        guard let store else { return }
        let locations = settings.logLocations
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
        lastReport = try? Ingestor(store: store, locations: settings.logLocations).ingest()
        lastScanAt = Date()
        recompute()
        dashboard.reload()
    }

    func recompute() {
        now = Date()
        guard let store else { return }
        do {
            snapshot = try LimitsCalculator.snapshot(store: store, now: now)
        } catch {
            problem = "Could not read the database: \(error.localizedDescription)"
        }
        postDueAlerts()
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
