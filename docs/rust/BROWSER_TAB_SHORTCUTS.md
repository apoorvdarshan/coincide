# Browser-local tab shortcuts

The browser pane handles Command-T / Command-W / Command-Shift-[ / Command-Shift-]
on macOS and Control equivalents on Linux and Windows. They create a tab, close
the active tab, and cycle backward/forward. New tabs focus the address field;
closing the last tab returns focus to the composer.

Chrome dispatch requires the active window and focused browser pane. Native
callbacks belong to the exact owned page view, snapshot its navigation epoch,
and enqueue a bounded typed command. Dispatch rechecks the selected thread,
active tab, visibility, epoch, native URL and current exact-view native focus.
A queued key cannot borrow browser chrome focus after the composer, settings or
another native view takes focus. Windows owns GotFocus/LostFocus registrations
and also checks the current foreground queue focus HWND against the captured
exact native descendant, so delayed LostFocus delivery cannot authorize dispatch.
macOS and GTK read the actual responder/widget focus at dispatch. Hidden/sibling views, inactive
windows, overlays, extra modifiers and ordinary page keys do not gain a global
command route. Recognized stale native chords are consumed. Agent page-key host
chords remain denied; no script or arbitrary-key API invokes this route.

Each adapter owns its registration and captured shutdown leases: a local
NSEvent monitor, WebView2 accelerator handler, or GTK widget signal. Removal and
callback-owner return are distinct from proving native SDK deallocation.

Pure recognition/scope tests and metadata compilation can run locally. The
fresh-runner-only example exercises production callbacks using disposable owned
views, four fixed chords, sibling focus, hidden views, plain-key refusal and the
shutdown fence. Native runner results and whole-app interactive acceptance are
separate evidence; source compilation alone establishes neither.
