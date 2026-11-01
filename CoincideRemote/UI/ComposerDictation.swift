@preconcurrency import AVFAudio
import Observation
import SwiftUI

/// Dictation in Coincide Remote's composer, with Apple's on-device recognition (the Mac's `AppleSpeechRecognizer`):
/// the microphone permission is asked for the first time the user taps the microphone, partial text streams into the
/// draft as they speak, and nothing is sent until they send it.
@Observable
final class RemoteDictation {
    enum State: Equatable {
        case idle
        case preparing(progress: Double?)
        case listening(since: Date)
        case finishing
    }

    private(set) var state: State = .idle
    private(set) var level: Float = 0
    var error: String?
    /// The microphone or speech recognition was refused; the alert offers Settings.
    private(set) var needsSettings = false

    @ObservationIgnored private var recognizer: AppleSpeechRecognizer?
    @ObservationIgnored private var capture: AudioCapture?
    @ObservationIgnored private var insertion: DictationInsertion?
    @ObservationIgnored private var original = ""
    @ObservationIgnored private var draft: Binding<String>?
    @ObservationIgnored private var generation = 0

    var isActive: Bool { state != .idle }

    func toggle(draft: Binding<String>) {
        if isActive { stop() } else { start(draft: draft) }
    }

    func start(draft: Binding<String>) {
        guard state == .idle else { return }
        generation += 1
        let generation = generation
        self.draft = draft
        original = draft.wrappedValue
        insertion = DictationInsertion(text: original, selection: NSRange(location: (original as NSString).length, length: 0))
        state = .preparing(progress: nil)
        Task {
            do {
                guard await AVAudioApplication.requestRecordPermission() else {
                    needsSettings = true
                    throw DictationFailure(String(localized: "Coincide Remote doesn’t have access to the microphone. Turn it on in Settings."))
                }
                let recognizer = AppleSpeechRecognizer(locale: .autoupdatingCurrent)
                self.recognizer = recognizer
                try await recognizer.prepare { fraction in
                    Task { @MainActor in
                        guard self.generation == generation, case .preparing = self.state else { return }
                        self.state = .preparing(progress: fraction)
                    }
                }
                guard self.generation == generation, let format = await recognizer.audioFormat() else { return }
                try await recognizer.begin { text in
                    Task { @MainActor in
                        guard self.generation == generation, case .listening = self.state else { return }
                        self.show(text)
                    }
                }
                let capture = AudioCapture()
                try capture.start(
                    deviceUID: nil, format: format, sink: { recognizer.append($0) },
                    level: { level in Task { @MainActor in self.level = level } })
                guard self.generation == generation else {
                    capture.stop()
                    return
                }
                self.capture = capture
                state = .listening(since: Date())
            } catch {
                guard self.generation == generation else { return }
                if (error as? AppleSpeechRecognizer.Failure) == .notAuthorized { needsSettings = true }
                fail(error)
            }
        }
    }

    func stop() {
        guard case .listening = state, let recognizer else { return cancel() }
        let generation = generation
        capture?.stop()
        capture = nil
        state = .finishing
        Task {
            let text = (try? await recognizer.finish()) ?? ""
            guard self.generation == generation else { return }
            show(text)
            finish()
        }
    }

    /// Stops and takes partial text back out.
    func cancel() {
        guard state != .idle else { return }
        generation += 1
        capture?.stop()
        capture = nil
        if let recognizer { Task { await recognizer.cancel() } }
        draft?.wrappedValue = original
        finish()
    }

    private func show(_ text: String) {
        guard var insertion, let draft, let edit = insertion.update(text) else { return }
        let current = draft.wrappedValue as NSString
        guard NSMaxRange(edit.range) <= current.length else { return }
        draft.wrappedValue = current.replacingCharacters(in: edit.range, with: edit.replacement)
        self.insertion = insertion
    }

    private func fail(_ error: Error) {
        capture?.stop()
        capture = nil
        if let recognizer { Task { await recognizer.cancel() } }
        draft?.wrappedValue = original
        self.error = error.localizedDescription
        finish()
    }

    private func finish() {
        recognizer = nil
        insertion = nil
        draft = nil
        level = 0
        state = .idle
    }
}

private struct DictationFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// The microphone in the composer's footer, beside attach: the theme's secondary ink at rest, the accent while
/// dictating.
struct DictationButton: View {
    let dictation: RemoteDictation
    let draft: Binding<String>
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            dictation.toggle(draft: draft)
        } label: {
            Image(systemName: dictation.isActive ? "mic.fill" : "mic")
                .font(.body.weight(.medium))
                .foregroundStyle(dictation.isActive ? theme.accent : theme.secondaryInk)
                // Wider when a large text size makes the symbol wider, so it never runs into attach or send.
                .padding(.horizontal, 2)
                .frame(minWidth: 40, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dictation.isActive ? Text("Stop dictating") : Text("Dictate"))
    }
}

/// Above the message while dictating: a level meter in the accent, the time so far and cancel, as on the Mac.
struct DictationBar: View {
    let dictation: RemoteDictation
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var levels = [Float](repeating: 0, count: 9)

    var body: some View {
        HStack(spacing: 8) {
            switch dictation.state {
            case .listening(let since):
                meter
                TimelineView(.periodic(from: since, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(since)))
                    Text(verbatim: String(format: "%d:%02d", seconds / 60, seconds % 60))
                        .font(.footnote.monospacedDigit().weight(.medium))
                        .foregroundStyle(theme.secondaryInk)
                }
            case .preparing(let progress):
                Text(progress.map { String(localized: "Downloading speech model… \(Int(($0 * 100).rounded()))%") } ?? String(localized: "Getting ready…"))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(theme.secondaryInk)
            case .finishing:
                Text("Transcribing…")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(theme.secondaryInk)
            case .idle:
                EmptyView()
            }
            Spacer(minLength: 0)
            Button {
                dictation.cancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(theme.secondaryInk)
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Cancel dictation"))
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .onChange(of: dictation.level) { _, level in
            if reduceMotion {
                levels = [Float](repeating: 0, count: levels.count - 1) + [level]
            } else {
                levels = Array(levels.dropFirst()) + [level]
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Dictation"))
    }

    @ViewBuilder private var meter: some View {
        if reduceMotion {
            Capsule()
                .fill(theme.accent.opacity(0.2))
                .overlay(alignment: .leading) {
                    GeometryReader { geometry in
                        Capsule().fill(theme.accent).frame(width: max(6, geometry.size.width * CGFloat(levels.last ?? 0)))
                    }
                }
                .frame(width: 64, height: 6)
                .accessibilityHidden(true)
        } else {
            HStack(spacing: 2) {
                ForEach(levels.indices, id: \.self) { index in
                    Capsule()
                        .fill(theme.accent)
                        .frame(width: 3, height: max(3, 18 * CGFloat(levels[index])))
                }
            }
            .frame(height: 18)
            .accessibilityHidden(true)
        }
    }
}
