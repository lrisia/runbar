import AppKit
import SwiftUI

/// What the panel needs to do when a control is used. Implemented by AppDelegate.
protocol PanelActions: AnyObject {
    func toggle(_ id: String)
    func restart(_ id: String)
    func openLog(_ id: String)
    func copyCommand(_ id: String)
    func openConfig()
    func openLogs()
    func openHistory()
    func reloadConfig()
    func setLaunchAtLogin(_ on: Bool)
    func quit()
    /// Writes the draft into the config, as a new item or over the one it
    /// edits. Returns an error to show, or nil.
    func saveItem(_ draft: AddDraft) -> String?
    /// Opens the form filled in from the item's config entry.
    func editItem(_ id: String)
    /// Stops the item and removes it from the config; Undo can put it back.
    func deleteItem(_ id: String)
    func undoDelete()
    /// Shows a folder picker and puts the choice in the draft.
    func chooseFolder()
}

enum DraftKind: String, CaseIterable, Identifiable {
    case service, command, scheduled
    var id: String { rawValue }

    var title: String {
        switch self {
        case .service: "Service"
        case .command: "Command"
        case .scheduled: "Scheduled"
        }
    }

    var hint: String {
        switch self {
        case .service: "Keeps running in the background, even after Runbar quits."
        case .command: "Runs once each time you press ▶."
        case .scheduled: "Runs on a cron schedule while Runbar is open."
        }
    }

    var exampleCommand: String {
        switch self {
        case .service: "python3 -m http.server 8000"
        case .command: "brew upgrade"
        case .scheduled: "rsync -a ~/Documents/ /Volumes/Backup/Documents/"
        }
    }

    var exampleName: String {
        switch self {
        case .service: "File server"
        case .command: "Update Homebrew"
        case .scheduled: "Back up Documents"
        }
    }

    /// Title and SF Symbol for a new section holding this kind.
    var sectionTitle: String {
        switch self {
        case .service: "Services"
        case .command: "Commands"
        case .scheduled: "Scheduled"
        }
    }

    var sectionIcon: String {
        switch self {
        case .service: "server.rack"
        case .command: "terminal"
        case .scheduled: "clock"
        }
    }
}

/// The form's fields, for a new item or an edit. Kept while the panel is
/// closed, so a stray click outside doesn't lose what was typed.
struct AddDraft: Equatable {
    /// The id of the item being edited; nil for a new one.
    var editing: String?
    var name = ""
    var command = ""
    var kind = DraftKind.service
    var directory = ""
    var schedule = ""
    var restartOnFailure = true
    /// The item had `restart = "always"`; kept while the box stays ticked.
    var restartAlways = false
    var autostart = false
    var notify = false
    /// Index into the config's sections; nil makes a new one for the kind.
    var section: Int?
    var error: String?
}

struct RowModel: Identifiable, Equatable {
    enum Control: Equatable { case toggle, runStop }
    enum Dot: Equatable { case idle, ok, warn, fail }

    var id: String
    var name: String
    var detail: String
    var dot: Dot
    var spinning: Bool
    var isOn: Bool
    var control: Control
    var canRestart: Bool
    var command: String
    /// Settings from the config, shown when the row is expanded.
    var info: [String]
}

struct SectionModel: Identifiable, Equatable {
    var id: Int
    var title: String?
    var icon: String?
    var rows: [RowModel]
    /// Kinds of the items in it ("service", ...), to pick a default for new items.
    var kinds: Set<String> = []
}

final class PanelModel: ObservableObject {
    @Published var sections: [SectionModel] = []
    @Published var configError: String?
    @Published var warning: String?
    @Published var launchAtLogin = false
    @Published var expanded: Set<String> = []
    /// Non-nil while the form is showing.
    @Published private(set) var draft: AddDraft?
    /// Name of the item just deleted, while its Undo strip shows.
    @Published var undoName: String?
    /// The row whose command was just copied; its ⋯ shows a check.
    @Published private(set) var copied: String?
    weak var actions: PanelActions?
    /// Reports the content's natural size so the panel can fit it.
    var onSize: ((CGSize) -> Void)?

