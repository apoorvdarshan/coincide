# Project actions and project settings

Coincide ports T3 Code's project actions, the Project settings category, and
repository-backed defaults to native macOS controls. This page describes what is
implemented and where the safety boundaries are.

## Quick-run toolbar

The toolbar shows a split button for the selected conversation's project:

- The primary entry is the action you ran last in this project, otherwise the first
  action without a setup or settle role, otherwise the first that does not settle
  (T3's `primaryProjectScript`).
- The menu lists every action with role labels such as `Install (setup, on settle)`,
  its shortcut, **Open Preview** entries for actions with a preview URL, **Import
  from t3.json** entries, **Add Action…**, **Run Script…** and **Project Settings…**.
- App-owned actions run directly in a dedicated terminal tab. The run pins the
  action's stable ID and execution digest as displayed, re-reads the settings file
  and refuses the run if the action changed.
- When the project has no actions of its own, t3.json scripts are listed, but
  choosing one opens the existing review sheet first, because the command comes from
  the checkout.

Per-action shortcuts need Command or Control plus one printable key. Standard window
and editing shortcuts are reserved. Shortcuts are active while the window shows the
toolbar. They are stored with the action, not in a `keybindings.json` file.

## Project settings

Open **Project Settings…** from a project header's context menu in the sidebar, or
from the toolbar menu. The sheet contains:

- **Project**: rename (one checkout or the whole group) and icon (Automatic,
  Monogram, Symbol, Emoji, or an image file inside the checkout).
- **Actions**: add, edit, reorder and delete actions, import scripts from t3.json
  (scripts whose command or case-insensitive name already exists are skipped), and
  **Use t3.json…** to drop the project's own list. Coincide never writes t3.json.
  An invalid t3.json is reported.
- **Defaults**: **New thread workspace** and **Worktree submodules**. Each resolves
  in T3's order: this project, all projects, the checkout's t3.json, then the
  built-in value (Local and Recursive). A badge shows which tier applies.
- **Checkouts** with Reveal and Remove, and project removal.

Saving a setup or settle role on one action releases it from any other action, so a
project has at most one of each. Absent fields inherit; an empty action list is an
explicit override with no actions.

## Setup and settle roles

When a project has its own action list, managed worktree setup and settle use its
roles instead of t3.json's. The existing safety properties are unchanged:

- Discovery only reads files and never executes commands.
- The captured plan names the exact command and is shown for explicit review.
- The managed helper re-reads the pinned settings file immediately before spawn and
  fails with "configuration changed" if the action's digest no longer matches.

Plans pinned to t3.json keep their original encoding. A plan pinned to an action
adds a `projectAction` field and omits `configurationRevision`. Older Coincide
builds cannot decode a workspace that holds such a plan.

## Previews

An action's or script's `previewUrl` must be `http` or `https` and must not contain
a user name or password. With **Open preview automatically**, Coincide waits until a
loopback preview port accepts a TCP connection, for up to 60 seconds, and then opens
the URL in the default browser. The wait stops if the terminal stops first.
Non-loopback URLs open right away. **Open Preview** opens the URL on demand. An in-app
preview panel is not implemented.

## Icons

**Automatic** checks t3.json `iconPath`, then T3's well-known favicon and app-icon
locations. Only regular files of 1 MiB or less, resolved inside the checkout, are
read. Otherwise the sidebar shows a two-character monogram derived from the project
name (`Nebula` → `NA`, `Silver Orchard` → `SO`, `M7 Forge` → `M7`).

## Storage

Project settings live in private files under
`~/Library/Application Support/Coincide/ProjectSettings/`, one per project. Each
file has owner-only permissions and is replaced atomically. Checkouts that share a
resolved repository identity share one file. Settings saved before the identity
resolved remain readable and move to the shared file on the next save. A corrupt
file, or one saved by a newer build, is left unchanged and disables editing until
it is fixed. The last-run action and the all-projects defaults are device
preferences stored in `UserDefaults`.
