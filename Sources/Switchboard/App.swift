import AppKit
import SwiftUI
import ServiceManagement

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static var shared: AppDelegate?

    private let router = Router()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var activation: (at: TimeInterval, previousApp: NSRunningApplication?, windowAboveSettings: Int?)?
    private var settingsModel: SettingsModel?
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        shared = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isFirstLaunch = ConfigStore.createStarterIfMissing()
        installStatusItem()
        if CommandLine.arguments.contains("--set-default") {
            DefaultBrowser.request()
        }
        if isFirstLaunch || CommandLine.arguments.contains("--settings") {
            showSettings()
        }
    }

    func applicationWillBecomeActive(_ notification: Notification) {
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let normal = windows.filter { $0[kCGWindowLayer as String] as? Int == 0 }.compactMap { $0[kCGWindowNumber as String] as? Int }
        let index = settingsWindow.flatMap { $0.isVisible ? normal.firstIndex(of: $0.windowNumber) : nil }
        let previousApp = NSWorkspace.shared.menuBarOwningApplication.flatMap { $0 == .current ? nil : $0 }
        activation = (ProcessInfo.processInfo.systemUptime, previousApp, index.flatMap { $0 > 0 ? normal[$0 - 1] : nil })
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let returnFocusTo = takeLinkActivation()
        urls.forEach { router.route($0, sourceApp: nil, returnFocusTo: returnFocusTo) }
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard
            let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
            let url = URL(string: string)
        else { return }
        let senderPID = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value
        let sourceApp = senderPID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        router.route(url, sourceApp: sourceApp == Bundle.main.bundleIdentifier ? nil : sourceApp, returnFocusTo: takeLinkActivation())
    }

    private func takeLinkActivation() -> NSRunningApplication? {
        defer { activation = nil }
        // ponytail: any activation in the last second counts as caused by this link, since no API ties the two; a background link right after clicking Settings would misfire
        guard let activation, ProcessInfo.processInfo.systemUptime - activation.at < 1 else { return nil }
        if let windowAbove = activation.windowAboveSettings {
            settingsWindow?.order(.below, relativeTo: windowAbove)
        }
        return activation.previousApp
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Switchboard")
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Switchboard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let model = SettingsModel()
            let window = SettingsWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            window.title = "Switchboard Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 560, height: 640))
            window.center()
            settingsModel = model
            settingsWindow = window
        }
        settingsModel?.reload()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

final class SettingsWindow: NSWindow {
    static var refusesKey = false
    override var canBecomeKey: Bool { !Self.refusesKey && super.canBecomeKey }
    override var canBecomeMain: Bool { !Self.refusesKey && super.canBecomeMain }
}
