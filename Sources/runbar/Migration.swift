import Foundation
import RunbarCore

/// Runbar was called cmdbar. On the first launch after the rename this moves
/// cmdbar's config, logs and state to Runbar's folders and unloads services
/// still running under cmdbar's launchd labels, so Runbar can start them
/// again under its own.
enum Migration {
    private static let oldName = "cmdbar"
    private static let oldLabelPrefix = "local.\(oldName)."

    /// Ids of the services that were running before, to start again once
    /// the config is loaded. Empty when there is nothing of cmdbar's left.
    static func fromCmdbar(paths: Paths) -> [String] {
        let fm = FileManager.default
        let oldConfig = paths.home + "/.config/\(oldName)"
        let oldSupport = paths.home + "/Library/Application Support/\(oldName)"
        let oldLogs = paths.home + "/Library/Logs/\(oldName)"
        let oldLoginAgents = ((try? fm.contentsOfDirectory(atPath: paths.loginAgentsDir)) ?? [])
            .filter { $0.hasPrefix(oldLabelPrefix) }
        let jobs = runTool("/bin/launchctl", ["list"]).out.split(separator: "\n")
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false) }
            .filter { $0.count >= 3 && $0[2].hasPrefix(oldLabelPrefix) }
        guard [oldConfig, oldSupport, oldLogs].contains(where: { fm.fileExists(atPath: $0) })
            || !oldLoginAgents.isEmpty || !jobs.isEmpty
        else { return [] }

        let domain = "gui/\(getuid())"
        var running: [String] = []
        for cols in jobs {
            let label = String(cols[2])
            if Int32(cols[0]) != nil { running.append(String(label.dropFirst(oldLabelPrefix.count))) }
            let target = "\(domain)/\(label)"
            guard runTool("/bin/launchctl", ["bootout", target]).status == 0 else { continue }
            // bootout returns before the process has exited.
            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline, runTool("/bin/launchctl", ["print", target]).status == 0 {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }

        for name in oldLoginAgents { try? fm.removeItem(atPath: paths.loginAgentsDir + "/" + name) }
        // Agent definitions carry the old label and log path; Runbar writes
        // new ones when it starts a service.
        try? fm.removeItem(atPath: oldSupport + "/agents")
        try? fm.removeItem(atPath: oldSupport + "/loaded")

        move(oldConfig, to: paths.configDir)
        move(oldSupport, to: paths.supportDir)
        move(oldLogs, to: paths.logsDir)
        return running
    }

    /// Leaves the old folder alone if Runbar already has its own.
    private static func move(_ from: String, to: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: from), !fm.fileExists(atPath: to) else { return }
        try? fm.moveItem(atPath: from, toPath: to)
    }
}
