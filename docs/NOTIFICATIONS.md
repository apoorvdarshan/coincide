# Native thread notifications

In Settings → General → Thread notifications, choose Off, Notifications only,
Sound only, or Notifications with sound. The default is Off. Choosing desktop
notifications requests macOS notification permission when necessary. If access
was denied, enable Coincide in System Settings → Notifications and use Check
Notification Permission.

Background notifications report observed completion, a pending approval or
question, or a failed run. Their body includes the thread name, never transcript
content, tool arguments, provider errors or account information. Opening one
selects the still-existing, unarchived conversation and reveals the main window.
One current notification per thread contributes to its Dock attention count.
Returning to the app clears pending/delivered notifications and that count.

Sound modes also play while the app is active. Completion uses the system Glass
sound and input/failure uses Submarine; simultaneous events share a short
coalescing window. These are native system sounds rather than bundled T3 audio.

History loading/import, rewind, interrupted or explicitly stopped runs, and
archived conversations do not produce completion alerts. Delivery revalidates
the exact current alert occurrence before sound and after permission/submission
waits. Resolving a request, starting another run, renaming, archiving or deleting
a conversation invalidates queued alerts and removes stale notification/badge
state. Unarchiving cannot resurrect a previous queued occurrence.

SwiftPM test helpers and the synthetic UI bundle never request OS permission,
play sounds or change the application's Dock badge. Core regressions verify
transitions, deduplication, history/Stop suppression, failure-load behavior and
queued-alert invalidation. Actual OS permission, delivery, sound and click
interaction still require packaged-app acceptance. In-app foreground banners and
remote/multi-environment notification behavior remain parity gaps.
