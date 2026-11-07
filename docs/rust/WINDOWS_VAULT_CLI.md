# Windows vault CLI ownership

The Windows `CliCommand` transport accepts absolute native `.exe` files, passes
arguments directly, inherits the authorized app's existing session, and suppresses
stderr. It does not invoke shell shims, log into a manager, unlock a vault or read
a personal vault during tests. Browser Settings discovers `bw.exe` and `op.exe`
from absolute PATH entries by filesystem inspection only; `.cmd`/`.bat` shims and
relative/current-directory entries are excluded.

A child starts suspended, joins a non-breakaway kill-on-close Job, and only then
resumes. One stdout reader drains only bytes already reported available while a
separate writer delivers bounded input. The writer owns a zeroizing input copy.
Deadline/failure cleanup requests cancellation of its synchronous pipe I/O,
terminates the Job, waits for retained root/descendant process handles to signal,
and actually joins the writer. Cancellation requests, Job counts and leader exit
alone do not release ownership. An unconfirmed kernel cleanup keeps the existing
vault worker occupied; no new vault operation gains admission meanwhile.

Input and captured output are bounded to 8 MiB; temporary capture buffers are
zeroized. The trusted caller receives the same private byte result contract as
Unix. This is not a claim that every parsed value or OS buffer is erased.

Windows-only inert PowerShell helpers cover success/nonzero/overflow, a child
writing before draining large stdin, blocked stdin cancellation, and a successful
leader whose descendant retains inherited pipes. Tests retain actual process
handles and verify signals after cleanup. Disposable runner results are required
before calling this Windows implementation validated. No actual manager/vault,
WebAuthn ceremony, native approval UI, or personal desktop is used by these tests.

The existing private-fill native approval and page/permit checks remain required.
This transport does not add a Windows Bitwarden passkey browser bridge. WebView2's
API probe still does not establish a Windows Hello/sign-in ceremony. Linux
passkeys and unsupported user-verification/registration routes remain unavailable.
