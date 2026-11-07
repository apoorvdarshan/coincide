# Coincide local patch

This is the already locked `gpui-base` 0.9.0 package from crates.io, upstream
commit `7591a35eced761e3613c01e71ff04c10129dae1a` (`crates/base`). Its original
Apache 2.0 license and source files are preserved. The Cargo registry is not
modified. The registry's `.cargo-ok` cache marker is omitted.

Local source changes:

- `src/input/base/state.rs`: registers and re-exports the small native preview
  module.
- `src/input/base/native_preview.rs`: textarea-only source and native revision
  checked transient replacement. Preserves the complete prior undo/redo manager
  and restores edit/event flags with an unwind-safe scope. Refuses read-only,
  disabled, IME composition, token metadata, multiple cursors, open transactions,
  stale source, invalid grapheme boundaries and excessive text. Transient edits
  notify layout without emitting user Change or InputEditsEvent.
- `src/input/base/native_preview_tests.rs`: private TestPlatform coverage for
  prior history + one final undo/redo, Unicode/focus, changed source, IME,
  read-only admission and actual unwind restoration. No host input/device use.

The application must restore the exact original source before a final ordinary
edit or user edit/undo. This patch does not add an agent or JSON authority API.
