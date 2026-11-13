import Foundation

/// Where Runbar keeps things on disk.
public struct Paths: Sendable {
    public let home: String

    public init(home: String = NSHomeDirectory()) { self.home = home }

    public var configDir: String { home + "/.config/runbar" }
    public var configFile: String { configDir + "/config.toml" }
    public var supportDir: String { home + "/Library/Application Support/runbar" }
    public var stateFile: String { supportDir + "/state.json" }
    /// Agents that should only run when started from the menu. Kept out of
    /// ~/Library/LaunchAgents so launchd does not start them at login.
    public var parkedAgentsDir: String { supportDir + "/agents" }
    public var loginAgentsDir: String { home + "/Library/LaunchAgents" }
    public var logsDir: String { home + "/Library/Logs/runbar" }
    public var historyLog: String { logsDir + "/history.log" }

    public func log(for id: String) -> String { logsDir + "/\(id).log" }

    public func agentPlist(for id: String, autostart: Bool) -> String {
        (autostart ? loginAgentsDir : parkedAgentsDir) + "/\(Launchd.label(for: id)).plist"
    }
}

public enum Launchd {
    public static let labelPrefix = "local.runbar."

    public static func label(for id: String) -> String { labelPrefix + id }

    public static func id(fromLabel label: String) -> String? {
        label.hasPrefix(labelPrefix) ? String(label.dropFirst(labelPrefix.count)) : nil
    }

    /// The agent definition for a service.
    public static func plist(for item: Item, shell: String, logPath: String) -> [String: Any] {
        var env = item.env
        env["RUNBAR_COMMAND"] = item.command
        env["RUNBAR"] = "1"

        var plist: [String: Any] = [
            "Label": label(for: item.id),
            "ProgramArguments": Shell.wrapperArguments(shell: shell),
            "EnvironmentVariables": env,
            "WorkingDirectory": item.directory,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
            "RunAtLoad": true,
        ]
        switch item.restart {
        case .no: break
        case .onFailure: plist["KeepAlive"] = ["SuccessfulExit": false]
        case .always: plist["KeepAlive"] = true
        }
        return plist
    }

    public static func plistData(for item: Item, shell: String, logPath: String) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: plist(for: item, shell: shell, logPath: logPath),
            format: .xml, options: 0)
    }

    public struct JobStatus: Equatable, Sendable {
        public var pid: Int32?
        /// Last exit status. Negative means killed by that signal.
        public var lastExit: Int32
    }

    /// Parses `launchctl list` (columns: PID, Status, Label), keeping Runbar's jobs.
    public static func parseList(_ output: String) -> [String: JobStatus] {
        var result: [String: JobStatus] = [:]
        for line in output.split(separator: "\n") {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 3, let id = id(fromLabel: String(cols[2])) else { continue }
            let pid = Int32(cols[0])
            let status = Int32(cols[1]) ?? 0
            result[id] = JobStatus(pid: pid, lastExit: status)
        }
        return result
    }
}

public enum Shell {
    /// The user's login shell, falling back to zsh.
    public static func loginShell() -> String {
        if let pw = getpwuid(getuid()), let cString = pw.pointee.pw_shell {
            let shell = String(cString: cString)
            if !shell.isEmpty, FileManager.default.isExecutableFile(atPath: shell) { return shell }
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty { return shell }
        return "/bin/zsh"
    }

    /// Runs `$RUNBAR_COMMAND` with the PATH and exports an interactive login shell
    /// sets up, then hands off to a plain shell. The hand-off matters: an interactive
    /// shell ignores SIGTERM, so stopping would otherwise wait for launchd's SIGKILL.
    public static func wrapperArguments(shell: String) -> [String] {
        [shell, "-ilc", "exec \(quote(shell)) -c \"$RUNBAR_COMMAND\""]
    }

    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
