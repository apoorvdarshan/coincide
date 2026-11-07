# Browser address and user-turn controls

The native address field resolves HTTP(S) addresses, local development servers,
user-selected local file paths, and searches. The search provider is saved in
`browser.json` without replacing other fields. Inline completion reads bookmarks
and the selected persistent profile's history off the UI thread. Private profiles
do not complete from saved history.

Agent `search` requests become HTTP(S) navigation using the selected search
provider. Agent navigation does not gain local-file access. A local folder grant
created by the user typing a file path ends when the tab navigates to web content.

`ask-user` displays a per-thread Your turn banner with Done and Not Now. A newer
request supersedes the prior one. Results distinguish done, declined, timeout,
superseded and cancelled; the engine and CLI retain the requested timeout plus
receipt allowance. Messages and request durations remain bounded.

`viewport` accepts explicit bounded dimensions, mobile/tablet/desktop presets,
or reset. The native view fits the panel using page zoom while retaining the
requested CSS layout dimensions where native pixel geometry can represent them.
Windows aligns integral child-view bounds and continuous zoom together to avoid
losing a CSS row in narrow panels. Extreme custom dimensions at small fit scales
can remain approximate when no integral native geometry represents the requested
CSS dimensions; this does not establish universal viewport emulation precision.

## Verification boundary

The recovered implementation passes formatting, core strict clippy, desktop
checks including tests/examples, 49 browser-related core tests, 32 address/UI
filtered desktop tests, and 47 browser-owner tests. Those checks use temporary
files and inert unit fixtures. They do not establish native renderer, pixels,
keyboard completion, chooser permissions, or three-platform UI acceptance.
Those checks belong on disposable GitHub runners; no personal browser, vault,
profile, installed app, or running Swift instance was used.