    func startAdding() {
        if draft == nil { show(AddDraft(section: defaultSection(for: .service))) }
    }

    /// Opens the form (non-nil) or goes back to the list (nil), sliding.
    func show(_ newDraft: AddDraft?) {
        withAnimation(Motion.page) { draft = newDraft }
    }

    /// Changes fields while the form is open; ignored once it has closed.
    func updateDraft(_ change: (inout AddDraft) -> Void) {
        guard var current = draft else { return }
        change(&current)
        draft = current
    }

    func flashCopied(_ id: String) {
        withAnimation(Motion.ui) { copied = id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard self?.copied == id else { return }
            withAnimation(Motion.ui) { self?.copied = nil }
        }
    }

    /// The first section that already holds this kind.
    func defaultSection(for kind: DraftKind) -> Int? {
        sections.first { $0.kinds.contains(kind.rawValue) }?.id
    }
}

/// One timing for every UI change, so the window and its content move
/// together. Reduce Motion swaps slides for fades and drops the rest.
enum Motion {
    static let duration = 0.2
    /// Fast start, soft landing, no overshoot.
    static let curve: (Double, Double, Double, Double) = (0.2, 0.8, 0.2, 1)

    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static var ui: Animation? {
        reduced ? nil : .timingCurve(curve.0, curve.1, curve.2, curve.3, duration: duration)
    }

    static var page: Animation {
        reduced ? .easeInOut(duration: 0.15)
            : .timingCurve(curve.0, curve.1, curve.2, curve.3, duration: duration)
    }

    static func hover(_ on: Bool) -> Animation { .easeOut(duration: on ? 0.14 : 0.2) }
}

/// Natural heights of the list and the form, measured separately so the
/// panel sizes to the page being shown, not to both while one slides out.
private struct PageSizeKey: PreferenceKey {
    static var defaultValue: [Bool: CGSize] = [:]
    static func reduce(value: inout [Bool: CGSize], nextValue: () -> [Bool: CGSize]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension View {
    func reportsSize(isForm: Bool) -> some View {
        background(GeometryReader { Color.clear.preference(key: PageSizeKey.self, value: [isForm: $0.size]) })
    }
}

// MARK: - Views

struct PanelView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        ZStack(alignment: .top) {
            if model.draft != nil {
                AddForm(model: model)
                    .padding(.vertical, 6)
                    .frame(width: 330)
                    .fixedSize(horizontal: false, vertical: true)
                    .reportsSize(isForm: true)
                    .transition(slide(from: .trailing))
            } else {
                list
                    .padding(.vertical, 6)
                    .frame(width: 330)
                    .fixedSize(horizontal: false, vertical: true)
                    .reportsSize(isForm: false)
                    .transition(slide(from: .leading))
            }
        }
        .onPreferenceChange(PageSizeKey.self) { sizes in
            if let size = sizes[model.draft != nil] { model.onSize?(size) }
        }
        // The window animates its height around the content; keep the
        // content pinned to the top while it does.
        .frame(width: 330)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    /// The form pushes in from the right and the list steps aside to the
    /// left; Back reverses it. A fade under Reduce Motion.
    private func slide(from edge: Edge) -> AnyTransition {
        Motion.reduced ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = model.configError {
                Banner(symbol: "exclamationmark.triangle.fill", color: .red,
                       title: "Config error, using the last good config", message: error,
                       action: ("Open config", { model.actions?.openConfig() }))
            }
            if let warning = model.warning {
                Banner(symbol: "exclamationmark.circle.fill", color: .orange, title: nil, message: warning)
            }

            if model.sections.allSatisfy({ $0.rows.isEmpty }) {
                Text("Nothing here yet. Press + to add one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }

            ForEach(model.sections) { section in
                if !section.rows.isEmpty {
                    SectionHeader(title: section.title, icon: section.icon)
                    ForEach(section.rows) { row in
                        Row(row: row, model: model)
                    }
                }
            }

            if let name = model.undoName {
                UndoStrip(name: name) { model.actions?.undoDelete() }
                    .transition(Motion.reduced ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }

            Divider().padding(.top, 6)
            Footer(model: model)
        }
    }
}

/// Shown for a few seconds after a delete.
private struct UndoStrip: View {
    var name: String
    var undo: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "trash")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("Deleted \u{201C}\(name)\u{201D}")
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            SmallButton(title: "Undo", action: undo)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 5)
        .padding(.top, 6)
    }
}

