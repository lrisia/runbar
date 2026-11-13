import Foundation
import RunbarCore

enum ServiceState: Equatable {
    case stopped
    case running(pid: Int32)
    /// Loaded in launchd but not running and not coming back on its own.
    case exited(code: Int32)
    /// Exited; launchd will start it again (KeepAlive).
    case restarting(code: Int32)

    var isActive: Bool {
        switch self {
        case .running, .restarting: return true
        case .stopped, .exited: return false
        }
    }
}

/// Starts and stops `kind = "service"` items as launchd agents and tracks their state.
/// No polling: state is read when the menu opens, after an action, and when a
/// watched process exits.
final class Services {
    private let paths: Paths
    private let shell: String
    private let notifier: Notifier
    private let domain = "gui/\(getuid())"
    private let actionQueue = DispatchQueue(label: "runbar.launchctl")

    private(set) var items: [String: Item] = [:]
    private(set) var states: [String: ServiceState] = [:]
    private var watchers: [String: (pid: Int32, source: DispatchSourceProcess)] = [:]
    private var lastFailureNotice: [String: Date] = [:]
    /// Ids with an action in flight, shown as "Starting…"/"Stopping…".
    private(set) var busy: [String: String] = [:]

    var onChange: (() -> Void)?
    /// Called when a service fails, for the menu bar icon.
    var onFailure: (() -> Void)?

    init(paths: Paths, shell: String, notifier: Notifier) {
        self.paths = paths
        self.shell = shell
        self.notifier = notifier
        Files.ensureDir(paths.parkedAgentsDir)
        Files.ensureDir(paths.loginAgentsDir)
        Files.ensureDir(paths.logsDir)
        Files.ensureDir(loadedRecordDir)
    }

    private var loadedRecordDir: String { paths.supportDir + "/loaded" }
    private func loadedRecord(_ id: String) -> String { loadedRecordDir + "/\(id).plist" }

    private func plistData(_ item: Item) -> Data? {
        try? Launchd.plistData(for: item, shell: shell, logPath: paths.log(for: item.id))
    }

    // MARK: Config sync

