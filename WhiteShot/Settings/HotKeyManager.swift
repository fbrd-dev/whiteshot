import AppKit
import Carbon.HIToolbox

/// Registers the global capture shortcuts with Carbon's hot key API, which works without any
/// Accessibility permission and is what virtually every Mac utility uses.
final class HotKeyManager {
    static let shared = HotKeyManager()

    var onAction: ((HotkeyAction) -> Void)?
    private var references: [ShortcutSlot: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x57535448   // 'WSTH'

    private init() {
        NotificationCenter.default.addObserver(forName: ShortcutStore.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    func start() {
        installHandlerIfNeeded()
        reload()
    }

    /// Registers every shortcut of every action: the primary and, if the user set one, the second.
    func reload() {
        for (_, ref) in references { UnregisterEventHotKey(ref) }
        references.removeAll()
        for action in HotkeyAction.allCases {
            for index in 0..<ShortcutStore.slotCount {
                guard let shortcut = ShortcutStore.shortcut(for: action, slot: index) else { continue }
                var ref: EventHotKeyRef?
                let id = EventHotKeyID(signature: Self.signature, id: action.carbonID * 10 + UInt32(index))
                let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref)
                if status == noErr, let ref { references[ShortcutSlot(action: action, index: index)] = ref }
            }
        }
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == HotKeyManager.signature,
                  let action = HotkeyAction.allCases.first(where: { $0.carbonID == id.id / 10 }) else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { HotKeyManager.shared.onAction?(action) }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    /// True if the shortcut in `slot` could be registered (macOS refuses combinations it owns).
    func isRegistered(_ slot: ShortcutSlot) -> Bool { references[slot] != nil }
}
