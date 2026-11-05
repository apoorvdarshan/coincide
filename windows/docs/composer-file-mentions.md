# Project file mentions on Windows

In an ordinary project conversation, type `@` followed by part of a file name or relative path. Suggestions search
that conversation's declared project folder. Choose a row and press Tab or Enter, or use **Insert file mention**.
Arrow keys change the choice; Escape closes suggestions. Ctrl+Enter and Shift+Enter retain their normal editor
behavior. The selected relative path replaces only the current `@` token; paths containing spaces are quoted.
Insertion updates the draft and never sends a message, starts a provider, adds an attachment or changes queued work.

Discovery reads directory entries and file attributes, never file contents. It runs on a cancellable worker and
excludes hidden/system files, dot folders/files, dependency/build directories, reparse points, placeholder files and
hard links. Roots must be local fixed/RAM storage and have no linked ancestors. The walk is bounded to 20,000
visited entries, 5,000 files, 32 nested directories and 2 MiB of path metadata, with a two-second soft scan deadline.
Filesystem driver latency can exceed that deadline; it is not a hard kernel-I/O timeout. Partial scans say so.

Matching folds Unicode case and accepts `/` or `\` in the query. At most 30 matching file paths are shown. Before
insertion, a worker pins the original directory chain and verifies the exact selected file ID. It then rechecks the
conversation, project, draft revision, current text and UTF-16 caret/selection. Replaced files, junction swaps and
stale results leave the draft unchanged. Projectless conversations and bot-managed folders are outside this picker.

Portable trigger, insertion and path-matching tests pass locally. Native filesystem, component and full-app owned
project coverage is included; exact-head Windows CI and physical acceptance remain required before claiming them
verified. The feature does not execute discovered instructions or read files into the message.
