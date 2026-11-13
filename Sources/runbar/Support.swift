import AppKit
import RunbarCore
import UserNotifications

/// Runs a short helper (launchctl, open) and returns its output.
@discardableResult
func runTool(_ path: String, _ args: [String]) -> (status: Int32, out: String, err: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { return (-1, "", "\(error)") }
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus,
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self))
}

enum Files {
    static let maxLogBytes: UInt64 = 5 * 1024 * 1024

    static func ensureDir(_ path: String) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    /// Moves a log aside as `<name>.1` once it passes the size limit.
    static func rotateIfLarge(_ path: String) {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? UInt64, size > maxLogBytes else { return }
        let old = path + ".1"
        try? fm.removeItem(atPath: old)
        try? fm.moveItem(atPath: path, toPath: old)
    }

    static func append(_ text: String, to path: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    static func openInEditor(_ path: String) {
        // -t: the default text editor, since .toml often has no app bound to it.
        runTool("/usr/bin/open", ["-t", path])
    }

    static func reveal(_ path: String) {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

enum Format {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    static let dayTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"
        return f
    }()
    static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        return f
    }()

    static func when(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? time.string(from: date) : dayTime.string(from: date)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    static func exit(_ code: Int32) -> String {
        code < 0 ? "signal \(-code)" : "exit \(code)"
    }
}

/// Posts user notifications; clicking one opens the related log.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let enabled = Bundle.main.bundleIdentifier != nil

    func setUp() {
        guard enabled else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String, logPath: String? = nil) {
        guard enabled else {
            FileHandle.standardError.write("[notify] \(title): \(body)\n".data(using: .utf8)!)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let logPath { content.userInfo = ["log": logPath] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let log = response.notification.request.content.userInfo["log"] as? String {
            DispatchQueue.main.async { Files.reveal(log) }
        }
        completionHandler()
    }
}
