# Windows browser history, bookmarks and metadata import

`BrowserPanel` keeps its existing create/request/tab/profile APIs. Its toolbar now
contains a bookmark star and a native Bookmarks and History pane. The star updates
from the selected profile and toggles an explicit bookmark, including in private
tabs, matching the Mac browser. Successful ordinary navigation records history;
private and credential-private tabs do not record history. Credential echo checks
also protect the bookmark URL/title.

The default selected persistent profile shares one library across conversations.
The existing explicit `isolate_thread_profiles=true` option selects separate
library directories. Private WebView profiles never create an automatic private
history store. An explicit private-page bookmark belongs to the selected ordinary
library, as on Mac.

`App/BrowserLibraryPanel.h` provides native search, open, selected-row removal,
confirmed Clear History, import-file selection, immutable metadata preview,
selected-row review and confirmed merge. Clearing history retains bookmarks and
marks the current profile's saved tab URLs blank without closing the live pages;
a later explicit navigation can be restored again. Deletion timestamps/fingerprints
prevent already queued older visits from repopulating cleared history. Removed
URLs are not retained as plaintext deletion markers.

## Root integration

The toolbar works without new Root routes. Optional hooks:

```cpp
browser->set_owner(ownerHwnd);         // Parent the native metadata-file chooser.
browser->show_library();               // Optional Settings > Browser entrypoint.
co_await browser->flush_library(true);  // Before graceful final close: stop new
                                      // automatic records and await owned saves.
browser->close();
```

`library_idle()` reports pending history/bookmark work and accepted library saves.
`flush_library(false)` also supports ordinary explicit flushes; final flush has a
10-second wait bound and reports a still-running save rather than claiming it was
durable. Pending owner confirmations are not accepted by flushing. The optional
`set_library_confirmation(Confirm)` binds Root's trusted native dialog service;
otherwise the pane uses Cancel-default ContentDialogs and hides them on close.
No browser tool or website field can supply this approval callback.

`library_directory(thread)` returns the app-owned selected-profile library path.
`Runtime/BrowserLibrary.h` exposes a worker-only `Store(directory)` with `open`,
stale-snapshot-checked `commit`, and serialized `update`. `Snapshot` and
`Contents` are useful for Root settings and tests. Known schema version/format
boundaries are strict; unknown supported-version root/row fields survive updates.
Invalid, future, stale or physically replaced storage is preserved and reported.

## Storage and import boundaries

- File: `<browser-root>/library/Default/browser-library.json`, or the explicit
  isolated conversation profile key. Format `coincide.windows.browser-library`,
  version 1. History is bounded to 10,000 records; bookmarks to 5,000. File bound:
  16 MB. New files/directories receive a current-user/SYSTEM protected DACL.
- Writers acquire a physical-directory scoped file lease, read fresh state,
  prevalidate the full next schema, flush a unique private temporary file, and
  atomically replace the library. Short-lived ancestor handles prevent path
  replacement. Explicit stale snapshots fail instead of overwriting newer work.
  The existing native local-file policy limits profile paths to 240 characters;
  linked, offline, remote or replaced profile folders are refused.
- URLs are HTTP(S) only, with no userinfo/fragments or named sensitive auth query
  values. Import data is allowlisted; cookies, credentials, preferences, browser
  sessions and raw unknown source fields never merge into the library.
- Opening the browser/pane reads Coincide's own library only. External browser
  data is read solely after the owner chooses a source file or explicitly previews
  its typed path. There is no automatic owner-browser/profile scan.
- Supported sources: Chrome/Edge/Chromium bookmark JSON (including `Bookmarks`),
  Firefox bookmark JSON, Netscape bookmark HTML, Windows Coincide library JSON,
  and the real Mac BrowserLibrary Codable file (including its 2001 Date epoch).
- `History`/`history.sqlite` and Firefox `places.sqlite` use Windows' system
  `winsqlite3.dll`, loaded only from System32 using installed SDK ABI types.
  Main database (128 MB max) and optional WAL (64 MB max) are copied into a unique
  protected temporary directory. SQLite queries the copy only. Fixed supported
  history/bookmark queries have 5,000-row limits per kind, bounded text/SQL and
  a five-second VM progress deadline. No extension, arbitrary SQL or credential
  table query is exposed. Only known owned snapshot files are removed afterward.
  An active rollback journal is refused; close/export that browser database and
  explicitly preview it again. Chromium/Firefox hidden history rows are excluded.
- Preview stores source hashes, not a retained raw owner export. Source main/WAL
  fingerprints are checked before import; changing/busy sources need a new preview.
  Native import confirms exact selected row counts and source file. Duplicate
  bookmarks are merged once; existing history keeps larger counts/later dates.
- Unsupported formats (for example compressed Firefox JSONLZ4, cookie/password
  exports and unrecognized SQLite schemas) fail explicitly. A missing Windows
  system reader requests supported HTML/JSON rather than pretending to import.

Bounds limit records, bytes and SQLite execution; local filesystem-driver latency
is not a guaranteed wall-clock deadline. Source files are opened for reading only;
browser database/shm/sign-in state is never opened for writing. No model/network
or account action is part of metadata import.

## Offline validation entrypoints

- `browser_library_tests(report)`: actual private app-store files, atomic failures,
  stale writers, concurrent native writers, schema/unknown-field preservation,
  queued visit removal, real Chromium/Firefox/Netscape/Mac formats, source changes.
- `browser_history_sqlite_tests(report)`: actual OS SQLite with owned committed
  main/WAL data, Chromium/Firefox fixed metadata queries, original byte preservation,
  and changed/unsupported source refusal. No owner browser database is read.
- `browser_library_panel_tests(report, xamlRoot)`: native controls/confirmations,
  row selection, real owned WebView2 virtual origins/private profiles, explicit
  private bookmarks, synthetic approved-fill exclusion, profile sharing/isolation,
  clear/restore semantics and save flush. No external website or actual account.
- Existing 43 offline browser engine regressions remain required after BrowserPanel
  integration; this feature does not replace their coverage.
