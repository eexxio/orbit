import SwiftUI

struct DictateButton: View {
    let dictation: ComposerDictation
    let accent: Accent
    let toggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: toggle) {
            ZStack {
                if dictation.phase == .listening {
                    Circle()
                        .fill(recordingFill)
                        .frame(width: 30, height: 30)
                }
                if dictation.phase == .preparing || dictation.phase == .finishing {
                    ProgressView().controlSize(.mini)
                } else {
                    let listening = dictation.phase == .listening
                    Image(systemName: listening ? "waveform" : "mic")
                        .foregroundStyle(listening ? accent.onColor : Color.secondary)
                        .symbolEffect(.variableColor.iterative, isActive: listening && !reduceMotion)
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace.downUp))
                }
            }
            .font(.body)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -7)
        .disabled(dictation.phase == .permission || dictation.phase == .finishing)
        .animation(.snappy(duration: 0.2), value: dictation.phase)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityHint(dictation.phase == .idle ? "Speak to type a message" : "")
        .accessibilityIdentifier(identifier)
        .keyboardShortcut("d", modifiers: [.command, .option])
    }

    private var recordingFill: Color {
        guard accent == .mono else { return accent.color }
        return colorScheme == .dark ? .white : .black
    }

    private var label: LocalizedStringKey {
        switch dictation.phase {
        case .listening: "Stop dictation"
        case .preparing: "Preparing dictation"
        default: "Dictate"
        }
    }

    private var value: Text {
        switch dictation.phase {
        case .listening: Text("Listening")
        case .preparing: Text("\(dictation.progress) percent")
        default: Text("")
        }
    }

    private var identifier: String {
        switch dictation.phase {
        case .listening: "chat.dictate.stop"
        case .preparing: "chat.dictate.preparing"
        default: "chat.dictate"
        }
    }
}

struct DictationDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 6, height: 6)
            .opacity(dim && !reduceMotion ? 0.35 : 1)
            .onChange(of: reduceMotion, initial: true) {
                if reduceMotion {
                    dim = false
                } else {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                        dim = true
                    }
                }
            }
            .accessibilityHidden(true)
    }
}

struct DictationNoticeView: View {
    let dictation: ComposerDictation
    let accent: Accent
    let retry: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        if dictation.phase == .preparing || dictation.notice != nil {
            HStack(spacing: 8) {
                Label {
                    title
                        .lineLimit(1)
                } icon: {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundStyle(dictation.phase == .preparing || dictation.notice == .noSpeech
                                         ? Color.secondary : Color.orange)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("chat.dictate.notice")

                if dictation.phase == .preparing {
                    action("Cancel") { dictation.stop() }
                } else if dictation.notice == .permission {
                    action("Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                } else if dictation.notice == .downloadFailed {
                    action("Try Again", run: retry)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .transition(.opacity)
        }
    }

    private func action(_ title: LocalizedStringKey, run: @escaping () -> Void) -> some View {
        Button(title, action: run)
            .buttonStyle(.plain)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(accent.color)
    }

    private var title: Text {
        if dictation.phase == .preparing {
            return Text("Downloading speech model… \(dictation.progress)%")
        }
        return switch dictation.notice {
        case .permission: Text("Microphone access is off for orbit.")
        case .downloadFailed: Text("Couldn't download the speech model.")
        case .noSpeech: Text("Didn't catch that.")
        default: Text("Dictation stopped. Try again.")
        }
    }

    private var icon: String {
        if dictation.phase == .preparing { return "arrow.down.circle" }
        return switch dictation.notice {
        case .permission: "mic.slash"
        case .noSpeech: "waveform.slash"
        default: "exclamationmark.circle"
        }
    }
}
