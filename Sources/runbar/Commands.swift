import Foundation
import RunbarCore

enum Trigger: String {
    case manual, schedule, catchUp = "catch-up"
}

struct RunResult {
    var exit: Int32
    var finished: Date
    var duration: TimeInterval
}

/// Collects a run's output: appends it to the log and keeps the tail for notifications.
/// Written from the pipe's reader thread, read from main.
private final class RunOutput {
    private let lock = NSLock()
    private var tail = Data()
    private var log: FileHandle?
    private let tailLimit = 8 * 1024

    init(logPath: String) {
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        log = FileHandle(forWritingAtPath: logPath)
        log?.seekToEndOfFile()
    }

    func write(_ data: Data, toTail: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        log?.write(data)
        guard toTail else { return }
        tail.append(data)
        if tail.count > tailLimit { tail.removeFirst(tail.count - tailLimit) }
    }

    func close() -> String {
        lock.lock(); defer { lock.unlock() }
        try? log?.close()
        log = nil
        return String(decoding: tail, as: UTF8.self)
    }
}

private final class Run {
    let pid: pid_t
    let started: Date
    let trigger: Trigger
    let output: RunOutput
    let reader: FileHandle
    var exitSource: DispatchSourceProcess?
    var killTimer: DispatchWorkItem?
    var finished = false

    init(pid: pid_t, started: Date, trigger: Trigger, output: RunOutput, reader: FileHandle) {
        self.pid = pid
        self.started = started
        self.trigger = trigger
        self.output = output
        self.reader = reader
    }
}

/// Runs `command` and `scheduled` items as child processes, each in its own
/// process group so Stop reaches everything the command started.
final class Commands {
    private let paths: Paths
    private let shell: String
    private let notifier: Notifier
    private var runs: [String: Run] = [:]
    private(set) var lastResults: [String: RunResult] = [:]

    var onChange: (() -> Void)?
    var onFailure: (() -> Void)?

    init(paths: Paths, shell: String, notifier: Notifier) {
        self.paths = paths
        self.shell = shell
        self.notifier = notifier
        Files.ensureDir(paths.logsDir)
    }

    func isRunning(_ id: String) -> Bool { runs[id] != nil }
    func isStopping(_ id: String) -> Bool { runs[id]?.killTimer != nil }
    func startedAt(_ id: String) -> Date? { runs[id]?.started }
    var anyRunning: Bool { !runs.isEmpty }
    var runningCount: Int { runs.count }

    func toggle(_ item: Item) {
        if isRunning(item.id) { stop(item.id) } else { run(item, trigger: .manual) }
    }

    @discardableResult
    func run(_ item: Item, trigger: Trigger) -> Bool {
        guard runs[item.id] == nil else {
            Files.append("\(Format.stamp.string(from: Date())) \(item.id) skipped (\(trigger.rawValue)): still running\n",
                         to: paths.historyLog)
            return false
        }
        let logPath = paths.log(for: item.id)
        Files.rotateIfLarge(logPath)
        let output = RunOutput(logPath: logPath)
        let started = Date()
        output.write("\n=== \(Format.stamp.string(from: started)) \(trigger.rawValue): \(item.command)\n".data(using: .utf8)!,
                     toTail: false)

        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return false }
        let reader = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)

        var env = ProcessInfo.processInfo.environment
        for (key, value) in item.env { env[key] = value }
        env["RUNBAR_COMMAND"] = item.command
        env["RUNBAR"] = "1"

        let pid: pid_t
        do {
            pid = try spawn(Shell.wrapperArguments(shell: shell), env: env, cwd: item.directory, outFD: fds[1])
        } catch {
            close(fds[1])
            _ = output.close()
            notifier.post(title: "\(item.name) could not start", body: "\(error)", logPath: logPath)
            onFailure?()
            return false
        }
        close(fds[1])

        let run = Run(pid: pid, started: started, trigger: trigger, output: output, reader: reader)
        reader.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { output.write(data) }
        }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        // The exit event can arrive a moment before the child is reapable, so
        // wait for it there instead of polling with WNOHANG.
        source.setEventHandler { [weak self] in self?.reap(item: item, wait: true) }
        run.exitSource = source
        runs[item.id] = run
        source.resume()
        // It may have exited before the source was armed.
        reap(item: item, wait: false)
        onChange?()
        return true
    }

    func stop(_ id: String) {
        guard let run = runs[id], run.killTimer == nil else { return }
        kill(-run.pid, SIGTERM)
        let work = DispatchWorkItem { kill(-run.pid, SIGKILL) }
        run.killTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        onChange?()
    }

    func stopAll() {
        for run in runs.values { kill(-run.pid, SIGTERM) }
    }

    private func reap(item: Item, wait: Bool) {
        guard let run = runs[item.id], !run.finished else { return }
        var status: Int32 = 0
        var r: pid_t
        repeat { r = waitpid(run.pid, &status, wait ? 0 : WNOHANG) } while r == -1 && errno == EINTR
        guard r == run.pid else { return }
        run.finished = true
        run.exitSource?.cancel()
        run.killTimer?.cancel()

        // WIFEXITED / WEXITSTATUS / WTERMSIG are macros Swift cannot see.
        let signal = status & 0x7f
        let code: Int32 = signal == 0 ? (status >> 8) & 0xff : -signal
        let finished = Date()
        let duration = finished.timeIntervalSince(run.started)

        // Let the reader drain what the process wrote just before exiting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            run.reader.readabilityHandler = nil
            run.output.write("=== \(Format.exit(code)) after \(Format.duration(duration))\n".data(using: .utf8)!, toTail: false)
            let tail = run.output.close()
            try? run.reader.close()

            self.runs[item.id] = nil
            self.lastResults[item.id] = RunResult(exit: code, finished: finished, duration: duration)
            Files.append("\(Format.stamp.string(from: run.started)) \(item.id) \(run.trigger.rawValue) \(Format.exit(code)) \(Format.duration(duration))\n",
                         to: self.paths.historyLog)

            let failed = code != 0
            if failed { self.onFailure?() }
            if failed || item.output == .notify {
                self.notifier.post(
                    title: failed ? "\(item.name) failed (\(Format.exit(code)))" : "\(item.name) done",
                    body: Self.lastLines(tail, count: 5).ifEmpty("No output · \(Format.duration(duration))"),
                    logPath: self.paths.log(for: item.id))
            }
            self.onChange?()
        }
    }

    static func lastLines(_ text: String, count: Int) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(count)
            .map { $0.count > 120 ? String($0.prefix(119)) + "…" : $0 }
            .joined(separator: "\n")
    }

    // MARK: posix_spawn

    struct SpawnError: Error, CustomStringConvertible {
        var code: Int32
        var description: String { String(cString: strerror(code)) }
    }

    private func spawn(_ args: [String], env: [String: String], cwd: String, outFD: Int32) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outFD, 1)
        posix_spawn_file_actions_adddup2(&actions, outFD, 2)
        posix_spawn_file_actions_addchdir_np(&actions, cwd)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Own process group (so Stop can signal the group), no inherited fds,
        // default signal handling and an empty mask in the child.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)

        let argv = args.map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, args[0], &actions, &attr, argv, envp)
        guard rc == 0 else { throw SpawnError(code: rc) }
        return pid
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
