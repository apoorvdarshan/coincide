# Internal native adapter test host

This unpublished library mounts the desktop production Computer Use module by
path, including its unchanged fake and opt-in owned-window tests. It provides
fast Windows SDK and native fixture feedback before compiling the UI toolkit.
It creates no distribution binary and replaces no desktop checks.

Ordinary tests are inert. The ignored owned-window case runs only on a fresh
GitHub runner with its existing explicit fixture marker. Never run it against
a personal desktop.
