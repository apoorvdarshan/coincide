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
text remains unsent; no coding agent or network provider is invoked.
The shell resolves the selected Xcode's real Git executable before entering the
sandbox; commit verification avoids `/usr/bin/git`'s developer-tool shim and
retains both output streams in the test result for diagnosis.

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
Screenshots and accessibility trees are retained in the `.xcresult` and exported
by `xcresulttool` into the uploaded attachments directory after testing. The
runner never writes directly to the shell-owned artifact directory. The result
gate requires all three tests to pass with zero
skips. Startup or Accessibility failures remain failed verification, and are not
reported as completed visual QA.

The existing SwiftPM suite remains independent and runs in full. A separate
change-classification job limits the native UI job to product, package,
packaging, and UI-harness changes. Configuration tests run without a GUI:

```sh
python3 -m unittest discover -s UITests/macOS -p 'test_*.py' -v
```
