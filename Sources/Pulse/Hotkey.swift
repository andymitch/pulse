import AppKit
import Carbon.HIToolbox
import SwiftUI

struct Hotkey: Codable, Equatable {
    var key: UInt32
    var modifiers: UInt32
    var label: String

    static let standard = Hotkey(key: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey | cmdKey), label: "⌃⌥⌘P")
    static let off = Hotkey(key: 0, modifiers: 0, label: "")

    init(key: UInt32, modifiers: UInt32, label: String) {
        self.key = key
        self.modifiers = modifiers
        self.label = label
    }

    init?(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard !flags.isDisjoint(with: [.control, .option, .command]) else { return nil }
        let names: [(NSEvent.ModifierFlags, Int, String)] = [(.control, controlKey, "⌃"), (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")]
        let used = names.filter { flags.contains($0.0) }
        let char = event.keyCode == UInt16(kVK_Space) ? "Space" : (event.charactersIgnoringModifiers ?? "").uppercased()
        self.init(key: UInt32(event.keyCode), modifiers: UInt32(used.map(\.1).reduce(0, |)), label: used.map(\.2).joined() + char)
    }
}

@MainActor
enum GlobalHotkey {
    static var action: () -> Void = {}
    private static var ref: EventHotKeyRef?
    private static var handler: EventHandlerRef?

    static func register(_ hotkey: Hotkey) {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                MainActor.assumeIsolated { GlobalHotkey.action() }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        guard hotkey != .off else { return }
        RegisterEventHotKey(hotkey.key, hotkey.modifiers, EventHotKeyID(signature: OSType(0x504C5345), id: 1), GetApplicationEventTarget(), 0, &ref)
    }
}

struct HotkeyRow: View {
    @Binding var hotkey: Hotkey
    @State private var monitor: Any?

    var body: some View {
        LabeledContent {
            HStack {
                Button(monitor != nil ? "Press a shortcut…" : hotkey == .off ? "None" : hotkey.label, action: record)
                if hotkey != .off && monitor == nil {
                    Button { hotkey = .off } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).help("Turn off the shortcut")
                }
            }
        } label: {
            Text("Open and close Pulse")
            Text("Works from any app, even when the menu bar icon is hidden behind the notch.")
        }
        .onDisappear(perform: stop)
    }

    private func record() {
        guard monitor == nil else { return stop() }
        GlobalHotkey.register(.off)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
            } else if let key = Hotkey(event) {
                hotkey = key
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        GlobalHotkey.register(hotkey)
    }
}