private struct Banner: View {
    var symbol: String
    var color: Color
    var title: String?
    var message: String
    /// A way out, such as opening the file the error is in.
    var action: (title: String, run: () -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                if let title { Text(title).font(.callout.weight(.semibold)) }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let action {
                    SmallButton(title: action.title, action: action.run)
                        .padding(.leading, -6)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }
}

private struct SectionHeader: View {
    var title: String?
    var icon: String?

    var body: some View {
        if title != nil || icon != nil {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon) }
                if let title { Text(title) }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 7)
            .padding(.bottom, 2)
        }
    }
}

private struct StatusIndicator: View {
    var dot: RowModel.Dot
    var spinning: Bool

    var body: some View {
        ZStack {
            if spinning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            } else {
                switch dot {
                case .idle: Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.2).frame(width: 8, height: 8)
                case .ok: Circle().fill(Color.green).frame(width: 8, height: 8)
                case .warn: Circle().fill(Color.orange).frame(width: 8, height: 8)
                case .fail: Circle().fill(Color.red).frame(width: 8, height: 8)
                }
            }
        }
        .frame(width: 16, height: 16)
        .animation(Motion.ui, value: dot)
        .animation(Motion.ui, value: spinning)
    }
}

private struct Row: View {
    var row: RowModel
    @ObservedObject var model: PanelModel
    @State private var hovering = false

    private var expanded: Bool { model.expanded.contains(row.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusIndicator(dot: row.dot, spinning: row.spinning)
                // A real button, so Tab and VoiceOver can open the details too.
                Button(action: toggleExpanded) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(row.name).font(.system(size: 13))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                                .opacity(hovering || expanded ? 1 : 0.45)
                        }
                        Text(row.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                            // Running times roll from one second to the next.
                            .contentTransition(.numericText())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(row.detail)
                .accessibilityLabel(row.name)
                .accessibilityValue("\(row.detail), \(expanded ? "details shown" : "details hidden")")
                .accessibilityHint("Shows the command and settings")
                Spacer(minLength: 6)
                control
                moreMenu
            }
            .contentShape(Rectangle())
            .onTapGesture { toggleExpanded() }

            if expanded {
                details.transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        // The row's height animates; clipping to it reveals the details as
        // the row opens instead of drawing them over the row below.
        .clipped()
        .background(hovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .animation(Motion.hover(hovering), value: hovering)
        .padding(.horizontal, 5)
        .onHover { hovering = $0 }
    }

    /// Animated with the same timing as the window, which grows or shrinks
    /// around the row at the same pace.
    private func toggleExpanded() {
        withAnimation(Motion.ui) {
            if expanded { model.expanded.remove(row.id) } else { model.expanded.insert(row.id) }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.command)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(6)
                .help(row.command)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.info.joined(separator: " · "))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                SmallButton(title: "Edit") { model.actions?.editItem(row.id) }
                SmallButton(title: "Delete") { model.actions?.deleteItem(row.id) }
            }
        }
        .padding(.leading, 24)
        .padding(.bottom, 2)
    }

    @ViewBuilder private var control: some View {
        switch row.control {
        case .toggle:
            Toggle(row.name, isOn: Binding(get: { row.isOn }, set: { _ in model.actions?.toggle(row.id) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(row.spinning)
        case .runStop:
            RunButton(running: row.isOn, name: row.name) { model.actions?.toggle(row.id) }
        }
    }

    private var moreMenu: some View {
        Menu {
            if row.canRestart {
                Button("Restart") { model.actions?.restart(row.id) }
                Divider()
            }
            Button("Open Log") { model.actions?.openLog(row.id) }
            Button("Copy Command") {
                model.actions?.copyCommand(row.id)
                model.flashCopied(row.id)
            }
            Divider()
            Button("Edit…") { model.actions?.editItem(row.id) }
            Button("Delete") { model.actions?.deleteItem(row.id) }
        } label: {
            // A check for a moment after Copy Command.
            Image(systemName: model.copied == row.id ? "checkmark" : "ellipsis")
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More actions for \(row.name)")
    }
}

/// Sinks slightly while held, so a click is felt before its result shows.
private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !Motion.reduced ? 0.94 : 1)
            .animation(.easeOut(duration: configuration.isPressed ? 0.09 : 0.2), value: configuration.isPressed)
    }
}

