import Foundation
import Testing
@testable import RunbarCore

// MARK: - Cron

private func date(_ s: String) -> Date {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "Asia/Bangkok")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.date(from: s)!
}

private var bangkok: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Bangkok")!
    return c
}

private func next(_ expr: String, after s: String) throws -> Date? {
    try CronSchedule(expr).next(after: date(s), calendar: bangkok)
}

@Test func cronEveryMinuteIsStrictlyAfter() throws {
    #expect(try next("* * * * *", after: "2026-11-12 10:00") == date("2026-11-12 10:01"))
}

@Test func cronStepsAndRanges() throws {
    #expect(try next("*/15 * * * *", after: "2026-11-12 10:01") == date("2026-11-12 10:15"))
    #expect(try next("5/20 * * * *", after: "2026-11-12 10:26") == date("2026-11-12 10:45"))
    #expect(try next("0 9-17/4 * * *", after: "2026-11-12 13:00") == date("2026-11-12 17:00"))
}

@Test func cronWeekdaysRollOverWeekend() throws {
    // 2026-11-13 is a Friday.
    #expect(try next("0 9 * * 1-5", after: "2026-11-13 09:00") == date("2026-11-16 09:00"))
    #expect(try next("0 9 * * mon-fri", after: "2026-11-13 09:00") == date("2026-11-16 09:00"))
    #expect(try next("0 0 * * 7", after: "2026-11-12 00:00") == date("2026-11-15 00:00"))
}

@Test func cronDayAndWeekdayAreOred() throws {
    // Day 20 OR Monday: Monday 2026-11-16 comes first.
    #expect(try next("0 0 20 * 1", after: "2026-11-12 00:00") == date("2026-11-16 00:00"))
}

@Test func cronMonthsAndMacros() throws {
    #expect(try next("0 0 1 jan *", after: "2026-11-12 00:00") == date("2027-01-01 00:00"))
    #expect(try next("@monthly", after: "2026-11-12 00:00") == date("2026-12-01 00:00"))
    #expect(try next("0 0 29 2 *", after: "2026-11-12 00:00") == date("2028-02-29 00:00"))
}

@Test func cronRejectsBadInput() {
    #expect(throws: CronError.self) { try CronSchedule("* * * *") }
    #expect(throws: CronError.self) { try CronSchedule("60 * * * *") }
    #expect(throws: CronError.self) { try CronSchedule("*/0 * * * *") }
    #expect(throws: CronError.self) { try CronSchedule("5-1 * * * *") }
    #expect(throws: CronError.self) { try CronSchedule("0 0 * * funday") }
}

@Test func cronImpossibleDateNeverFires() throws {
    #expect(try next("0 0 31 2 *", after: "2026-11-12 00:00") == nil)
}

// MARK: - Config

@Test func defaultConfigParses() throws {
    let config = try ConfigLoader.parse(DefaultConfig.text, home: "/Users/me")
    let syncthing = try #require(config.allItems.first { $0.id == "syncthing" })
    #expect(syncthing.kind == .service)
    #expect(syncthing.restart == .onFailure)
    #expect(syncthing.directory == "/Users/me")
    #expect(config.sections.map(\.title) == ["Services", "Commands"])
    #expect(config.settings.icon == "terminal")
}

@Test func settingsIconPathExpands() throws {
    let config = try ConfigLoader.parse("[settings]\nicon = \"~/icons/bar.pdf\"\n", home: "/h")
    #expect(config.settings.icon == "/h/icons/bar.pdf")
    #expect(try ConfigLoader.parse("", home: "/h").settings.icon == "terminal")
}

@Test func configFillsDefaultsAndReadsEnv() throws {
    let config = try ConfigLoader.parse("""
    [[sections]]
      [[sections.items]]
      id = "job"
      kind = "scheduled"
      schedule = "@hourly"
      command = "echo hi"
      dir = "~/work"
      env = { A = "1" }
      catch_up = false
    """, home: "/h")
    let item = try #require(config.allItems.first)
    #expect(item.name == "job")
    #expect(item.directory == "/h/work")
    #expect(item.env == ["A": "1"])
    #expect(item.output == .silent)
    #expect(item.catchUp == false)
    #expect(item.schedule?.expression == "@hourly")
}

