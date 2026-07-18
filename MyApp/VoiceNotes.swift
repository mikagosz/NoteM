import AVFoundation
import Foundation
import Observation
import Speech

/// Notatki głosowe (Priorytet 4): dyktowanie na żywo.
///
/// Klik mikrofonu → aplikacja słucha i rozpoznany tekst pojawia się w notatce
/// od razu w trakcie mówienia (żaden plik audio nie jest zapisywany).
/// Rozpoznawanie działa on-device: najpierw nowy `SpeechTranscriber`
/// (macOS 26, obsługuje polski), a gdy niedostępny — starszy
/// `SFSpeechRecognizer` w trybie on-device.
@MainActor
@Observable
final class VoiceDictation {
    enum Phase {
        case idle
        /// Between the mic click and the first listened sample (permissions,
        /// model download on first use).
        case preparing
        case listening
    }

    private(set) var phase: Phase = .idle
    /// When listening started (drives the elapsed-time label).
    private(set) var startedAt: Date?
    /// Human-readable problem (mic access denied / no speech model), if any.
    private(set) var lastError: String?

    /// Called on the main actor with the full text of the current session
    /// every time it changes — including tentative (volatile) fragments that
    /// get refined as recognition improves.
    var onTranscript: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    /// Tears down the tap/engine and terminates the audio input stream.
    private var stopEngine: (() -> Void)?
    /// Waits for the recognizer to finalize pending results after stopping.
    private var finishAnalysis: (() async -> Void)?
    private var resultsTask: Task<Void, Never>?
    /// Finalized phrases of the session, in spoken order.
    private var finalizedText = ""
    /// Tentative tail of the session, replaced on every refinement.
    private var volatileText = ""

