import AVFoundation
import Speech
import SwiftUI
import Synchronization

@Observable
final class ComposerDictation {
    enum Phase: Equatable { case idle, permission, preparing, listening, finishing }
    enum Notice: Equatable { case permission, downloadFailed, noSpeech, error }

    private(set) var phase = Phase.idle
    private(set) var available = false
    private(set) var notice: Notice?
    private(set) var progress = 0
    private(set) var heardSpeech = false
    var isBusy: Bool { phase != .idle }
    var isCapturing: Bool { phase == .listening || phase == .finishing }

    private var locale: Locale?
    private var operation: Task<Void, Never>?
    private var results: Task<Void, Never>?
    private var detection: Task<Void, Never>?
    private var silence: Task<Void, Never>?
    private var limit: Task<Void, Never>?
    private var finishTimeout: Task<Void, Never>?
    private var noticeTimeout: Task<Void, Never>?
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var input: DictationAudioInput?
    private var installation: Progress?
    private var ownsAudioSession = false
    private var sessionID: UUID?
    private var committed = ""
    private var provisional = ""
    private var lastFinalEnd = CMTime.invalid
    private var speechDetected = false
    private var updateDraft: ((String) -> Void)?
    private var afterFinish: (() -> Void)?
    private let fakeText: String? = {
        #if DEBUG && targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-orbitFakeDictation"), args.indices.contains(index + 1) {
            return args[index + 1]
        }
        #endif
        return nil
    }()

    func checkAvailability() async {
        if fakeText != nil {
            available = true
        } else if SpeechTranscriber.isAvailable {
            locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current)
            available = locale != nil
        }
    }

    func start(draft: String, update: @escaping (String) -> Void) {
        guard available, !isBusy else { return }
        dismissNotice()
        committed = draft
        provisional = ""
        lastFinalEnd = .invalid
        speechDetected = false
        heardSpeech = false
        updateDraft = update
        let id = UUID()
        sessionID = id
        phase = .permission
        operation = Task {
            if let fakeText {
                phase = .listening
                receive(fakeText, isFinal: false)
                return
            }

            // UI previews and unsigned review builds may omit the unapproved privacy keys.
            guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil,
                  Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
                stop(with: .permission)
                return
            }
            let microphoneAllowed = await AVAudioApplication.requestRecordPermission()
            guard sessionID == id else { return }
            guard microphoneAllowed else { stop(with: .permission); return }
            let speechAllowed = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
            guard sessionID == id else { return }
            guard speechAllowed, let locale else { stop(with: .permission); return }

            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            do {
                let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
                guard sessionID == id else { return }
                if let request {
                    phase = .preparing
                    progress = 0
                    installation = request.progress
                    let updates = Task {
                        while !Task.isCancelled, sessionID == id {
                            progress = Int(request.progress.fractionCompleted * 100)
                            try? await Task.sleep(for: .milliseconds(150))
                        }
                    }
                    defer { updates.cancel() }
                    try await request.downloadAndInstall()
                    guard sessionID == id else { return }
                    installation = nil
                }
            } catch {
                if sessionID == id { stop(with: .downloadFailed) }
                return
            }

            do {
                if UIAccessibility.isVoiceOverRunning { await announceListening() }
                guard sessionID == id else { return }
                try await startAudio(transcriber, id: id)
            } catch {
                if sessionID == id { stop(with: .error) }
            }
        }
    }

    private func announceListening() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await notification in NotificationCenter.default.notifications(
                    named: UIAccessibility.announcementDidFinishNotification
                ) {
                    if notification.userInfo?[UIAccessibility.announcementStringValueUserInfoKey] as? String == "Listening" {
                        return
                    }
                }
            }
            group.addTask { try? await Task.sleep(for: .seconds(1)) }
            await Task.yield()
            UIAccessibility.post(notification: .announcement, argument: "Listening")
            await group.next()
            group.cancelAll()
        }
    }

    private enum AudioError: Error { case unavailable }

    private func startAudio(_ transcriber: SpeechTranscriber, id: UUID) async throws {
        let detector = SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: true)
        let modules: [any SpeechModule] = [transcriber, detector]
        let analyzer = SpeechAnalyzer(modules: modules)
        self.analyzer = analyzer
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
        guard sessionID == id else { return }
        guard let format else { throw AudioError.unavailable }
        try await analyzer.prepareToAnalyze(in: format)
        guard sessionID == id else { return }

        let (audio, continuation) = AsyncThrowingStream<AnalyzerInput, Error>.makeStream()
        let input = DictationAudioInput(format: format, continuation: continuation)
        self.input = input
        try await analyzer.start(inputSequence: audio)
        guard sessionID == id else { return }
        let audioSession = AVAudioSession.sharedInstance()
        // AVAudioSession doesn't accept duckOthers with the record category.
        try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .allowBluetoothHFP])
        try audioSession.setActive(true)
        ownsAudioSession = true
        let engine = AVAudioEngine()
        let node = engine.inputNode
        let source = node.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0 else { throw AudioError.unavailable }
        let frames = AVAudioFrameCount(source.sampleRate * 0.15)
        try node.installAudioTap(onBus: 0, bufferSize: frames, format: source) { buffer, _ in
            input.receive(buffer)
        }
        self.engine = engine
        try engine.start()
        beginListening()

        detection = Task {
            do {
                for try await result in detector.results {
                    guard sessionID == id, phase == .listening else { return }
                    guard speechDetected != result.speechDetected else { continue }
                    speechDetected = result.speechDetected
                    if heardSpeech { scheduleSilence() }
                }
            } catch {
                if sessionID == id, phase == .listening { stop(with: .error) }
            }
        }

        results = Task {
            do {
                for try await result in transcriber.results {
                    guard sessionID == id, !Task.isCancelled else { return }
                    let start = result.range.start
                    if lastFinalEnd.isValid, start < lastFinalEnd { continue }
                    if result.isFinal { lastFinalEnd = result.range.end }
                    receive(String(result.text.characters), isFinal: result.isFinal)
                }
                guard sessionID == id else { return }
                if phase == .finishing { completeFinish() } else { stop(with: .error) }
            } catch {
                if sessionID == id {
                    if phase == .finishing { completeFinish() } else { stop(with: .error) }
                }
            }
        }
    }

    private func beginListening() {
        phase = .listening
        scheduleSilence()
        limit = Task {
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            finish()
        }
    }

    private func receive(_ text: String, isFinal: Bool) {
        guard isCapturing else { return }
        let changed = provisional != text
        provisional = text
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let first = !heardSpeech
            heardSpeech = true
            if (first || changed), phase == .listening, fakeText == nil { scheduleSilence() }
        }
        let separator = committed.last?.isWhitespace == false && text.first?.isWhitespace == false ? " " : ""
        let merged = committed + separator + text
        if isFinal {
            committed = merged
            provisional = ""
        }
        updateDraft?(merged)
    }

    private func scheduleSilence() {
        silence?.cancel()
        if heardSpeech && speechDetected { return }
        let duration = heardSpeech ? 3 : 8
        silence = Task {
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            finish()
        }
    }

    func finish(then completion: (() -> Void)? = nil) {
        guard phase == .listening else { return }
        phase = .finishing
        afterFinish = completion
        silence?.cancel()
        limit?.cancel()
        stopMicrophone(flush: true)
        if let fakeText {
            receive(fakeText, isFinal: true)
            completeFinish()
        } else {
            finishTimeout = Task {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                completeFinish()
            }
            operation = Task {
                do { try await analyzer?.finalizeAndFinishThroughEndOfInput() }
                catch { if !Task.isCancelled { completeFinish() } }
            }
        }
    }

    private func completeFinish() {
        let completion = afterFinish
        stop(with: heardSpeech ? nil : .noSpeech)
        completion?()
    }

    private func stopMicrophone(flush: Bool = false) {
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            self.engine = nil
        }
        input?.finish(flush: flush)
        input = nil
        if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        }
    }

    func stop(with reason: Notice? = nil) {
        sessionID = nil
        operation?.cancel()
        results?.cancel()
        detection?.cancel()
        silence?.cancel()
        limit?.cancel()
        finishTimeout?.cancel()
        installation?.cancel()
        installation = nil
        stopMicrophone()
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
        updateDraft = nil
        afterFinish = nil
        phase = .idle
        if let reason { showNotice(reason) }
    }

    func dismissNotice() {
        noticeTimeout?.cancel()
        notice = nil
    }

    private func showNotice(_ reason: Notice) {
        dismissNotice()
        notice = reason
        let seconds = switch reason {
        case .permission, .downloadFailed: 6
        case .noSpeech: 2
        case .error: 4
        }
        noticeTimeout = Task {
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            notice = nil
        }
    }
}

private nonisolated final class DictationAudioInput: Sendable {
    private let converter: Mutex<AnalyzerInputConverter>
    private let continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation

    init(format: AVAudioFormat, continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation) {
        converter = Mutex(AnalyzerInputConverter(analyzerFormat: format))
        self.continuation = continuation
    }

    func receive(_ buffer: AVReadOnlyAudioPCMBuffer) {
        do {
            try converter.withLock {
                for audio in try $0.convert(AVAudioPCMBuffer(copying: buffer), at: nil) {
                    continuation.yield(audio)
                }
            }
        } catch {
            continuation.finish(throwing: error)
        }
    }

    func finish(flush: Bool) {
        do {
            if flush {
                try converter.withLock {
                    for audio in try $0.flush() { continuation.yield(audio) }
                }
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
}
