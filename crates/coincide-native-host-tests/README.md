# Internal native adapter test host

This unpublished library mounts the desktop production Computer Use module by
path, including its unchanged fake and opt-in owned-window tests. It provides
fast Windows and Linux SDK and native fixture feedback before compiling the UI toolkit.
It creates no distribution binary and replaces no desktop checks.

Ordinary tests are inert. The ignored owned-window case runs only on a fresh
GitHub runner with its existing explicit fixture marker. Never run it against
a personal desktop.

The Linux host mounts the same production Appshots platform and notification
activity modules for shared bounded X11 helpers and the real Observation type.
It adds GTK only for the unchanged owned synthetic child. Linux native tests
require a fresh runner, private D-Bus and Xvfb plus the existing opt-in marker.
Wayland refusal is tested separately. No UI toolkit from the application is used.
