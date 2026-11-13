import Foundation
import RunbarCore

/// Loads the config and reloads it when the file changes. Watches both the file
/// (in-place writes) and its folder (editors that save by replacing the file).
final class ConfigWatcher {
    private let paths: Paths
    private var fileSource: DispatchSourceFileSystemObject?
    private var dirSource: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var lastText: String?

    /// Called on main with a new config or the reason it could not be used.
    var onLoad: ((Result<Config, ConfigError>) -> Void)?

    init(paths: Paths) {
        self.paths = paths
    }

    func start() {
        Files.ensureDir(paths.configDir)
        if !FileManager.default.fileExists(atPath: paths.configFile) {
            FileManager.default.createFile(atPath: paths.configFile, contents: DefaultConfig.text.data(using: .utf8))
        }
        dirSource = watch(paths.configDir, events: .write)
        armFileWatch()
        reload(force: true)
    }

    func reload(force: Bool = false) {
        guard let data = FileManager.default.contents(atPath: paths.configFile) else {
            onLoad?(.failure(ConfigError("Cannot read \(paths.configFile)")))
            return
        }
        let text = String(decoding: data, as: UTF8.self)
        if !force && text == lastText { return }
        lastText = text
        // An empty file is usually an editor mid-save; never treat it as "remove everything".
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onLoad?(.failure(ConfigError("Config file is empty")))
            return
        }
        do {
            onLoad?(.success(try ConfigLoader.parse(text)))
        } catch let error as ConfigError {
            onLoad?(.failure(error))
        } catch {
            onLoad?(.failure(ConfigError("\(error)")))
        }
    }

    private func armFileWatch() {
        fileSource?.cancel()
        fileSource = watch(paths.configFile, events: [.write, .delete, .rename, .extend])
    }

    private func watch(_ path: String, events: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
        source.setEventHandler { [weak self] in self?.changed() }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // The file may have been replaced; follow the new one.
            self.armFileWatch()
            self.reload()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
