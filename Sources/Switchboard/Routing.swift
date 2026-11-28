import AppKit
import SwitchboardCore

enum ConfigStore {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Switchboard/config.json")

    static func load() -> (config: Config, error: String?) {
        guard let data = try? Data(contentsOf: url) else { return (.empty, nil) }
        do {
            return (try JSONDecoder().decode(Config.self, from: data), nil)
        } catch {
            return (.empty, "config.json is invalid, rules are off")
        }
    }

    @discardableResult
    static func createStarterIfMissing() -> Bool {
        guard !FileManager.default.fileExists(atPath: url.path) else { return false }
        save(.empty)
        return true
    }

    static func save(_ config: Config) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(config) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

enum DefaultBrowser {
    static var isSwitchboard: Bool {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
            .flatMap { Bundle(url: $0)?.bundleIdentifier } == Bundle.main.bundleIdentifier
    }

    static func request(completion: @escaping @MainActor () -> Void = {}) {
        let appURL = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "http") { _ in
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "https") { _ in
                Task { @MainActor in completion() }
            }
        }
    }
}

struct BrowserOption: Identifiable {
    let id: String
    let appName: String
    let title: String
    let icon: NSImage
    let target: Target

    static func id(for target: Target) -> String {
        target.profile.map { "\(target.browser)#\($0)" } ?? target.browser
    }

    var smallIcon: NSImage {
        let small = icon.copy() as! NSImage
        small.size = NSSize(width: 16, height: 16)
        return small
    }
}

enum InstalledApps {
    static func name(for bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
    }

    static func icon(for bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
            let icon = NSWorkspace.shared.icon(forFile: $0.path)
            icon.size = NSSize(width: 16, height: 16)
            return icon
        }
    }
}

enum Browsers {
    static func options(hiding hidden: [String]) -> [BrowserOption] {
        let probe = URL(string: "https://example.com")!
        var seen = Set<String>()
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: probe).compactMap { appURL -> (URL, String, String)? in
            guard
                !appURL.pathComponents.contains(where: { $0.hasPrefix(".") }),
                let bundleID = Bundle(url: appURL)?.bundleIdentifier,
                bundleID != Bundle.main.bundleIdentifier,
                !hidden.contains(bundleID),
                seen.insert(bundleID).inserted
            else { return nil }
            let name = FileManager.default.displayName(atPath: appURL.path).replacingOccurrences(of: ".app", with: "")
            return (appURL, bundleID, name)
        }
        return apps
            .sorted { $0.2.localizedStandardCompare($1.2) == .orderedAscending }
            .flatMap { appURL, bundleID, name -> [BrowserOption] in
                let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                let profiles = chromiumProfiles(for: bundleID)
                guard profiles.count > 1 else {
                    return [BrowserOption(id: bundleID, appName: name, title: name, icon: icon, target: Target(browser: bundleID))]
                }
                return profiles.map { profile in
                    BrowserOption(
                        id: "\(bundleID)#\(profile.directory)",
                        appName: name,
                        title: "\(name) · \(profile.name)",
                        icon: icon,
                        target: Target(browser: bundleID, profile: profile.directory)
                    )
                }
            }
    }

    private static func chromiumProfiles(for bundleID: String) -> [BrowserProfile] {
        guard let supportPath = BrowserFamily.chromiumSupportPaths[bundleID] else { return [] }
        let localState = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/\(supportPath)/Local State")
        guard let data = try? Data(contentsOf: localState) else { return [] }
        return BrowserFamily.chromiumProfiles(localState: data)
    }
}

enum Launcher {
    @discardableResult
    static func open(_ url: URL, in target: Target) -> Bool {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.browser) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        let flags = BrowserFamily.launchFlags(for: target)
        if flags.isEmpty {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
        } else {
            configuration.createsNewApplicationInstance = true
            configuration.arguments = flags + [url.absoluteString]
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        }
        return true
    }
}

@MainActor
final class Router {
    private let picker = PickerController()

    func route(_ incoming: URL, sourceApp: String?, returnFocusTo: NSRunningApplication?) {
        let (config, error) = ConfigStore.load()
        let url = config.cleanLinks ? LinkCleaner.clean(incoming) : incoming
        let forcePicker = NSEvent.modifierFlags.contains(.shift)
        if !forcePicker,
           let target = config.target(for: url, sourceApp: sourceApp) ?? config.defaultTarget,
           Launcher.open(url, in: target) {
            return
        }
        picker.show(url: url, options: Browsers.options(hiding: config.hiddenBrowsers), notice: error, returnFocusTo: returnFocusTo)
    }
}
