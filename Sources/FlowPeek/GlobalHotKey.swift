import AppKit
import Carbon.HIToolbox
import FlowPeekCore
import OSLog

private let flowPeekHotKeyNotification = Notification.Name("FlowPeekHotKeyPressed")
private let flowPeekHotKeyIDKey = "id"

/// Carbon hands the callback a C function pointer, so the pressed hot key's id is republished as a
/// notification and routed on the main actor from there.
private let flowPeekHotKeyHandler: EventHandlerUPP = { _, event, _ in
    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr else { return noErr }
    let id = identifier.id
    DispatchQueue.main.async {
        NotificationCenter.default.post(
            name: flowPeekHotKeyNotification,
            object: nil,
            userInfo: [flowPeekHotKeyIDKey: id]
        )
    }
    return noErr
}

@MainActor
final class GlobalHotKey {
    var onPress: (() -> Void)?

    private var identifier: UInt32?
    private var reference: EventHotKeyRef?
    private var observer: NSObjectProtocol?

    /// The returned status is the only witness to a combination another process already owns, so it
    /// is handed back rather than only logged. Note this begins by dropping any previous claim: a
    /// caller that gets a failure is left holding nothing and has to put the old shortcut back.
    @discardableResult
    func register(_ shortcut: FlowPeekShortcut, for action: FlowPeekShortcutAction) -> OSStatus {
        unregister()
        HotKeyDispatcher.shared.installHandlerIfNeeded()
        identifier = action.hotKeyID
        let signature = OSType(UInt32(ascii: "F") << 24 | UInt32(ascii: "P") << 16 | UInt32(ascii: "H") << 8 | UInt32(ascii: "K"))
        let hotKeyID = EventHotKeyID(signature: signature, id: action.hotKeyID)
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.modifiers.carbonFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "FlowPeek", category: "HotKey").info(
            "register \(action.rawValue, privacy: .public) as \(shortcut.display, privacy: .public) -> \(status == noErr ? "ok" : "OSStatus \(status)", privacy: .public)"
        )
        observer = NotificationCenter.default.addObserver(
            forName: flowPeekHotKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let pressed = note.userInfo?[flowPeekHotKeyIDKey] as? UInt32
            MainActor.assumeIsolated {
                guard let self, pressed == self.identifier else { return }
                self.onPress?()
            }
        }
        return status
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        reference = nil
        observer = nil
        identifier = nil
    }
}

/// One Carbon event handler for the whole process; installing it per hot key would deliver every
/// press once per registration.
@MainActor
private final class HotKeyDispatcher {
    static let shared = HotKeyDispatcher()
    private var handler: EventHandlerRef?

    func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), flowPeekHotKeyHandler, 1, &eventType, nil, &handler)
    }
}

private extension UInt32 {
    init(ascii: Character) { self = ascii.asciiValue.map(UInt32.init) ?? 0 }
}
