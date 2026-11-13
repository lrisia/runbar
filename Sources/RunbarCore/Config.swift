import Foundation
import TOMLKit

public enum ItemKind: String, Decodable, Sendable {
    /// Long-running process kept by launchd. Survives Runbar quitting.
    case service
    /// Runs once when clicked.
    case command
    /// Runs on a cron schedule while Runbar is running; can also be run by hand.
    case scheduled
}

public enum RestartPolicy: String, Decodable, Sendable {
    case no
    case onFailure = "on-failure"
    case always
}

public enum OutputMode: String, Decodable, Sendable {
    /// Notify only when the run fails.
    case silent
    /// Notify after every run, with the last lines of output.
    case notify
}

/// One entry in the menu, after validation and path expansion.
public struct Item: Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: ItemKind
    public var command: String
    public var directory: String
    public var env: [String: String]
    public var restart: RestartPolicy
    public var autostart: Bool
    public var output: OutputMode
    public var schedule: CronSchedule?
    public var catchUp: Bool
    public var icon: String?
}

public struct Section: Equatable, Sendable {
    public var title: String?
    public var icon: String?
    public var items: [Item]
}

public struct AppSettings: Equatable, Sendable {
    /// SF Symbol name, or a path to an image file used as a template icon.
    public static let defaultIcon = "terminal"
    public var icon: String = AppSettings.defaultIcon
    public init() {}
}

public struct Config: Equatable, Sendable {
    public var settings = AppSettings()
    public var sections: [Section]

    public var allItems: [Item] { sections.flatMap(\.items) }
}

public struct ConfigError: Error, CustomStringConvertible, Equatable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

// MARK: - Raw TOML shape

struct RawItem: Decodable {
    var id: String
    var name: String?
    var kind: String
    var command: String
    var dir: String?
    var env: [String: String]?
    var restart: String?
    var autostart: Bool?
    var output: String?
    var schedule: String?
    var catchUp: Bool?
    var icon: String?

    enum CodingKeys: String, CodingKey {
        case id, name, kind, command, dir, env, restart, autostart, output, schedule, icon
        case catchUp = "catch_up"
    }
}

struct RawSection: Decodable {
    var title: String?
    var icon: String?
    var items: [RawItem]?
}

struct RawSettings: Decodable {
    var icon: String?
}

struct RawConfig: Decodable {
    var settings: RawSettings?
    var sections: [RawSection]?
}

// MARK: - Loading

public enum ConfigLoader {
    public static func parse(_ text: String, home: String = NSHomeDirectory()) throws -> Config {
        let raw: RawConfig
        do {
            raw = try TOMLDecoder().decode(RawConfig.self, from: text)
        } catch let error as TOMLParseError {
            throw ConfigError("TOML syntax error at line \(error.source.begin.line): \(error.description)")
        } catch let error as DecodingError {
            throw ConfigError(describe(error))
        }

        var seen = Set<String>()
        var sections: [Section] = []
        for (sIndex, rawSection) in (raw.sections ?? []).enumerated() {
            var items: [Item] = []
            for rawItem in rawSection.items ?? [] {
                let item = try validate(rawItem, home: home, where: "section \(sIndex + 1)")
                guard seen.insert(item.id).inserted else {
                    throw ConfigError("Duplicate id \"\(item.id)\"")
                }
                items.append(item)
            }
            sections.append(Section(title: rawSection.title, icon: rawSection.icon, items: items))
        }
        var settings = AppSettings()
        if let icon = raw.settings?.icon?.trimmingCharacters(in: .whitespaces), !icon.isEmpty {
            settings.icon = expandTilde(icon, home: home)
        }
        return Config(settings: settings, sections: sections)
    }

    static func validate(_ raw: RawItem, home: String, where place: String) throws -> Item {
        let id = raw.id
        func fail(_ message: String) -> ConfigError { ConfigError("Item \"\(id)\" (\(place)): \(message)") }

        guard id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else {
            throw fail("id may use only letters, digits, '.', '_' and '-'")
        }
        guard let kind = ItemKind(rawValue: raw.kind) else {
            throw fail("kind must be service, command or scheduled")
        }
        guard !raw.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw fail("command is empty")
        }

        if kind != .service {
            if raw.restart != nil { throw fail("restart applies only to kind = \"service\"") }
            if raw.autostart != nil { throw fail("autostart applies only to kind = \"service\"") }
        } else if raw.output != nil {
            throw fail("output does not apply to services; read their log instead")
        }
        if kind != .scheduled {
            if raw.schedule != nil { throw fail("schedule applies only to kind = \"scheduled\"") }
            if raw.catchUp != nil { throw fail("catch_up applies only to kind = \"scheduled\"") }
        }

        var restart = RestartPolicy.no
        if let value = raw.restart {
            guard let parsed = RestartPolicy(rawValue: value) else {
                throw fail("restart must be no, on-failure or always")
            }
            restart = parsed
        }
        var output = OutputMode.silent
        if let value = raw.output {
            guard let parsed = OutputMode(rawValue: value) else {
                throw fail("output must be silent or notify")
            }
            output = parsed
        }
        var schedule: CronSchedule?
        if kind == .scheduled {
            guard let expr = raw.schedule else { throw fail("scheduled items need a schedule") }
            do { schedule = try CronSchedule(expr) } catch let error as CronError {
                throw fail("schedule: \(error.description)")
            }
            if schedule?.next(after: Date()) == nil {
                throw fail("schedule \"\(expr)\" never fires")
            }
        }

        return Item(
            id: id,
            name: raw.name ?? id,
            kind: kind,
            command: raw.command,
            directory: expandTilde(raw.dir ?? "~", home: home),
            env: raw.env ?? [:],
            restart: restart,
            autostart: raw.autostart ?? false,
            output: output,
            schedule: schedule,
            catchUp: raw.catchUp ?? true,
            icon: raw.icon
        )
    }

    static func describe(_ error: DecodingError) -> String {
        func path(_ keys: [CodingKey]) -> String {
            keys.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let ctx):
            let at = path(ctx.codingPath)
            return "Missing \"\(key.stringValue)\"" + (at.isEmpty ? "" : " in \(at)")
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx):
            return "Wrong type at \(path(ctx.codingPath)): \(ctx.debugDescription)"
        @unknown default:
            return "\(error)"
        }
    }

    public static func expandTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }
}
