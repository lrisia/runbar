import AppKit
import RunbarCore

/// Fires `scheduled` items while Runbar runs. One timer per item, aimed at its
/// next fire time; sleep, wake and clock changes trigger a re-check.
///
/// Each item has a baseline: the time up to which its fires have been handled.
/// A check runs the item once if a fire time falls between the baseline and now,
/// so a timer firing late and a wake notice arriving together cannot double-run it.
final class Scheduler {
    private struct Saved: Codable {
        var baseline: Date
        var expression: String
    }

    private let paths: Paths
    private let commands: Commands
    private var items: [String: Item] = [:]
    private var saved: [String: Saved] = [:]
    private var timers: [String: Timer] = [:]
    private(set) var nextFire: [String: Date] = [:]
    /// A fire this late counts as missed rather than on time.
    private let lateAfter: TimeInterval = 90

    var onChange: (() -> Void)?

    init(paths: Paths, commands: Commands) {
        self.paths = paths
        self.commands = commands
        load()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.checkAll()
        }
        NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.checkAll()
        }
    }

    func apply(_ newItems: [Item]) {
        let scheduled = newItems.filter { $0.kind == .scheduled }
        items = Dictionary(uniqueKeysWithValues: scheduled.map { ($0.id, $0) })
        let now = Date()
        for item in scheduled {
            let expression = item.schedule?.expression ?? ""
            if saved[item.id]?.expression != expression {
                // New item or new schedule: count fires from now on.
                saved[item.id] = Saved(baseline: now, expression: expression)
            }
        }
        for id in saved.keys where items[id] == nil { saved[id] = nil }
        save()
        checkAll()
    }

    func checkAll() {
        for id in items.keys { check(id) }
        onChange?()
    }

    private func check(_ id: String) {
        timers.removeValue(forKey: id)?.invalidate()
        guard let item = items[id], let schedule = item.schedule, var state = saved[id] else { return }
        let now = Date()

        if let due = schedule.next(after: state.baseline), due <= now {
            let missed = now.timeIntervalSince(due) > lateAfter
            if !missed {
                commands.run(item, trigger: .schedule)
            } else if item.catchUp {
                commands.run(item, trigger: .catchUp)
            } else {
                Files.append("\(Format.stamp.string(from: now)) \(id) missed run at \(Format.stamp.string(from: due)) (catch_up = false)\n",
                             to: paths.historyLog)
            }
            state.baseline = now
            saved[id] = state
            save()
        }

        guard let next = schedule.next(after: state.baseline) else {
            nextFire[id] = nil
            return
        }
        nextFire[id] = next
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            self?.check(id)
            self?.onChange?()
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        timers[id] = timer
    }

    // MARK: Persistence

    private func load() {
        guard let data = FileManager.default.contents(atPath: paths.stateFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        saved = (try? decoder.decode([String: Saved].self, from: data)) ?? [:]
    }

    private func save() {
        Files.ensureDir(paths.supportDir)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(saved) {
            FileManager.default.createFile(atPath: paths.stateFile, contents: data)
        }
    }
}
