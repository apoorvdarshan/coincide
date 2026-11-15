# Coincide Remote port

The native Rust desktop now implements the existing iPhone/iPad Remote v1
TLS 1.3 WebSocket protocol. Remote starts disabled. The General settings panel
provides enable/disable, addresses, certificate fingerprint, expiring one-use
pairing QR/code, paired devices, revoke, and certificate reset.

TLS identities and token hashes use the platform secret store, scoped to the
app data directory. No secret-store access occurs while disabled. Pairing
requires a saved credential before returning success. Malformed existing
identities/device credentials fail closed and retain their original bytes until
an explicit certificate reset. The listener admits
local/private/link-local/Tailscale peers, limits concurrent connections, rate
limits failed authentication, and bounds complete authentication including TLS
and WebSocket handshakes. Disable/quit interrupts owned sockets before joining
workers. Address discovery uses bounded child process capture.

Implemented protocol paths include workspace, transcripts/pagination, live
item/turn updates, image and text send/queue, Codex image steering, private
image thumbnails/full previews for managed Rust attachments, approval/question responses, new
threads, rename/pin/archive/snooze, unread and settle/unsettle, stop, device
presence, and marking a thread seen. Marking a thread seen clears its Mac alerts and informs connected phones;
an active phone's visible thread also counts as seen. Requests use the existing
Engine gates. Disconnected phones do not receive lock-screen clears.

Closing the main window leaves Remote and desktop notifications owned by the
running application. Phone seen events continue to clear desktop alerts, and
the Dock or app menu can reopen the window. A normal app quit still disconnects
phones and stops the Engine; this is not an independent agent-host process and
does not preserve running turns across app quit, update, or crash.

Remote's older usage view receives actual cached account windows for enabled
providers, including their reset times. The richer usage dashboard is not yet
implemented; the phone falls back to its older limits view. Image submissions
accept up to 10 images, up to 20 MiB each and 24 MiB total before normalization;
previews currently cover managed Rust attachments, not every Swift-era or
assistant media type. Images that cannot be steered are queued.

Remaining behavior gaps include move/delete actions,
steer-queued, dismiss-question, show-thread, and the richer usage dashboard.
Unsupported commands return errors. Bonjour advertisement is implemented for macOS and Linux; Windows
uses pairing-code addresses. CloudKit phone alerts are not implemented.

Validation uses disposable data directories, an in-memory secret store, fixture
Engine, and pinned-certificate loopback TLS clients. Tests cover pairing,
authentication, workspace/transcripts, image previews, account-limit filtering,
certificate reset, wrong pins, deadlines, and socket shutdown. These tests do not establish real iPhone pairing, OS secret
store access, actual LAN/Bonjour/Tailscale reachability, or native settings UI
acceptance. No personal account, microphone, or permission interaction is needed.
