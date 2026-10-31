import AppKit
import CoincideKit
import Testing

@testable import Coincide

/// Dictation in the composer: the microphone follows Settings › Voice, and no keys are watched until the keyboard
/// shortcut is turned on. Uses a window that is never shown, and never the real microphone.
@MainActor
struct DictationComposerTests {
    private func composer() -> (ComposerViewController, AppStore, NSWindow, TemporaryDirectory) {
        let folder = TemporaryDirectory("dictation-composer")
        let store = AppStore(directory: folder.url)
        let registry = ProviderRegistry(store: store, providers: [])
        let composer = ComposerViewController(store: store, registry: registry, runner: ThreadRunner(store: store, registry: registry))
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 400), styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = composer.view
        return (composer, store, window, folder)
    }

    @Test func theMicrophoneFollowsTheVoiceSetting() {
        let (composer, store, _, folder) = composer()
        _ = folder
        #expect(composer.footer.micButton.isHidden == false)
        #expect(composer.footer.dictationIndicator.isHidden)
        store.updateSettings { $0.voice.isEnabled = false }
        #expect(composer.footer.micButton.isHidden)
        store.updateSettings { $0.voice.isEnabled = true }
        #expect(composer.footer.micButton.isHidden == false)
    }

    @Test func noKeysAreWatchedUntilTheShortcutIsOn() {
        let (composer, store, window, folder) = composer()
        _ = (folder, window)
        #expect(store.settings.voice.shortcutEnabled == false)
        store.updateSettings { $0.voice.changeSomethingElse() }
        #expect(composer.isDictationShortcutInstalled == false)
        store.updateSettings { $0.voice.shortcutEnabled = true }
        #expect(composer.isDictationShortcutInstalled)
        store.updateSettings { $0.voice.shortcutEnabled = false }
        #expect(composer.isDictationShortcutInstalled == false)
        // Voice off takes the shortcut with it.
        store.updateSettings {
            $0.voice.shortcutEnabled = true
            $0.voice.isEnabled = false
        }
        #expect(composer.isDictationShortcutInstalled == false)
    }

    @Test func withoutAThreadThereIsNothingToDictateInto() {
        let (composer, _, _, folder) = composer()
        _ = folder
        #expect(composer.canDictate == false)
        #expect(composer.isDictating == false)
        composer.toggleDictation()
        #expect(composer.isDictating == false)
    }

    @Test func theSearchFindsVoiceSettings() {
        let entries = SettingsSearchResults.entries(kinds: [])
        for query in ["dictation", "microphone", "Whisper", "Groq", "OpenAI", "push to talk", "Fn", "send when I stop"] {
            #expect(entries.contains { $0.pane == .section(.voice) && $0.matches(query) }, "Missing search entry: \(query)")
        }
        #expect(SettingsSection(rawValue: "voice") == .voice)
    }

    @Test func shortcutConflictsAreNamed() throws {
        let optionSpace = DictationShortcut.keys(try #require(KeyShortcut("alt+space")))
        #expect(DictationShortcutConflicts.warnings(for: optionSpace).contains { $0.contains("non-breaking space") })
        let spotlight = DictationShortcut.keys(try #require(KeyShortcut("mod+space")))
        #expect(DictationShortcutConflicts.warnings(for: spotlight).contains { $0.contains("Spotlight") })
        #expect(DictationShortcutConflicts.warnings(for: .modifier(.fn)).isEmpty)
    }

    @Test func theMenuNamesTheShortcutOnlyWhenItsOn() {
        var voice = VoiceSettings()
        #expect(DictationMenu.subtitle(for: voice) == nil)
        voice.shortcutEnabled = true
        #expect(DictationMenu.subtitle(for: voice) == "Hold or tap 🌐 fn")
        voice.shortcutMode = .tap
        #expect(DictationMenu.subtitle(for: voice) == "Tap 🌐 fn")
    }
}

extension VoiceSettings {
    /// A change to settings that leaves the shortcut alone.
    fileprivate mutating func changeSomethingElse() { sendsWhenStopped.toggle() }
}