    /// Starts listening. Returns `false` (with `lastError` set) when the
    /// microphone or on-device speech recognition is unavailable.
    func start() async -> Bool {
        guard phase == .idle else { return false }
        lastError = nil
        guard await Self.requestMicrophoneAccess() else {
            lastError = Loc.t("Brak dostępu do mikrofonu — zezwól w Ustawieniach systemowych → Prywatność i ochrona → Mikrofon.",
                              "No microphone access — allow it in System Settings → Privacy & Security → Microphone.")
            return false
        }
        phase = .preparing
        finalizedText = ""
        volatileText = ""

        // Polski ma pierwszeństwo niezależnie od silnika: nowy SpeechTranscriber
        // nie zna polskiego (stan macOS 26), więc dla polskiego używany jest
        // starszy SFSpeechRecognizer z modelem on-device. Angielski dopiero,
        // gdy polski jest niedostępny w żadnym silniku.
        var started = false
        if #available(macOS 26, *) {
            started = await startModern(languagePrefix: "pl")
        }
        if !started {
            started = await startLegacy(identifier: "pl-PL")
        }
        if !started, #available(macOS 26, *) {
            started = await startModern(languagePrefix: "en")
        }
        if !started {
            started = await startLegacy(identifier: "en-US")
        }
        if started {
            phase = .listening
            startedAt = Date()
        } else {
            phase = .idle
            lastError = Loc.t("Rozpoznawanie mowy jest niedostępne na tym Macu (brak polskiego modelu on-device).",
                              "Speech recognition is unavailable on this Mac (no on-device Polish model).")
        }
        return started
    }

    /// Stops listening and waits for the last pending fragment to finalize.
    func stop() async {
        guard phase == .listening else { return }
        stopEngine?()
        stopEngine = nil
        await finishAnalysis?()
        finishAnalysis = nil
        await resultsTask?.value
        resultsTask = nil
        phase = .idle
        startedAt = nil
    }

    /// Full text of the session so far (finalized + tentative tail).
    private func emit() {
        var text = finalizedText
        if !volatileText.isEmpty {
            if !text.isEmpty { text += " " }
            text += Self.continuingSentence(volatileText, after: finalizedText)
        }
        onTranscript?(text)
    }

    private func appendFinalized(_ text: String) {
        guard !text.isEmpty else { return }
        let adjusted = Self.continuingSentence(text, after: finalizedText)
        if !finalizedText.isEmpty { finalizedText += " " }
        finalizedText += adjusted
    }

    /// The recognizer capitalizes the start of every segment, but a segment
    /// that follows a comma (or no punctuation at all — a pause mid-sentence)
    /// continues the previous sentence, so its first letter goes lowercase.
    private static func continuingSentence(_ tail: String, after head: String) -> String {
        guard let last = head.last else { return tail }
        let sentenceEnders: Set<Character> = [".", "!", "?", "…", "\n"]
        guard !sentenceEnders.contains(last) else { return tail }
        guard let first = tail.first, first.isUppercase else { return tail }
        return tail.prefix(1).lowercased() + tail.dropFirst()
    }

    // MARK: - New API (SpeechAnalyzer, macOS 26)

    @available(macOS 26, *)
    private func startModern(languagePrefix: String) async -> Bool {
        let supported = await SpeechTranscriber.supportedLocales
        guard let locale = supported.first(where: { $0.identifier.hasPrefix(languagePrefix) }) else {
            return false
        }

        // progressiveTranscription = preset for live audio: instant tentative
        // text, refined and finalized as more context arrives.
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        do {
            // Download the on-device model on first use (no-op afterwards).
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                return false
            }
            let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            try await analyzer.start(inputSequence: inputSequence)

            let forwarder = TapForwarder(analyzerFormat: format, builder: inputBuilder)
            let input = audioEngine.inputNode
            input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { buffer, _ in
                forwarder.forward(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()

            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard let self else { break }
                        let text = String(result.text.characters)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if result.isFinal {
                            self.appendFinalized(text)
                            self.volatileText = ""
                        } else {
                            self.volatileText = text
                        }
                        self.emit()
                    }
                } catch {
                    // Stream ended (session finished or analyzer error).
                }
            }
            stopEngine = { [audioEngine] in
                audioEngine.inputNode.removeTap(onBus: 0)
                audioEngine.stop()
                forwarder.finish()
            }
            finishAnalysis = {
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            return true
        } catch {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            return false
        }
    }

    /// Converts mic buffers to the analyzer's format on the audio thread and
    /// feeds them to the analyzer's input stream. (Apple's
    /// `AnalyzerInputConverter` needs macOS 27, so the conversion is done by
    /// hand with `AVAudioConverter`.)
    @available(macOS 26, *)
    private final class TapForwarder: @unchecked Sendable {
        private let analyzerFormat: AVAudioFormat
        private let builder: AsyncStream<AnalyzerInput>.Continuation
        private var converter: AVAudioConverter?

        init(analyzerFormat: AVAudioFormat, builder: AsyncStream<AnalyzerInput>.Continuation) {
            self.analyzerFormat = analyzerFormat
            self.builder = builder
        }

        func forward(_ buffer: AVAudioPCMBuffer) {
            guard let converted = convert(buffer) else { return }
            builder.yield(AnalyzerInput(buffer: converted))
        }

        func finish() {
            builder.finish()
        }

        private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
            if buffer.format == analyzerFormat { return buffer }
            if converter == nil {
                converter = AVAudioConverter(from: buffer.format, to: analyzerFormat)
            }
            guard let converter else { return nil }
            let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else {
                return nil
            }
            var supplied = false
            var conversionError: NSError?
            converter.convert(to: output, error: &conversionError) { _, status in
                if supplied {
                    // .noDataNow (not .endOfStream) keeps the converter usable
                    // for the next mic buffer of the live stream.
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            return conversionError == nil ? output : nil
        }
    }

    // MARK: - Legacy fallback (SFSpeechRecognizer)

    private func startLegacy(identifier: String) async -> Bool {
        guard await Self.requestSpeechAuthorization() else { return false }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier)),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { return false }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true

        let input = audioEngine.inputNode
        input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            return false
        }

        // Po pauzie w mówieniu rozpoznawanie on-device zamyka segment (wynik
        // z `speechRecognitionMetadata`) i kolejne wyniki częściowe zaczynają
        // od zera — dlatego zamknięty segment dokleja się do `finalizedText`,
        // a wyniki częściowe podmieniają tylko bieżącą końcówkę.
        recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let result else { return }
            let text = result.bestTranscription.formattedString
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let segmentDone = result.isFinal || result.speechRecognitionMetadata != nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                if segmentDone {
                    self.appendFinalized(text)
                    self.volatileText = ""
                } else {
                    self.volatileText = text
                }
                self.emit()
            }
        }
        stopEngine = { [audioEngine] in
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            request.endAudio()
        }
        return true
    }

    // MARK: - Permissions

    private static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private static func requestSpeechAuthorization() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
