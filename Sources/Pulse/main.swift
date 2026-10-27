import AppKit
import Combine
import os
import SwiftUI

private let log = Logger(subsystem: "com.andymitch.pulse", category: "popover")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var store: Store!
    private var badge: AnyCancellable?
    private var recordingIcon: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let dir = Settings.dir
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            store = Store(db: try DB(path: dir.appendingPathComponent("pulse.db").path), dir: dir)
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
            return
        }

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        NSApp.mainMenu = NSMenu()
        NSApp.mainMenu?.addItem(NSMenuItem())
        NSApp.mainMenu?.addItem(editItem)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Pulse")
            button.action = #selector(clicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        badge = store.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            let n = self.store.checklist.filter { !$0.done }.count
            self.statusItem.button?.title = n > 0 ? "\(n)" : ""
            self.statusItem.button?.imagePosition = .imageLeading
        }

        recordingIcon = Meetings.shared.$recording.sink { [weak self] meeting in
            guard let meeting else {
                self?.statusItem.button?.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Pulse")
                return
            }
            let image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Pulse, recording \(meeting.title)")?
                .withSymbolConfiguration(.init(paletteColors: [.systemRed]))
            image?.isTemplate = false
            self?.statusItem.button?.image = image
        }
        Meetings.shared.watch { [weak self] in self?.store.me }

        popover.contentViewController = NSHostingController(rootView: ContentView(store: store))
        popover.behavior = .transient
        popover.delegate = self
        store.startHourlySync()
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r").target = self
            menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
            if Meetings.shared.recording != nil {
                menu.addItem(withTitle: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "").target = self
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Pulse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            sender.performClick(nil)
            statusItem.menu = nil
        } else if popover.isShown {
            popover.performClose(sender)
        } else {
            let height = min(920, (sender.window?.screen?.visibleFrame.height ?? 920) - 40)
            popover.contentSize = NSSize(width: 760, height: height)
            store.refreshTodayIfStale()
            Updater.shared.checkIfDue(every: 1800)
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            log.log("Opened popover, active: \(NSApp.isActive, privacy: .public)")
        }
    }

    @objc private func refresh() { Task { await store.refresh() } }

    @objc private func stopRecording() { Task { await Meetings.shared.stop(skip: true) } }

    func popoverWillClose(_ notification: Notification) {
        log.log("Closing popover, active: \(NSApp.isActive, privacy: .public), event: \(String(describing: NSApp.currentEvent), privacy: .public)")
    }

    func popoverDidClose(_ notification: Notification) {
        Speaker.shared.stop()
        if !popover.isShown { NSApp.deactivate() }
    }

    func applicationDidResignActive(_ notification: Notification) {
        log.log("Resigned active, frontmost: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none", privacy: .public)")
    }

    @objc private func showSettings() {
        store.showingSettings = true
        if let button = statusItem.button, !popover.isShown { clicked(button) }
    }
}

if CommandLine.arguments.contains("--self-test") {
    do { try selfTest() } catch { print(error); exit(1) }
    exit(0)
}

adoptLoginShellPath()
let delegate = MainActor.assumeIsolated { AppDelegate() }
MainActor.assumeIsolated {
    NSApplication.shared.delegate = delegate
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
}