private func configError(_ text: String) -> String? {
    do { _ = try ConfigLoader.parse(text); return nil } catch let e as ConfigError { return e.description } catch { return "\(error)" }
}

@Test func configRejectsMistakes() {
    func item(_ body: String) -> String { "[[sections]]\n[[sections.items]]\n" + body }
    #expect(configError(item("id = \"a b\"\nkind = \"command\"\ncommand = \"x\""))?.contains("id may use") == true)
    #expect(configError(item("id = \"a\"\nkind = \"daemon\"\ncommand = \"x\""))?.contains("kind must be") == true)
    #expect(configError(item("id = \"a\"\nkind = \"command\"\ncommand = \"x\"\nrestart = \"always\""))?.contains("only to kind = \"service\"") == true)
    #expect(configError(item("id = \"a\"\nkind = \"scheduled\"\ncommand = \"x\""))?.contains("need a schedule") == true)
    #expect(configError(item("id = \"a\"\nkind = \"command\""))?.contains("Missing \"command\"") == true)
    #expect(configError("[[sections]\n")?.contains("TOML syntax error") == true)
    let dup = item("id = \"a\"\nkind = \"command\"\ncommand = \"x\"") + "\n[[sections.items]]\nid = \"a\"\nkind = \"command\"\ncommand = \"y\""
    #expect(configError(dup)?.contains("Duplicate id") == true)
}

// MARK: - Launchd

@Test func plistForService() throws {
    var item = try #require(try ConfigLoader.parse(DefaultConfig.text, home: "/h").allItems.first)
    item.env = ["X": "1"]
    let plist = Launchd.plist(for: item, shell: "/bin/zsh", logPath: "/h/log")
    #expect(plist["Label"] as? String == "local.runbar.syncthing")
    #expect(plist["ProgramArguments"] as? [String] == ["/bin/zsh", "-ilc", "exec '/bin/zsh' -c \"$RUNBAR_COMMAND\""])
    let env = try #require(plist["EnvironmentVariables"] as? [String: String])
    #expect(env == ["X": "1", "RUNBAR": "1", "RUNBAR_COMMAND": "syncthing serve --no-browser"])
    #expect((plist["KeepAlive"] as? [String: Bool]) == ["SuccessfulExit": false])
    #expect(plist["RunAtLoad"] as? Bool == true)
}

@Test func parsesLaunchctlList() {
    let out = "PID\tStatus\tLabel\n123\t0\tlocal.runbar.syncthing\n-\t-15\tlocal.runbar.web\n-\t0\tcom.apple.other\n"
    let jobs = Launchd.parseList(out)
    #expect(jobs.count == 2)
    #expect(jobs["syncthing"] == .init(pid: 123, lastExit: 0))
    #expect(jobs["web"] == .init(pid: nil, lastExit: -15))
}

// MARK: - Adding items

@Test func addToFirstSectionLandsBeforeTheNext() throws {
    var item = NewItem(name: "Web dev", kind: .service, command: "npm run dev")
    item.restart = .onFailure
    item.directory = "~/proj"
    let text = ConfigEditor.adding(item, id: "web-dev", to: .existing(0), in: DefaultConfig.text)
    let config = try ConfigLoader.parse(text, home: "/h")
    let added = try #require(config.sections[0].items.last)
    #expect(added.id == "web-dev")
    #expect(added.restart == .onFailure)
    #expect(added.directory == "/h/proj")
    #expect(config.sections[1].items.count == 1)
}