/// The keyboard focus ring for the borderless buttons, drawn on their hover
/// shape (the system ring doesn't follow it). Shows only when keyboard
/// navigation is on, since only then can these buttons take focus. Tracked
/// with FocusState: `\.isFocused` inside a ButtonStyle never changes.
private struct FocusRing: ViewModifier {
    var radius: CGFloat = 5
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .focusEffectDisabled()
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .opacity(focused ? 1 : 0)
                    .allowsHitTesting(false)
            }
    }
}

/// A text button in a row's details, lit on hover.
private struct SmallButton: View {
    var title: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(hovering ? .primary : .secondary)
                .padding(.horizontal, 6)
                .frame(minHeight: 22)
                .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .modifier(FocusRing())
        .animation(Motion.hover(hovering), value: hovering)
        .onHover { hovering = $0 }
    }
}

/// Run/stop for a command: a bare glyph, lit only on hover like the footer.
private struct RunButton: View {
    var running: Bool
    var name: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: running ? "stop.fill" : "play.fill")
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 11))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 24, height: 22)
                .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .modifier(FocusRing())
        .animation(Motion.hover(hovering), value: hovering)
        .onHover { hovering = $0 }
        .help(running ? "Stop" : "Run")
        .accessibilityLabel("\(running ? "Stop" : "Run") \(name)")
    }
}

private struct Footer: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                FooterButton(symbol: "plus", shortcut: "⌘N", help: "Add to menu") { model.startAdding() }
                    .keyboardShortcut("n", modifiers: .command)
                FooterButton(symbol: "slider.horizontal.3", shortcut: "⌘,", help: "Open config") { model.actions?.openConfig() }
                    .keyboardShortcut(",", modifiers: .command)
                FooterButton(symbol: "arrow.clockwise", shortcut: "⌘R", help: "Reload config") { model.actions?.reloadConfig() }
                    .keyboardShortcut("r", modifiers: .command)
                FooterButton(symbol: "folder", help: "Open logs folder") { model.actions?.openLogs() }
                FooterButton(symbol: "clock.arrow.circlepath", help: "Open run history") { model.actions?.openHistory() }
                Spacer()
                FooterButton(symbol: "power", shortcut: "⌘Q", help: "Quit Runbar (services keep running)") { model.actions?.quit() }
                    .keyboardShortcut("q", modifiers: .command)
            }
            Toggle("Open Runbar at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.actions?.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox)
                .font(.caption)
                .padding(.horizontal, 6)
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }
}

/// An icon button. With `shortcut`, the key is printed after the icon in plain
/// dim text, the way a menu shows it.
private struct FooterButton: View {
    var symbol: String
    var shortcut: String? = nil
    var help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 13))
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundStyle(hovering ? .secondary : .tertiary)
                }
            }
            .padding(.horizontal, shortcut == nil ? 0 : 8)
            .frame(minWidth: 28, minHeight: 24)
            .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .modifier(FocusRing())
        .animation(Motion.hover(hovering), value: hovering)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Add form

