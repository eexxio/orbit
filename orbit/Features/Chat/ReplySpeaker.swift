import AVFoundation
import MarkdownUI

@Observable
final class ReplySpeaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = ReplySpeaker()

    private(set) var speakingID: UUID?
    private(set) var failedID: UUID?
    private var utteranceID: ObjectIdentifier?
    private var didStartUtterance = false
    @ObservationIgnored private var playbackWatchdog: Task<Void, Never>?
    private let synthesizer = AVSpeechSynthesizer()

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func start(id: UUID, text: String) {
        stop()
        failedID = nil
        let text = ReplySpeechText.render(text)
        guard !text.isEmpty else { return }
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-orbitStallReadAloud") {
            beginPlayback(id)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-orbitFakeReadAloud") {
            speakingID = id
            return
        }
        #endif
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio,
                                    options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true)
        } catch {
            failPlayback(id)
            return
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        utterance.prefersAssistiveTechnologySettings = true
        utteranceID = ObjectIdentifier(utterance)
        beginPlayback(id)
        synthesizer.speak(utterance)
    }

    func stop() {
        guard speakingID != nil else { return }
        playbackWatchdog?.cancel()
        playbackWatchdog = nil
        let realSpeech = utteranceID != nil
        utteranceID = nil
        didStartUtterance = false
        speakingID = nil
        if realSpeech {
            synthesizer.stopSpeaking(at: .immediate)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func beginPlayback(_ id: UUID) {
        speakingID = id
        watchPlayback(id, timeout: .seconds(3))
    }

    private func watchPlayback(_ id: UUID, timeout: Duration) {
        playbackWatchdog?.cancel()
        playbackWatchdog = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, speakingID == id else { return }
            failPlayback(id)
        }
    }

    private func failPlayback(_ id: UUID) {
        stop()
        failedID = id
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        didMakeProgress(ObjectIdentifier(utterance))
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        didMakeProgress(ObjectIdentifier(utterance))
    }

    nonisolated private func didMakeProgress(_ id: ObjectIdentifier) {
        Task { @MainActor in
            guard utteranceID == id, let speakingID else { return }
            didStartUtterance = true
            watchPlayback(speakingID, timeout: .seconds(15))
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        didEnd(ObjectIdentifier(utterance), cancelled: false)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        didEnd(ObjectIdentifier(utterance), cancelled: true)
    }

    nonisolated private func didEnd(_ id: ObjectIdentifier, cancelled: Bool) {
        Task { @MainActor in
            guard utteranceID == id, let speakingID else { return }
            if cancelled || !didStartUtterance {
                failPlayback(speakingID)
            } else {
                stop()
            }
        }
    }
}

private final class ReplySpeechText: NSObject, XMLParserDelegate {
    private var output = ""
    private var skippedElement: String?

    static func render(_ markdown: String) -> String {
        let html = MarkdownContent(markdown).renderHTML()
        let parser = XMLParser(data: Data("<reply>\(html)</reply>".utf8))
        let delegate = ReplySpeechText()
        parser.delegate = delegate
        parser.parse()
        return delegate.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        guard skippedElement == nil else { return }
        switch element {
        case "pre", "table":
            output += element == "pre" ? "\nCode block.\n" : "\nTable.\n"
            skippedElement = element
        case "img":
            output += attributes["alt"] ?? ""
        case "br":
            output += "\n"
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if skippedElement == nil { output += string }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if let skippedElement {
            if element == skippedElement { self.skippedElement = nil }
            return
        }
        switch element {
        case "li":
            while output.last?.isWhitespace == true { output.removeLast() }
            if let last = output.last, !last.isPunctuation { output += "." }
            output += "\n"
        case "p", "h1", "h2", "h3", "h4", "h5", "h6":
            output += "\n"
        default:
            break
        }
    }
}
