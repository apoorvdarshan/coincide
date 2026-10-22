The desktop UI tests use Xcode's actual macOS UI automation runner. The app is
built only by SwiftPM; this project's tiny placeholder app supplies the target
metadata Xcode needs to build its UI test runner. It is never the app exercised
by the tests.

`script/test_macos_ui.sh --build-for-testing` compiles the runner without
launching any GUI. It reuses
`~/Library/Developer/Xcode/DerivedData/coincide-desktop-ui-tests`.

GitHub Actions runs `script/test_macos_ui.sh --ci <verified-app-bundle>` after
all SwiftPM tests, packaging, signature checks, and resource checks pass. The
script stages a separate app copy in task-owned temporary storage, gives it the
dedicated `com.apoorvdarshan.coincide.uitesting` bundle identifier, signs it ad
hoc, and points the generated `.xctestrun` at that copy. Neither `dist/` nor an
installed app is replaced. GUI execution refuses to run outside GitHub Actions.

Every UI test creates a private `coincide-ui-testing-*` workspace in Foundation's
runner-owned temporary directory. Xcode sandboxes its generated UI runner;
shell-created scratch directories are not writable from that runner. The app's
DEBUG launch configuration requires that prefix, the dedicated bundle ID, and
explicit environment opt-in; invalid configuration must never fall back to
normal app data. Git identity and hooks are configured through a private
test-only Git config, without changing the runner's global settings. Composer
text remains unsent in the first eight workflows. The ninth sends three synthetic
prompts only to a bundled offline Codex protocol peer; no real coding agent or
network provider is invoked.
The shell resolves the selected Xcode's real Git executable before entering the
sandbox; commit verification avoids `/usr/bin/git`'s developer-tool shim and
retains both output streams in the test result for diagnosis.
Native panel and alert buttons are scoped to their visible containers so Touch
Bar duplicates cannot satisfy a query. For the pinned XCTest runtime's observed
512-unit alert-text truncation, on-device Vision checks both warning phrases in
the actual alert screenshot; the image and recognized text remain in the result.
Full checkout paths use exact menu-title predicates because XCTest's convenience
identifier queries reject strings longer than 128 characters.
Folder imports wait for the native location popup to name the requested folder,
then assert the Add Project button is enabled and hittable. This keeps navigation
readiness separate from expensive hit-testing of the panel's column hierarchy.
Script launch uses the visible toolbar button or the native overflow's Run Script…
menu item when the display cannot fit every toolbar control.
For script output, retained native CI video showed that XCTest's default
disclosure click hits the label without expanding it. The harness clicks the
visible triangle relative to that control's AX frame and requires expanded
state before checking the exact command output.
After an observed OutlineRow hit-testing failure, conversation selection targets
the row's identified native title, requires it to be hittable, and verifies
the containing row becomes selected.

