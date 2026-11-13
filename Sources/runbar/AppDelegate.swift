import AppKit
import RunbarCore
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, PanelActions {
    private let paths = Paths()
    private let notifier = Notifier()
    private var services: Services!
    private var commands: Commands!
    private var scheduler: Scheduler!
    private var watcher: ConfigWatcher!

    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    private var hosting: NSHostingView<PanelView>!
    /// The page's natural size, last reported by SwiftUI.
    private var contentSize: CGSize?
    private var lastClosed = Date.distantPast
    /// True from show until hide starts; the panel stays visible while it fades out.
    private var panelOpen = false
    private var clickMonitor: Any?
    private var iconMonitor: Any?
    private let model = PanelModel()
    private var config: Config?
    private var configError: ConfigError?
    private var unseenFailure = false
    /// Ticks once a second while the panel is open, for running times.
    private var liveTimer: Timer?
    /// Services that ran under cmdbar's labels, started again on the first config load.
    private var startAfterMigration: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything creates Runbar's folders, or the old ones won't move.
        startAfterMigration = Migration.fromCmdbar(paths: paths)
        notifier.setUp()
        let shell = Shell.loginShell()
        services = Services(paths: paths, shell: shell, notifier: notifier)
        commands = Commands(paths: paths, shell: shell, notifier: notifier)
        scheduler = Scheduler(paths: paths, commands: commands)
        watcher = ConfigWatcher(paths: paths)

        services.onChange = { [weak self] in self?.stateChanged() }
        commands.onChange = { [weak self] in self?.stateChanged() }
        scheduler.onChange = { [weak self] in self?.stateChanged() }
        services.onFailure = { [weak self] in self?.flagFailure() }
        commands.onFailure = { [weak self] in self?.flagFailure() }

        model.actions = self
        let hosting = NSHostingView(rootView: PanelView(model: model))
        // The panel sets its own frame from the reported content size and
        // animates it; the hosting view only follows.
        hosting.sizingOptions = []
        self.hosting = hosting
        panel = FloatingPanel(content: hosting)
        panel.onClose = { [weak self] in self?.hidePanel() }
        panel.onCancel = { [weak self] in
            guard let self else { return }
            if self.model.draft != nil { self.model.show(nil) } else { self.hidePanel() }
        }
        model.onSize = { [weak self] size in self?.fitPanel(size) }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Kept for VoiceOver's press; mouse clicks are handled by iconMonitor.
        statusItem.button?.target = self
        statusIcon = statusItem.button.map(StatusIcon.init)
        statusItem.button?.action = #selector(iconPressed)
        // Open and close on mouse-down and swallow the click, the way a menu
        // does. Letting the button track it would make it clear its highlight
        // on mouse-up, after the panel had set it.
        iconMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let button = self.statusItem.button, event.window === button.window else { return event }
            // ⌘-drag moves the icon along the menu bar; the system does that
            // only if it gets the mouse-down.
            if event.modifierFlags.contains(.command) { return event }
            self.togglePanel()
            return nil
        }

        watcher.onLoad = { [weak self] result in self?.configLoaded(result) }
        watcher.start()
        updateIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        commands.stopAll()
    }

    private func configLoaded(_ result: Result<Config, ConfigError>) {
        switch result {
        case .success(let newConfig):
            config = newConfig
            configError = nil
            services.apply(newConfig.allItems)
            scheduler.apply(newConfig.allItems)
            for id in startAfterMigration where services.items[id] != nil { services.start(id) }
            startAfterMigration = []
        case .failure(let error):
            // Keep running with the last good config.
            if configError != error {
                notifier.post(title: "Runbar config error", body: error.description, logPath: nil)
            }
            configError = error
        }
        stateChanged()
    }

    private func stateChanged() {
        updateIcon()
        if panelOpen { updateModel() }
    }

    private func flagFailure() {
        if panelOpen { return }
        unseenFailure = true
        updateIcon()
    }

    // MARK: Menu bar icon

    private var iconWarning: String?
    private var statusIcon: StatusIcon?

    private func updateIcon() {
        guard let icon = statusIcon else { return }
        let active = services.states.values.filter(\.isActive).count + commands.runningCount
        let commandRunning = commands.anyRunning
        if unseenFailure || configError != nil {
            icon.update(symbol: "exclamationmark.triangle.fill", active: active,
                        commandRunning: commandRunning, failed: true)
            return
        }
        let wanted = config?.settings.icon ?? AppSettings.defaultIcon
        iconWarning = nil
        if wanted.contains("/") {
            if let image = NSImage(contentsOfFile: wanted) {
                image.size = NSSize(width: 18, height: 18)
                // A custom image has no ".fill" twin; it is dimmed while idle instead.
                icon.update(symbol: nil, custom: image, active: active,
                            commandRunning: commandRunning, failed: false)
                return
            }
            iconWarning = "Icon file not found: \(wanted)"
        } else if NSImage(systemSymbolName: wanted, accessibilityDescription: nil) == nil {
            iconWarning = "No SF Symbol named \"\(wanted)\""
        }
        let base = iconWarning == nil && !wanted.contains("/") ? wanted : AppSettings.defaultIcon
        let filled = base + ".fill"
        let useFilled = active > 0 && NSImage(systemSymbolName: filled, accessibilityDescription: nil) != nil
        icon.update(symbol: useFilled ? filled : base, active: active,
                    commandRunning: commandRunning, failed: false)
    }

    // MARK: Panel

    /// The button's action: VoiceOver's press, and the mouse-up after a
    /// ⌘-click or ⌘-drag, which only moves the icon.
    @objc private func iconPressed() {
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true { return }
        togglePanel()
    }

    @objc private func togglePanel() {
        if panelOpen {
            hidePanel()
        } else if Date().timeIntervalSince(lastClosed) > 0.25 {
            // A click on the icon first closes the panel (it loses key);
            // don't reopen it from that same click.
            showPanel()
        }
    }

    /// The status item's window in screen coordinates; the panel hangs from it.
    private var iconRect: NSRect {
        statusItem.button?.window?.frame ?? .zero
    }

    private func showPanel() {
        services.refresh()
        unseenFailure = false
        updateIcon()
        updateModel()
        // Lay out now so SwiftUI reports this content's size before the
        // panel appears (fittingSize is zero with sizingOptions = []).
        hosting.layoutSubtreeIfNeeded()
        panel.place(below: iconRect, size: contentSize ?? NSSize(width: 330, height: 200), animated: false)
        // Key without activating Runbar: the app you were in keeps focus.
        panelOpen = true
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)

        // Animated so running times roll to the next second.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            withAnimation(Motion.ui) { self?.updateModel() }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
        // Clicks in other apps close it, like a menu.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hidePanel()
        }
    }

    private func hidePanel() {
        guard panelOpen, !pickingFolder else { return }
        // Opening the folder picker made Runbar active; give focus back.
        if NSApp.isActive { NSApp.deactivate() }
        panelOpen = false
        lastClosed = Date()
        // Fade out like a menu; the icon stays lit until the panel is gone.
        // Opening again mid-fade cancels the order-out.
        panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.panelOpen else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.statusItem.button?.highlight(false)
        })
        liveTimer?.invalidate()
        liveTimer = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    private func fitPanel(_ size: CGSize) {
        guard size.height > 0 else { return }
        contentSize = size
        // Out of SwiftUI's update pass; animated only while it is on screen.
        let animate = panelOpen && panel.isVisible && !Motion.reduced
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.panel.place(below: self.iconRect, size: size, animated: animate)
        }
    }

    private func updateModel() {
        let sections = (config?.sections ?? []).enumerated().map { index, section in
            SectionModel(id: index, title: section.title, icon: section.icon, rows: section.items.map(row),
                         kinds: Set(section.items.map(\.kind.rawValue)))
        }
        if model.sections != sections { model.sections = sections }
        let error = configError?.description
        if model.configError != error { model.configError = error }
        if model.warning != iconWarning { model.warning = iconWarning }
        let login = SMAppService.mainApp.status == .enabled
        if model.launchAtLogin != login { model.launchAtLogin = login }
    }

    private func row(_ item: Item) -> RowModel {
        let id = item.id
        var row = RowModel(id: id, name: item.name, detail: "", dot: .idle, spinning: false, isOn: false,
                           control: item.kind == .service ? .toggle : .runStop,
                           canRestart: item.kind == .service, command: item.command, info: [])
        switch item.kind {
        case .service:
            let state = services.states[id] ?? .stopped
            row.isOn = state.isActive
            switch state {
            case .running(let pid):
                row.dot = .ok
                row.detail = "Running · pid \(pid)"
                if services.needsRestart(id) { row.detail += " · config changed, restart to apply" }
            case .restarting(let code):
                row.dot = .warn
                row.detail = "Restarting after \(Format.exit(code))"
            case .exited(let code):
                row.dot = code == 0 ? .idle : .fail
                row.detail = code == 0 ? "Exited" : "Failed · \(Format.exit(code))"
            case .stopped:
                row.detail = "Stopped"
            }
            if let busy = services.busy[id] {
                row.spinning = true
                row.detail = busy
                // Show where the switch is heading, not where it was.
                row.isOn = busy != "Stopping…"
            }
            row.info.append("keeps running")
            switch item.restart {
            case .onFailure: row.info.append("restarts if it fails")
            case .always: row.info.append("always restarts")
            case .no: break
            }
            if item.autostart { row.info.append("starts at login") }

        case .command, .scheduled:
            var parts: [String] = []
            if item.kind == .command { row.info.append("runs once per press") }
            if let started = commands.startedAt(id) {
                row.isOn = true
                row.spinning = true
                row.dot = .ok
                parts.append(commands.isStopping(id)
                             ? "Stopping…"
                             : "Running · \(Format.duration(Date().timeIntervalSince(started)))")
            } else if let last = commands.lastResults[id] {
                row.dot = last.exit == 0 ? .idle : .fail
                parts.append("\(Format.exit(last.exit)) at \(Format.when(last.finished))")
            } else if item.kind == .command {
                parts.append("Not run yet")
            }
            if item.kind == .scheduled {
                parts.append(scheduler.nextFire[id].map { "next \(Format.when($0))" } ?? "no next run")
                if let schedule = item.schedule {
                    row.info.append("cron \(schedule.expression)\(item.catchUp ? "" : ", no catch-up")")
                }
            }
            row.detail = parts.joined(separator: " · ")
            if item.output == .notify { row.info.append("notifies every run") }
        }
        // Only what differs from the defaults; the command is shown above it.
        let dir = Self.tildePath(item.directory)
        if dir != "~" { row.info.insert("in \(dir)", at: 0) }
        return row
    }

    private static func tildePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: PanelActions

    func saveItem(_ draft: AddDraft) -> String? {
        let path = paths.configFile
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let current: Config
        do { current = try ConfigLoader.parse(text) } catch {
            return "The config has an error. Fix it first, so Runbar doesn't change a file it can't read."
        }
        let command = draft.command.trimmingCharacters(in: .whitespacesAndNewlines)
        var name = draft.name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            let first = command.split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init) ?? "item"
            name = (first as NSString).lastPathComponent
        }
        let kind = ItemKind(rawValue: draft.kind.rawValue) ?? .command
        var item = NewItem(name: name, kind: kind, command: command)
        item.directory = draft.directory
        item.restart = draft.restartOnFailure ? (draft.restartAlways ? .always : .onFailure) : .no
        item.autostart = draft.autostart
        item.notify = draft.notify
        item.schedule = draft.schedule

        let target: SectionTarget = draft.section.map { .existing($0) }
            ?? .new(title: draft.kind.sectionTitle, icon: draft.kind.sectionIcon)
        let id: String
        let updated: String
        if let editing = draft.editing {
            guard let changed = ConfigEditor.updating(editing, with: item, to: target, in: text) else {
                return "\u{201C}\(editing)\u{201D} is no longer in the config."
            }
            id = editing
            updated = changed
        } else {
            id = ConfigEditor.makeID(from: name, taken: Set(current.allItems.map(\.id)))
            updated = ConfigEditor.adding(item, id: id, to: target, in: text)
        }
        if let error = writeConfig(updated) { return Self.formMessage(error) }
        // The watcher reloads it; show the row opened.
        model.expanded.insert(id)
        return nil
    }

    func editItem(_ id: String) {
        guard let item = item(id) else { return }
        let text = (try? String(contentsOfFile: paths.configFile, encoding: .utf8)) ?? ""
        var draft = AddDraft()
        draft.editing = id
        draft.name = item.name
        draft.command = item.command
        draft.kind = DraftKind(rawValue: item.kind.rawValue) ?? .command
        let dir = Self.tildePath(item.directory)
        draft.directory = dir == "~" ? "" : dir
        draft.schedule = item.schedule?.expression ?? ""
        draft.restartOnFailure = item.restart != .no
        draft.restartAlways = item.restart == .always
        draft.autostart = item.autostart
        draft.notify = item.output == .notify
        draft.section = ConfigEditor.section(ofItem: id, in: text) ?? 0
        model.show(draft)
    }

    /// The config before and after the last delete, for Undo.
    private var undo: (before: String, after: String)?
    private var undoTimer: DispatchWorkItem?

    func deleteItem(_ id: String) {
        let text = (try? String(contentsOfFile: paths.configFile, encoding: .utf8)) ?? ""
        guard (try? ConfigLoader.parse(text)) != nil else {
            notifier.post(title: "Runbar didn't delete it", body: "The config has an error. Fix it first.", logPath: nil)
            return
        }
        guard let updated = ConfigEditor.removing(id, in: text) else { return }
        let name = item(id)?.name ?? id
        // A running command is stopped here; a service is stopped and its
        // agent removed when the reload no longer finds it.
        commands.stop(id)
        if let error = writeConfig(updated) {
            notifier.post(title: "Runbar didn't delete it", body: error, logPath: nil)
            return
        }
        undo = (text, updated)
        withAnimation(Motion.ui) {
            model.expanded.remove(id)
            model.undoName = name
        }
        AccessibilityNotification.Announcement("Deleted \(name). Undo is available for 5 seconds.").post()
        undoTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.endUndo() }
        undoTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// Puts the deleted entry back. A service comes back stopped.
    func undoDelete() {
        defer { endUndo() }
        guard let undo else { return }
        let now = (try? String(contentsOfFile: paths.configFile, encoding: .utf8)) ?? ""
        guard now == undo.after else {
            notifier.post(title: "Runbar couldn't undo",
                          body: "The config changed after the delete. Restore the entry by hand.", logPath: nil)
            return
        }
        if let error = writeConfig(undo.before) {
            notifier.post(title: "Runbar couldn't undo", body: error, logPath: nil)
        }
    }

    private func endUndo() {
        undoTimer?.cancel()
        undoTimer = nil
        undo = nil
        withAnimation(Motion.ui) { model.undoName = nil }
    }

    /// True while the folder picker is up; the panel stays open behind it.
    private var pickingFolder = false

    func chooseFolder() {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.allowsMultipleSelection = false
        open.canCreateDirectories = true
        open.prompt = "Choose"
        let typed = (model.draft?.directory ?? "").trimmingCharacters(in: .whitespaces)
        let start = ConfigLoader.expandTilde(typed.isEmpty ? "~" : typed, home: NSHomeDirectory())
        open.directoryURL = URL(fileURLWithPath: start, isDirectory: true)
        // Above the panel, which sits at pop-up menu level.
        open.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        pickingFolder = true
        // A file dialog needs Runbar active; hidePanel hands focus back.
        NSApp.activate(ignoringOtherApps: true)
        open.begin { [weak self] response in
            guard let self else { return }
            self.pickingFolder = false
            if response == .OK, let url = open.url {
                let path = Self.tildePath(url.path)
                self.model.updateDraft { $0.directory = path }
            }
            if self.panelOpen { self.panel.makeKeyAndOrderFront(nil) }
        }
    }

    /// A loader error as the form shows it: without the item and section
    /// prefix, which only make sense when reading the file.
    private static func formMessage(_ error: String) -> String {
        let plain = error.replacingOccurrences(of: #"^Item "[^"]*" \(section \d+\): "#, with: "",
                                               options: .regularExpression)
        return plain.prefix(1).uppercased() + plain.dropFirst()
    }

    /// Checks the text loads, then saves it. Returns an error to show, or nil.
    private func writeConfig(_ text: String) -> String? {
        do { _ = try ConfigLoader.parse(text) } catch let error as ConfigError {
            return error.description
        } catch {
            return "\(error)"
        }
        let path = paths.configFile
        do {
            Files.ensureDir((path as NSString).deletingLastPathComponent)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            return "Couldn't save the config: \(error.localizedDescription)"
        }
        return nil
    }

    private func item(_ id: String) -> Item? { config?.allItems.first { $0.id == id } }

    func toggle(_ id: String) {
        guard let item = item(id) else { return }
        switch item.kind {
        case .service: services.toggle(id)
        case .command, .scheduled: commands.toggle(item)
        }
        updateModel()
    }

    func restart(_ id: String) {
        services.restart(id)
        updateModel()
    }

    func openLog(_ id: String) {
        hidePanel()
        Files.reveal(paths.log(for: id))
    }

    func copyCommand(_ id: String) {
        guard let item = item(id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.command, forType: .string)
    }

    func openConfig() {
        hidePanel()
        Files.openInEditor(paths.configFile)
    }

    func reloadConfig() { watcher.reload(force: true) }

    func openLogs() {
        hidePanel()
        Files.ensureDir(paths.logsDir)
        NSWorkspace.shared.open(URL(fileURLWithPath: paths.logsDir))
    }

    func openHistory() {
        hidePanel()
        Files.reveal(paths.historyLog)
    }

    func setLaunchAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on {
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } else {
                try service.unregister()
            }
        } catch {
            notifier.post(title: "Open at login failed", body: error.localizedDescription)
        }
        updateModel()
    }

    func quit() { NSApp.terminate(nil) }

    // MARK: URL scheme

    /// `open runbar://<action>/<id>` with action start, stop, toggle, run or restart;
    /// `open runbar://reload`, `open runbar://menu`. For Raycast, Shortcuts or a shell alias.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "runbar" {
            let action = url.host ?? ""
            if action == "reload" { watcher.reload(force: true); continue }
            if action == "menu" {
                if !panelOpen { showPanel() }
                continue
            }
            let id = url.pathComponents.dropFirst().first ?? ""
            guard let item = item(id) else {
                notifier.post(title: "Runbar: unknown item", body: url.absoluteString)
                continue
            }
            switch (action, item.kind) {
            case ("toggle", .service): services.toggle(id)
            case ("start", .service): services.refresh(); if !(services.states[id]?.isActive ?? false) { services.start(id) }
            case ("stop", .service): services.stop(id)
            case ("restart", .service): services.refresh(); services.restart(id)
            case ("toggle", _): commands.toggle(item)
            case ("run", _), ("start", _): commands.run(item, trigger: .manual)
            case ("stop", _): commands.stop(id)
            default:
                notifier.post(title: "Runbar: unknown action", body: url.absoluteString)
            }
        }
    }
}