    /// Applies a new config: refreshes login agents and removes services that left the config.
    func apply(_ newItems: [Item]) {
        let services = newItems.filter { $0.kind == .service }
        items = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) })
        let fm = FileManager.default
        let jobs = listJobs()

        for item in services {
            let login = paths.agentPlist(for: item.id, autostart: true)
            if item.autostart {
                if let data = plistData(item), fm.contents(atPath: login) != data {
                    fm.createFile(atPath: login, contents: data)
                }
                // Not loaded now: next login loads exactly this file.
                if jobs[item.id] == nil, let data = plistData(item) {
                    fm.createFile(atPath: loadedRecord(item.id), contents: data)
                }
                try? fm.removeItem(atPath: paths.agentPlist(for: item.id, autostart: false))
            } else {
                try? fm.removeItem(atPath: login)
            }
        }

        // Anything of ours that is no longer a service in the config goes away.
        var known = Set<String>()
        for dir in [paths.loginAgentsDir, paths.parkedAgentsDir] {
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".plist") {
                if let id = Launchd.id(fromLabel: String(name.dropLast(6))) { known.insert(id) }
            }
        }
        known.formUnion(jobs.keys)
        for id in known where items[id] == nil {
            runTool("/bin/launchctl", ["bootout", "\(domain)/\(Launchd.label(for: id))"])
            try? fm.removeItem(atPath: paths.agentPlist(for: id, autostart: true))
            try? fm.removeItem(atPath: paths.agentPlist(for: id, autostart: false))
            try? fm.removeItem(atPath: loadedRecord(id))
        }
        refresh()
    }

    // MARK: State

    private func listJobs() -> [String: Launchd.JobStatus] {
        Launchd.parseList(runTool("/bin/launchctl", ["list"]).out)
    }

    /// Reads launchd's view of every service (one `launchctl list` call).
    func refresh() {
        let jobs = listJobs()
        var newStates: [String: ServiceState] = [:]
        for (id, item) in items {
            guard let job = jobs[id] else {
                newStates[id] = .stopped
                continue
            }
            if let pid = job.pid {
                newStates[id] = .running(pid: pid)
            } else {
                let comesBack = item.restart == .always || (item.restart == .onFailure && job.lastExit != 0)
                newStates[id] = comesBack ? .restarting(code: job.lastExit) : .exited(code: job.lastExit)
            }
        }

        for (id, state) in newStates {
            let old = states[id]
            if case .running = old {
                switch state {
                case .exited(let code) where code != 0, .restarting(let code) where code != 0:
                    noticeFailure(id: id, code: code)
                default: break
                }
            }
            if case .running(let pid) = state { watch(id: id, pid: pid) } else { unwatch(id) }
        }
        for id in watchers.keys where newStates[id] == nil { unwatch(id) }

        let changed = newStates != states
        states = newStates
        if changed { onChange?() }
    }

    /// True when the service runs with an older definition than the config now gives.
    func needsRestart(_ id: String) -> Bool {
        guard let item = items[id], let state = states[id], state.isActive,
              let record = FileManager.default.contents(atPath: loadedRecord(id))
        else { return false }
        return record != plistData(item)
    }

    private func noticeFailure(id: String, code: Int32) {
        onFailure?()
        let now = Date()
        if let last = lastFailureNotice[id], now.timeIntervalSince(last) < 60 { return }
        lastFailureNotice[id] = now
        let name = items[id]?.name ?? id
        let restarting = items[id].map { $0.restart != .no } ?? false
        notifier.post(title: "\(name) stopped (\(Format.exit(code)))",
                      body: restarting ? "launchd will restart it." : "Click to open its log.",
                      logPath: paths.log(for: id))
    }

    private func watch(id: String, pid: Int32) {
        if watchers[id]?.pid == pid { return }
        unwatch(id)
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in self?.processExited(id: id) }
        source.resume()
        watchers[id] = (pid, source)
        // It may have died before the source was armed.
        if kill(pid, 0) != 0 && errno == ESRCH { processExited(id: id) }
    }

    private func unwatch(_ id: String) {
        watchers.removeValue(forKey: id)?.source.cancel()
    }

    private func processExited(id: String) {
        unwatch(id)
        // launchd needs a moment to record the exit; check again after its
        // 10 s restart throttle to catch a KeepAlive restart.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refresh() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 11) { [weak self] in self?.refresh() }
    }

    // MARK: Actions

    func toggle(_ id: String) {
        guard let state = states[id] else { return }
        state.isActive ? stop(id) : start(id)
    }

    func start(_ id: String) {
        guard let item = items[id], busy[id] == nil, let data = plistData(item) else { return }
        let fm = FileManager.default
        let plistPath = paths.agentPlist(for: id, autostart: item.autostart)
        Files.rotateIfLarge(paths.log(for: id))
        fm.createFile(atPath: plistPath, contents: data)
        fm.createFile(atPath: loadedRecord(id), contents: data)
        let label = "\(domain)/\(Launchd.label(for: id))"
        let loaded = states[id].map { $0 != .stopped } ?? false

        perform(id, label: "Starting…", settle: 1.5) {
            if loaded {
                // Loaded but dead: drop the old definition so the new one takes effect.
                self.bootout(label)
            }
            return runTool("/bin/launchctl", ["bootstrap", self.domain, plistPath])
        }
    }

    func stop(_ id: String) {
        guard busy[id] == nil else { return }
        let label = "\(domain)/\(Launchd.label(for: id))"
        // bootout, not kill: killing a KeepAlive job only gets it restarted.
        perform(id, label: "Stopping…") { self.bootout(label) }
    }

    /// `launchctl bootout` returns before the process has exited, and launchd
    /// keeps listing the job (and refuses to bootstrap it again) until then.
    /// Waits for the job to go, up to launchd's 20 s exit timeout plus a margin,
    /// so the row stays "Stopping…" and a restart can load the new definition.
    /// Runs on `actionQueue`.
    @discardableResult
    private func bootout(_ label: String) -> (status: Int32, out: String, err: String) {
        let result = runTool("/bin/launchctl", ["bootout", label])
        guard result.status == 0 else { return result }
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline, runTool("/bin/launchctl", ["print", label]).status == 0 {
            Thread.sleep(forTimeInterval: 0.1)
        }
        return result
    }

    func restart(_ id: String) {
        guard let state = states[id] else { return }
        if state == .stopped { start(id); return }
        guard let item = items[id], busy[id] == nil else { return }
        if needsRestart(id) {
            busy[id] = "Restarting…"
            onChange?()
            actionQueue.async {
                self.bootout("\(self.domain)/\(Launchd.label(for: id))")
                DispatchQueue.main.async {
                    self.busy[id] = nil
                    self.states[id] = .stopped
                    self.start(item.id)
                }
            }
        } else {
            let label = "\(domain)/\(Launchd.label(for: id))"
            perform(id, label: "Restarting…", settle: 1.5) { runTool("/bin/launchctl", ["kickstart", "-k", label]) }
        }
    }

    /// Runs a launchctl action off the main thread. `settle` keeps the row busy a
    /// little longer after a start, so a command that dies at once shows as failed
    /// instead of flashing "running".
    private func perform(_ id: String, label: String, settle: TimeInterval = 0,
                         _ work: @escaping () -> (status: Int32, out: String, err: String)) {
        busy[id] = label
        onChange?()
        actionQueue.async {
            let result = work()
            DispatchQueue.main.async {
                if result.status != 0 {
                    let name = self.items[id]?.name ?? id
                    let detail = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.notifier.post(title: "\(name): launchctl failed",
                                       body: detail.isEmpty ? "exit \(result.status)" : detail)
                }
                let finish = {
                    self.busy[id] = nil
                    self.refresh()
                    self.onChange?()
                }
                if result.status == 0 && settle > 0 {
                    self.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: finish)
                } else {
                    finish()
                }
            }
        }
    }
}
