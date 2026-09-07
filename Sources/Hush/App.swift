import AppKit
import Carbon
import SwiftUI

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PlayerHostingView: NSHostingView<PlayerView> {
    var onResize: ((CGFloat) -> Void)?
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let height = self.fittingSize.height
            if height > 100 { self.onResize?(height) }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel!
    private var statusItem: NSStatusItem!
    private var model: ReaderModel!
    private var hotkeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var activationObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        model = ReaderModel()
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 420),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = PlayerHostingView(rootView: PlayerView(model: model,
            hide: { [weak self] in self?.panel.orderOut(nil) },
            resize: { [weak self] height in
                DispatchQueue.main.async { self?.resizePanel(height: height) }
            }))
        view.sizingOptions = [.intrinsicContentSize]
        view.onResize = { [weak self] height in self?.resizePanel(height: height) }
        panel.contentView = view
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 420, y: frame.maxY - 510))
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Hush")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor in self?.model.targetApp = app }
        }
        registerHotkeys()
        show()
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Hush")
        appMenu.addItem(withTitle: "About Hush", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let showItem = appMenu.addItem(withTitle: "Show Player", action: #selector(show), keyEquivalent: "0")
        showItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Hush", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Hush", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Show Hush", action: #selector(show), keyEquivalent: "")
            menu.addItem(withTitle: "Play / Pause", action: #selector(togglePlayback), keyEquivalent: "")
            menu.addItem(withTitle: "Stop", action: #selector(stop), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Hush", action: #selector(quit), keyEquivalent: "q")
            menu.items.forEach { $0.target = self }
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else if panel.isVisible { panel.orderOut(nil) }
        else { show() }
    }

    @objc func show() { panel.orderFrontRegardless() }

    private func resizePanel(height: CGFloat) {
        guard let panel, abs(panel.frame.height - height) > 1 else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        if let screen = panel.screen ?? NSScreen.main {
            frame.origin.y = max(screen.visibleFrame.minY + 12, min(frame.origin.y, screen.visibleFrame.maxY - height - 12))
        }
        panel.setFrame(frame, display: true)
    }
    @objc private func togglePlayback() { model.togglePlayback() }
    @objc private func stop() { model.stop() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func registerHotkeys() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            let action = id.id
            Task { @MainActor in delegate.handleHotkey(action) }
            return noErr
        }, 1, &type, pointer, &handler)
        for (id, modifiers) in [(UInt32(1), UInt32(optionKey)), (2, UInt32(optionKey | shiftKey)), (3, UInt32(optionKey | controlKey))] {
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(UInt32(kVK_Space), modifiers, EventHotKeyID(signature: 0x48555348, id: id),
                                             GetApplicationEventTarget(), 0, &reference)
            if result == noErr, let reference { hotkeys.append(reference) }
            else { model.shortcutAvailable = false }
        }
    }

    private func handleHotkey(_ id: UInt32) {
        show()
        switch id {
        case 1: model.capture()
        case 2: model.readClipboard()
        case 3: model.togglePlayback()
        default: break
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        model.shutdown()
    }
}

@main
enum HushApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
