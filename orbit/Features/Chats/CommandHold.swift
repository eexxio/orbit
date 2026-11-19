import GameController
import SwiftUI

@MainActor @Observable
final class CommandHold {
    private(set) var visible = false
    @ObservationIgnored private var hold: Task<Void, Never>?
    @ObservationIgnored private var keys: Set<GCKeyCode> = []

    func update(_ key: GCKeyCode, pressed: Bool, eligible: () -> Bool) {
        if pressed {
            guard keys.insert(key).inserted else { return }
            guard keys.count == 1, key == .leftGUI || key == .rightGUI, eligible() else {
                hide()
                return
            }
            hold = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled else { return }
                self?.visible = true
            }
        } else {
            keys.remove(key)
            if key == .leftGUI || key == .rightGUI { hide() }
        }
    }

    func hide() {
        hold?.cancel()
        hold = nil
        visible = false
    }

    func reset() {
        hide()
        keys.removeAll()
    }
}

enum HardwareKeyboardEvents {
    static let changed = Notification.Name("orbit.hardwareKeyboardChanged")

    static func observeKeyboard() {
        // Observe the hardware without competing with the text editor's responder or consuming chords.
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = { _, _, key, pressed in
            NotificationCenter.default.post(name: changed, object: nil, userInfo: [
                "key": key, "pressed": pressed
            ])
        }
    }
}

struct CommandHoldPanel: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let available: (ChatShortcut) -> Bool

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Text("Keyboard Shortcuts")
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                ShortcutRows(available: available)
                    .defaultScrollAnchor(.top)
                    .frame(maxHeight: min(535, max(0, proxy.size.height - 96)))
            }
            .frame(maxWidth: min(440, max(0, proxy.size.width - 32)))
            .background {
                let shape = RoundedRectangle(cornerRadius: 20)
                if reduceTransparency { shape.fill(Color(uiColor: .systemBackground)) }
                else { shape.fill(.regularMaterial) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black.opacity(0.14))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
