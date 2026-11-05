# Windows dictation shortcut

Voice and its global shortcut both default to off. In **Voice**, choose an existing local whisper CLI and a model,
enable Voice, enable **Global dictation shortcut: Ctrl+Shift+Space**, choose a behavior, then **Save**. Nothing downloads,
records, or transcribes merely because the settings pane opens or the shortcut is registered.

- **Hold to dictate:** press Ctrl+Shift+Space to begin. Releasing the chord stops capture and transcribes it. Releasing
  while the microphone is still preparing requests one stop as soon as preparation finishes.
- **Tap to start or stop:** the first tap starts recording; the next tap stops and transcribes. Key repeat cannot start
  another recording.

The shortcut opens Coincide's Voice pane so recording state and Cancel remain visible. It requires an available,
writable selected conversation and ignores native modal dialogs. Final text is appended only if that same conversation
and draft revision still match. It never sends or queues an agent message. Cancel, disabling the shortcut, closing the
window, and quitting discard active capture/transcription; canceled or superseded workers cannot insert late text.

With background operation enabled and the notification area available, an opted-in shortcut keeps Coincide available
in the notification area after its window is closed. An explicit Quit unregisters it. The shortcut does not work after
the application exits. Other Windows keyboard preferences and input behavior are not changed.

If another configured action or application reserves the chord, settings are saved but the shortcut remains inactive,
and Voice reports that it is unavailable. Resolve the conflict and choose Save again to retry registration. There is no
automatic fallback key or microphone activation.

The portable gesture suite passes locally. Injected native registration/message tests and synthetic Voice-panel
regressions cover lifecycle, registration conflicts, early release, cancellation and original-draft protection. Native
CI execution remains a separate verification gate. No real hotkey, microphone, installed engine or model recognition
acceptance is claimed by these synthetic tests. Cloud transcription, automatic model downloads and partial-result
dictation remain separate parity work.
