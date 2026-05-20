import AppKit
import AVFoundation

/// macOS read-aloud controller built on `AVSpeechSynthesizer`. One instance
/// lives per document window. Callers hand in *plain text* (markdown should
/// already be rendered to plain text via `MarkdownAttributedRenderer`); the
/// synthesizer then emits word-range callbacks so the UI can highlight the
/// currently-spoken word in lock-step with the audio.
///
/// State transitions:
///
///     idle ── speak() ──▶ speaking ── stop() / didFinish ──▶ idle
///                 ▲           │
///                 │           ├── pause() ──▶ paused
///                 │           ▲
///                 │           │
///                 └── resume()┘
///
/// Delegate callbacks from AVSpeechSynthesizer are nominally delivered on the
/// audio session queue. Because the synthesizer is created on the main actor,
/// in practice macOS routes them back to the main thread; we still hop
/// defensively via `MainActor.assumeIsolated` for Swift 6 isolation safety.
@MainActor
final class SpeechController: NSObject {

    enum State: Equatable {
        case idle
        case speaking
        case paused
    }

    private let synthesizer = AVSpeechSynthesizer()

    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    /// Plain text of the most recent utterance. Word ranges from the
    /// `willSpeakRange` callback index into this string.
    private(set) var spokenText: String = ""

    /// Range (in `spokenText`) of the word currently being spoken, or a
    /// `NSNotFound` range when no word is active.
    private(set) var currentWordRange = NSRange(location: NSNotFound, length: 0) {
        didSet {
            guard currentWordRange != oldValue else { return }
            onWordRangeChange?(currentWordRange)
        }
    }

    /// Notified whenever the spoken word changes (including being cleared).
    var onWordRangeChange: ((NSRange) -> Void)?

    /// Notified whenever the controller transitions between idle / speaking /
    /// paused. Use this to refresh menu enablement and toolbar state.
    var onStateChange: ((State) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isActive: Bool { state != .idle }
    var isSpeaking: Bool { state == .speaking }
    var isPaused: Bool { state == .paused }

    /// Speak `text` from the start. Any in-flight utterance is cancelled.
    /// `language` is a BCP-47 tag (e.g. "en-US"); nil falls back to the user's
    /// system language. Empty / whitespace-only text is a no-op.
    func speak(_ text: String, language: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }

        spokenText = text
        currentWordRange = NSRange(location: NSNotFound, length: 0)

        let utterance = AVSpeechUtterance(string: text)
        let tag = language ?? AVSpeechSynthesisVoice.currentLanguageCode()
        utterance.voice = AVSpeechSynthesisVoice(language: tag)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0

        synthesizer.speak(utterance)
    }

    /// Stop immediately. No-op when already idle.
    func stop() {
        guard synthesizer.isSpeaking || synthesizer.isPaused else { return }
        synthesizer.stopSpeaking(at: .immediate)
        // didCancel will reset state, but in case it doesn't fire promptly
        // make the transition deterministic for menu validation.
        currentWordRange = NSRange(location: NSNotFound, length: 0)
        state = .idle
    }

    /// Pause if speaking, resume if paused. Returns `true` when the state
    /// actually changed.
    @discardableResult
    func togglePause() -> Bool {
        switch state {
        case .speaking:
            return synthesizer.pauseSpeaking(at: .word)
        case .paused:
            return synthesizer.continueSpeaking()
        case .idle:
            return false
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechController: AVSpeechSynthesizerDelegate {

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didStart utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated { self.state = .speaking }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated {
            self.currentWordRange = NSRange(location: NSNotFound, length: 0)
            self.state = .idle
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didPause utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated { self.state = .paused }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didContinue utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated { self.state = .speaking }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated {
            self.currentWordRange = NSRange(location: NSNotFound, length: 0)
            self.state = .idle
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated { self.currentWordRange = characterRange }
    }
}
