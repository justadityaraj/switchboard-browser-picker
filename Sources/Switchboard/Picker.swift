import AppKit
import SwiftUI
import SwitchboardCore

final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PickerController: NSObject, NSWindowDelegate {
    private var panel: PickerPanel?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var returnFocusTo: NSRunningApplication?
    private var url: URL?
    private var options: [BrowserOption] = []

    func show(url: URL, options: [BrowserOption], notice: String?, returnFocusTo: NSRunningApplication?) {
        let returnFocusTo = returnFocusTo ?? (panel != nil ? self.returnFocusTo : nil)
        close()
        self.returnFocusTo = returnFocusTo
        self.url = url
        self.options = options

        let view = PickerView(url: url, options: options, notice: notice) { [weak self] option in
            self?.choose(option)
        }
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = PickerPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.setFrameOrigin(origin(for: size))
        self.panel = panel

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.close()
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        if NSApp.currentEvent?.window.map({ $0 !== panel }) == true {
            returnFocusTo = nil
        }
        close()
    }

    private func origin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)
        let x = min(max(mouse.x - 20, bounds.minX), bounds.maxX - size.width)
        let y = min(max(mouse.y - size.height + 20, bounds.minY), bounds.maxY - size.height)
        return NSPoint(x: x, y: y)
    }

    private func handle(_ event: NSEvent) -> Bool {
        let key = event.charactersIgnoringModifiers ?? ""
        switch event.keyCode {
        case 53:
            closeAndReturnFocus()
            return true
        case 36, 76:
            options.first.map(choose)
            return true
        default:
            break
        }
        if event.modifierFlags.contains(.command), key == "c" {
            copyLink()
            return true
        }
        if let digit = Int(key), (1...9).contains(digit), digit <= options.count {
            choose(options[digit - 1])
            return true
        }
        return false
    }

    private func choose(_ option: BrowserOption) {
        guard let url else { return }
        var target = option.target
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.option) {
            target.privateWindow = true
        }
        if modifiers.contains(.command), let host = url.host {
            var (config, error) = ConfigStore.load()
            if error == nil {
                config.remember(host: host, target: target)
                ConfigStore.save(config)
            }
        }
        close()
        Launcher.open(url, in: target)
    }

    private func copyLink() {
        guard let url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        closeAndReturnFocus()
    }

    private func closeAndReturnFocus() {
        let source = returnFocusTo
        close()
        if let source {
            NSApp.yieldActivation(to: source)
            source.activate()
        }
    }

    private func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        panel?.delegate = nil
        SettingsWindow.refusesKey = returnFocusTo != nil
        panel?.orderOut(nil)
        SettingsWindow.refusesKey = false
        panel = nil
        returnFocusTo = nil
    }
}

struct PickerView: View {
    let url: URL
    let options: [BrowserOption]
    let notice: String?
    let choose: (BrowserOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(url.host ?? url.absoluteString)
                    .font(.headline)
                    .lineLimit(1)
                Text(url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 6)
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6)
            }
            Divider()
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                PickerRow(option: option, shortcut: index < 9 ? index + 1 : nil) { choose(option) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Text("⌘ always use for \(url.host.flatMap(Rule.normalizedHost) ?? "this site")  ·  ⌥ private window")
                Text("⌘C copy link  ·  esc cancel")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
        }
        .padding(10)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct PickerRow: View {
    let option: BrowserOption
    let shortcut: Int?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(nsImage: option.icon)
                    .resizable()
                    .frame(width: 24, height: 24)
                Text(option.title)
                    .lineLimit(1)
                Spacer()
                if let shortcut {
                    Text("\(shortcut)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Color.accentColor.opacity(0.25) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