private struct AddForm: View {
    @ObservedObject var model: PanelModel
    @FocusState private var focus: Field?
    private enum Field { case name, command, schedule }

    /// Writes only while the form is open. A text field being torn down after
    /// Back commits its text through this binding; letting that through made a
    /// fresh draft and reopened the form as "Add".
    private var draft: Binding<AddDraft> {
        Binding(get: { model.draft ?? AddDraft() }, set: { new in model.updateDraft { $0 = new } })
    }
    private var d: AddDraft { model.draft ?? AddDraft() }

    private var commandEmpty: Bool {
        d.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The name used when the field is left empty: the command's first word.
    private var namePlaceholder: String {
        let first = d.command.split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init) ?? ""
        return first.isEmpty ? d.kind.exampleName : (first as NSString).lastPathComponent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Button(action: cancel) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back  Esc")
                .accessibilityLabel("Back")
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.leading, -6)

            VStack(alignment: .leading, spacing: 4) {
                Picker("Kind", selection: draft.kind) {
                    ForEach(DraftKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(d.kind.hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            field("Command") {
                TextField(d.kind.exampleCommand, text: draft.command, axis: .vertical)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1...4)
                    .focused($focus, equals: .command)
            }
            field("Name") {
                TextField(namePlaceholder, text: draft.name)
                    .focused($focus, equals: .name)
            }
            if d.kind == .scheduled {
                field("Schedule", note: "minute hour day month weekday, or @daily") {
                    TextField("0 9 * * 1-5", text: draft.schedule)
                        .font(.system(size: 12, design: .monospaced))
                        .focused($focus, equals: .schedule)
                }
            }
            field("Folder", note: "Where it runs. Empty means your home folder.") {
                HStack(spacing: 6) {
                    TextField("~", text: draft.directory)
                    Button { model.actions?.chooseFolder() } label: {
                        Image(systemName: "folder")
                    }
                    .help("Choose a folder")
                    .accessibilityLabel("Choose a folder")
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                if d.kind == .service {
                    Toggle("Restart if it fails", isOn: draft.restartOnFailure)
                    Toggle("Start at login", isOn: draft.autostart)
                } else {
                    Toggle("Notify after every run, not only on failure", isOn: draft.notify)
                }
            }
            .toggleStyle(.checkbox)

            field("Group", note: "The heading it is listed under in this menu.") {
                Picker("Group", selection: draft.section) {
                    ForEach(model.sections) { section in
                        Text(section.title ?? "Group \(section.id + 1)").tag(Optional(section.id))
                    }
                    if !model.sections.isEmpty { Divider() }
                    Text("New group \u{201C}\(d.kind.sectionTitle)\u{201D}").tag(Int?.none)
                }
                .labelsHidden()
                .fixedSize()
            }

            if let error = d.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button(d.editing == nil ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(commandEmpty || (d.kind == .scheduled && d.schedule.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .onAppear { focus = .command }
        .onExitCommand(perform: cancel)
        .onChange(of: d.kind) { _, kind in
            // A new item follows its kind; an edit stays where it is.
            if model.draft?.editing == nil {
                let section = model.defaultSection(for: kind)
                model.updateDraft { $0.section = section }
            }
        }
    }

    private func field<Content: View>(_ label: String, note: String? = nil,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
            if let note {
                Text(note).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        guard d.editing != nil else { return "Add to menu" }
        let name = d.name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Edit" : "Edit \u{201C}\(name)\u{201D}"
    }

    private func cancel() { model.show(nil) }

    private func save() {
        guard var current = model.draft else { return }
        current.error = nil
        if let error = model.actions?.saveItem(current) {
            withAnimation(Motion.ui) { model.updateDraft { $0.error = error } }
            if error.hasPrefix("Schedule") { focus = .schedule }
            AccessibilityNotification.Announcement(error).post()
        } else {
            model.show(nil)
        }
    }
}