The first two tests exercise light/dark actual windows, File-menu or keyboard project
creation, an initial Git commit, project renaming, collapse with the selected
conversation retained, and composer persistence across graceful quit/relaunch.
They then cancel a project-removal confirmation, verify the selected draft is
retained, confirm removal, and check the existing README, icon, HEAD bytes and
resolved Git commit remain unchanged while the workspace becomes empty.
The third test creates two private local Git repositories with the same
synthetic remote URL, without fetching or contacting that host. It imports both
through the native folder panel, creates conversations in each checkout, and
checks repository grouping, explicit future-checkout selection, distinct drafts,
separate-checkout mode, and persistence after relaunch. The existing checkout
commits must remain unchanged. It then renames both checkouts as a group,
reviews the exact paths in the native removal sheet, checks Cancel preserves
all three drafts, and confirms group removal clears the workspace while both
checkouts' README, HEAD bytes, and resolved commits remain unchanged.
The fourth test imports a private local repository, edits and saves through the
native file editor, and verifies unsaved buffers survive hiding the inspector.
It opens a content-search match and retains the rendered selection for visual
review, adds a relative file reference to an existing unsent draft, and checks
normal Quit cancellation preserves unsaved edits. Explicit Quit and Discard
must retain the last saved bytes; relaunch must restore the composer draft and
open those saved bytes while the Git commit remains unchanged. Selected text is
not exposed by public XCTest attributes; the match/file assertions and retained
pixels do not claim an automated selected-range check.
The fifth test discovers scripts in a private t3.json without running declared
setup/settle roles, checks Cancel preserves the draft, and rejects Run after the
configuration changes. Reload must display the replacement command before an
explicit launch. A controlled /bin/sh command writes private cwd and T3CODE
environment receipts, appears in its own terminal tab, and reports exit7.
The test then launches a private holding command, checks closing it requires
confirmation, verifies Cancel retains both tabs and the unsent draft, and
confirms closure removes only that running tab. Original Git HEAD is preserved;
process-group shutdown remains covered by the terminal unit tests.
The sixth test prepares a new branch from an explicit older local base, with
submodules set to None and no provider or network calls. The native sheet and
all three submodule options must fit the display. It checks the new checkout's
branch, commit and file contents, unchanged selected conversation and unsent
draft, and restoration of the same checkout after relaunch without duplication.
The cwd records intent before Git finishes; native Terminal and Reveal Workspace
must become enabled before any completed-checkout file or Git assertions.
The source checkout's newer commit, dirty tracked file, untracked sentinel and
HEAD bytes must remain intact.
The seventh test creates a private checkout with a blocking setup role. It checks
setup review is enabled by default, the exact command and new worktree cwd are
shown, and Cancel starts nothing. An explicit Run must report exit7 and retained
output while preserving the selected conversation and unsent draft. Continue
Without Setup must clear the blocking banner without changing the source
checkout's README, configuration, or Git HEAD. A second declared setup role must
never run. The test sends no message; provider queue ordering and release remain
engine/store test evidence. Files and Terminal intentionally remain available
while setup blocks provider messages.
The eighth test prepares a private worktree with a settle script, checks the
native Settle confirmation defaults to reviewing the script, and cancels both
the confirmation and command review without executing anything. After explicit
approval, the command must report exit0 and output while the conversation stays
settled. Only an explicit Resume clears that state; the selected conversation,
unsent draft, worktree path and original checkout bytes remain unchanged. A
second settle role must never run. Automatic resume on a submitted message and
provider queue ownership remain engine/store test evidence.
The ninth test creates three completed conversation turns through an isolated
offline Codex 0.163 protocol peer. It reviews and cancels Fork and Rewind without
mutating provider history, then confirms each exact second-run boundary. The
fork must open a new conversation with the reviewed prefix and leave the source
draft unchanged. Rewind must keep all audit rows while removing the suffix from
the current transcript. The explicit Revert and Keep Changes choice automatically
returns the original input to the latest draft only after confirmed completion;
the exact append must occur once and its Recall action must stay consumed after
graceful relaunch. Relaunch must retain both conversations and the removed-run
audit. Source README, HEAD bytes and Git commit stay unchanged.
The peer runs only from a private PATH entry with a private CODEX_HOME. Its
bounded state and wire log live under the test-owned workspace; flock plus
atomic state replacement preserve boundaries across fresh metadata/fork
processes. The CI shell resolves Python before entering the sandbox so the test
does not invoke Apple's developer-tool shim. Seven GUI-free configuration and
peer tests validate isolation, persistence and the strict result gate.

The tenth workflow uses an actual local Git repository and a natively prepared,
isolated managed worktree. An explicit fixture-only peer option edits its own
regular README during one synthetic provider turn; production code captures the
real baseline and post-run receipts. The workflow adds distinct staged, working,
new untracked and ignored files. Native restoration Cancel must preserve those
bytes, staged/working diffs, selection and draft. Explicit Restore Files must
recover baseline contents, remove new nonignored files, preserve ignored files,
clear staging and retain branch/HEAD, source checkout, conversation and latest
draft. Relaunch must preserve the applied restoration audit without replaying a
turn, fork, rewind or file restore. The peer's edit option is limited to a real
checkout directly beneath this fixture's Worktrees directory and rejects
unmanaged or symlink destinations; the original nine workflows do not enable it.
This is a Files-only operation and does not claim combined conversation rewind
plus file restoration. Execution and screenshots remain pending until the
exact-head hosted job runs; compilation and fixture tests alone are not GUI proof.

Screenshots and accessibility trees are retained in the `.xcresult` and exported
by `xcresulttool` into the uploaded attachments directory after testing. The
runner never writes directly to the shell-owned artifact directory. The result
gate requires all ten tests to pass with zero
skips. Startup or Accessibility failures remain failed verification, and are not
reported as completed visual QA.

The existing SwiftPM suite remains independent and runs in full. A separate
change-classification job limits the native UI job to product, package,
packaging, and UI-harness changes. Configuration tests run without a GUI:

```sh
python3 -m unittest discover -s UITests/macOS -p 'test_*.py' -v
```