@Test func addToLastSectionKeepsTrailingComments() throws {
    var item = NewItem(name: "Hi", kind: .command, command: "echo hi")
    item.notify = true
    let text = ConfigEditor.adding(item, id: "hi", to: .existing(1), in: DefaultConfig.text)
    let config = try ConfigLoader.parse(text, home: "/h")
    #expect(config.sections[1].items.last?.output == .notify)
    // The commented example still ends the file, after the new item.
    let tail = DefaultConfig.text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last!
    #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(tail))
    #expect(text.range(of: "id = \"hi\"")!.lowerBound < text.range(of: "# [[sections]]")!.lowerBound)
}

@Test func addNewSectionAndEscapeCommand() throws {
    var item = NewItem(name: "Q", kind: .scheduled, command: "echo \"a\\b\"\nls")
    item.schedule = "0 9 * * 1-5"
    let text = ConfigEditor.adding(item, id: "q", to: .new(title: "Scheduled", icon: "clock"), in: DefaultConfig.text)
    let config = try ConfigLoader.parse(text, home: "/h")
    #expect(config.sections.count == 3)
    #expect(config.sections[2].title == "Scheduled")
    #expect(config.sections[2].items[0].command == "echo \"a\\b\"\nls")
    #expect(config.sections[2].items[0].schedule != nil)
}

@Test func addToEmptyFile() throws {
    let item = NewItem(name: "A", kind: .command, command: "true")
    let text = ConfigEditor.adding(item, id: "a", to: .existing(0), in: "")
    let config = try ConfigLoader.parse(text, home: "/h")
    #expect(config.allItems.map(\.id) == ["a"])
}

@Test func idsFromNames() {
    #expect(ConfigEditor.makeID(from: "Web Dev Server!", taken: []) == "web-dev-server")
    #expect(ConfigEditor.makeID(from: "syncthing", taken: ["syncthing", "syncthing-2"]) == "syncthing-3")
    #expect(ConfigEditor.makeID(from: "ทดสอบ", taken: []) == "item")
}

// MARK: - Editing and removing items

private let editable = """
# top comment
[[sections]]
title = "A"

  [[sections.items]]
  id = "web"
  name = "Web"   # inline note
  kind = "scheduled"
  schedule = "0 9 * * *"
  catch_up = false
  command = \"\"\"
echo one
echo two\"\"\"
  env = { PORT = "8000" }
  # keep me

  [[sections.items]]
  id = "other"
  kind = "command"
  command = "true"

[[sections]]
title = "B"
"""

@Test func updateKeepsOtherKeysAndDropsStaleOnes() throws {
    var item = NewItem(name: "Web server", kind: .service, command: "npm run dev")
    item.restart = .onFailure
    let text = try #require(ConfigEditor.updating("web", with: item, to: .existing(0), in: editable))
    let config = try ConfigLoader.parse(text, home: "/h")
    let web = try #require(config.allItems.first { $0.id == "web" })
    #expect(web.name == "Web server")
    #expect(web.kind == .service)
    #expect(web.command == "npm run dev")
    #expect(web.restart == .onFailure)
    #expect(web.env == ["PORT": "8000"])
    #expect(config.sections[0].items.map(\.id) == ["web", "other"])
    #expect(text.contains("# keep me"))
    #expect(!text.contains("echo two"))
}

@Test func updateMovesToAnotherSection() throws {
    let item = NewItem(name: "Other", kind: .command, command: "true")
    let text = try #require(ConfigEditor.updating("other", with: item, to: .existing(1), in: editable))
    let config = try ConfigLoader.parse(text, home: "/h")
    #expect(config.sections[0].items.map(\.id) == ["web"])
    #expect(config.sections[1].items.map(\.id) == ["other"])
    #expect(ConfigEditor.section(ofItem: "other", in: text) == 1)
}

@Test func removeLeavesTheRest() throws {
    let text = try #require(ConfigEditor.removing("web", in: editable))
    let config = try ConfigLoader.parse(text, home: "/h")
    #expect(config.allItems.map(\.id) == ["other"])
    #expect(text.contains("# top comment"))
    #expect(ConfigEditor.removing("missing", in: editable) == nil)
}
