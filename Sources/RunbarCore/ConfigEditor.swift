import Foundation
import TOMLKit

/// An item filled in from the panel's form.
public struct NewItem: Equatable, Sendable {
    public var name: String
    public var kind: ItemKind
    public var command: String
    /// Empty or "~" means the default (home).
    public var directory: String = ""
    public var restart: RestartPolicy = .no
    public var autostart = false
    public var notify = false
    public var schedule = ""

    public init(name: String, kind: ItemKind, command: String) {
        self.name = name
        self.kind = kind
        self.command = command
    }
}

/// Where an item goes: the n-th `[[sections]]` table, or a new one.
public enum SectionTarget: Equatable, Sendable {
    case existing(Int)
    case new(title: String, icon: String)
}

/// Adds, changes and removes items by editing the config as text, so the
/// user's comments and layout stay as they wrote them. Callers check the
/// result with `ConfigLoader.parse` before writing it.
public enum ConfigEditor {
    /// A config id from a display name: lowercase, `-` between words, made
    /// unique against `taken` with a numeric suffix.
    public static func makeID(from name: String, taken: Set<String>) -> String {
        var base = ""
        var pendingDash = false
        for scalar in name.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                if pendingDash && !base.isEmpty { base += "-" }
                base.unicodeScalars.append(scalar)
                pendingDash = false
            } else {
                pendingDash = true
            }
        }
        if base.isEmpty { base = "item" }
        var id = base
        var n = 2
        while taken.contains(id) {
            id = "\(base)-\(n)"
            n += 1
        }
        return id
    }

    public static func adding(_ item: NewItem, id: String, to target: SectionTarget, in text: String) -> String {
        let block = (["[[sections.items]]", "id = \(quote(id))"] + fieldLines(item)).map { "  " + $0 }
        return inserting(block, to: target, in: text.components(separatedBy: "\n")).joined(separator: "\n")
    }

    /// The section index of the item with this id, or nil if the text has none.
    public static func section(ofItem id: String, in text: String) -> Int? {
        find(id, in: text.components(separatedBy: "\n"))?.section
    }

    /// Rewrites the fields the form manages and keeps everything else in the
    /// item (env, icon, comments) as it was. Moves it when `target` is another
    /// section. Nil when the id isn't in the text.
    public static func updating(_ id: String, with item: NewItem, to target: SectionTarget, in text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        guard let found = find(id, in: lines) else { return nil }
        let old = Array(lines[found.range])
        let indent = String(old[0].prefix { $0 == " " || $0 == "\t" })
        var managed: Set<String> = ["name", "kind", "command", "dir", "restart", "autostart", "output", "schedule"]
        if item.kind != .scheduled { managed.insert("catch_up") }
        var rest = removingKeys(managed, from: Array(old.dropFirst()))
        let fields = fieldLines(item).map { indent + $0 }
        let at = (rest.firstIndex { key(of: $0) == "id" }).map { $0 + 1 } ?? 0
        rest.insert(contentsOf: fields, at: at)
        let block = [old[0]] + rest

        if target == .existing(found.section) {
            lines.replaceSubrange(found.range, with: block)
            return lines.joined(separator: "\n")
        }
        lines = removingRange(found.range, from: lines)
        return inserting(block, to: target, in: lines).joined(separator: "\n")
    }

    /// The text without the item. Nil when the id isn't in it.
    public static func removing(_ id: String, in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let found = find(id, in: lines) else { return nil }
        return removingRange(found.range, from: lines).joined(separator: "\n")
    }

    // MARK: Text helpers

    /// Lines for the fields the form sets, without indent, header or id.
    static func fieldLines(_ item: NewItem) -> [String] {
        var out = [
            "name = \(quote(item.name))",
            "kind = \(quote(item.kind.rawValue))",
            "command = \(quote(item.command))",
        ]
        let dir = item.directory.trimmingCharacters(in: .whitespaces)
        if !dir.isEmpty && dir != "~" { out.append("dir = \(quote(dir))") }
        switch item.kind {
        case .service:
            if item.restart != .no { out.append("restart = \(quote(item.restart.rawValue))") }
            if item.autostart { out.append("autostart = true") }
        case .scheduled:
            out.append("schedule = \(quote(item.schedule.trimmingCharacters(in: .whitespaces)))")
            if item.notify { out.append("output = \"notify\"") }
        case .command:
            if item.notify { out.append("output = \"notify\"") }
        }
        return out
    }

    private static func inserting(_ block: [String], to target: SectionTarget, in input: [String]) -> [String] {
        var lines = input
        if case .existing(let index) = target {
            let headers = lines.indices.filter { isSectionHeader(lines[$0]) }
            if index >= 0 && index < headers.count {
                let start = headers[index]
                // The section runs until the next table that isn't one of its items.
                var end = lines.count
                for i in (start + 1)..<lines.count where startsOtherTable(lines[i]) {
                    end = i
                    break
                }
                // Insert after its last real line; comments and blank lines that
                // follow belong to whatever comes next.
                var last = end - 1
                while last > start && isBlankOrComment(lines[last]) { last -= 1 }
                lines.insert(contentsOf: [""] + block, at: last + 1)
                return lines
            }
        }
        let title: String
        let icon: String
        if case .new(let t, let i) = target { (title, icon) = (t, i) } else { (title, icon) = ("Items", "terminal") }
        while let tail = lines.last, tail.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        if !lines.isEmpty { lines.append("") }
        lines += ["[[sections]]", "title = \(quote(title))", "icon = \(quote(icon))", ""] + block + [""]
        return lines
    }

    /// An item's lines, from its `[[sections.items]]` header to its last real
    /// line, and the index of the section it is in.
    static func find(_ id: String, in lines: [String]) -> (range: ClosedRange<Int>, section: Int)? {
        var section = -1
        var i = 0
        while i < lines.count {
            if isSectionHeader(lines[i]) { section += 1 }
            guard isItemHeader(lines[i]) else {
                i += 1
                continue
            }
            var end = lines.count
            for j in (i + 1)..<lines.count where startsItemEnd(lines[j]) {
                end = j
                break
            }
            var last = end - 1
            while last > i && isBlankOrComment(lines[last]) { last -= 1 }
            if last > i {
                for j in (i + 1)...last where key(of: lines[j]) == "id" {
                    if (try? TOMLTable(string: content(lines[j])))?["id"]?.string == id {
                        return (i...last, max(section, 0))
                    }
                }
            }
            i = end
        }
        return nil
    }

    /// Drops the lines and one blank line before them, so no double gap is left.
    private static func removingRange(_ range: ClosedRange<Int>, from input: [String]) -> [String] {
        var lines = input
        var lower = range.lowerBound
        if lower > 0 && content(lines[lower - 1]).isEmpty { lower -= 1 }
        lines.removeSubrange(lower...range.upperBound)
        return lines
    }

    /// Removes `key = value` lines, including multi-line string values.
    static func removingKeys(_ keys: Set<String>, from lines: [String]) -> [String] {
        let delimiters = [String(repeating: "\"", count: 3), String(repeating: "'", count: 3)]
        var out: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            guard let k = key(of: line), keys.contains(k), let eq = line.firstIndex(of: "=") else {
                out.append(line)
                i += 1
                continue
            }
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            i += 1
            for delimiter in delimiters where value.hasPrefix(delimiter) {
                // Opened but not closed on this line: skip through the closing line.
                if value.components(separatedBy: delimiter).count - 1 < 2 {
                    while i < lines.count && !lines[i].contains(delimiter) { i += 1 }
                    i += 1
                }
            }
        }
        return out
    }

    /// The bare key of a `key = value` line.
    static func key(of line: String) -> String? {
        let c = content(line)
        guard let match = c.range(of: #"^[A-Za-z0-9_-]+(?=\s*=)"#, options: .regularExpression) else { return nil }
        return String(c[match])
    }

    /// A TOML basic string.
    public static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private static func content(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }

    static func isSectionHeader(_ line: String) -> Bool {
        content(line).range(of: #"^\[\[\s*sections\s*\]\]\s*(#.*)?$"#, options: .regularExpression) != nil
    }

    static func isItemHeader(_ line: String) -> Bool {
        content(line).range(of: #"^\[\[\s*sections\.items\s*\]\]"#, options: .regularExpression) != nil
    }

    /// A table header other than this section's items or their sub-tables.
    static func startsOtherTable(_ line: String) -> Bool {
        let c = content(line)
        guard c.hasPrefix("[") else { return false }
        if isItemHeader(c) { return false }
        return c.range(of: #"^\[\s*sections\.items\."#, options: .regularExpression) == nil
    }

    /// A table header that ends an item: anything but its own sub-tables.
    static func startsItemEnd(_ line: String) -> Bool {
        let c = content(line)
        guard c.hasPrefix("[") else { return false }
        return c.range(of: #"^\[\s*sections\.items\."#, options: .regularExpression) == nil
    }

    static func isBlankOrComment(_ line: String) -> Bool {
        let c = content(line)
        return c.isEmpty || c.hasPrefix("#")
    }
}
