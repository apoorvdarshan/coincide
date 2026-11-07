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
item/turn updates, text send/queue/steer, approval/question responses, new
threads, rename/pin/archive/snooze, stop, and device presence. Requests use the
existing Engine gates. Presence is received but does not route lock-screen
notifications.

Remaining behavior gaps are explicit: remote image upload, usage-limit sharing,
mark-seen/unread and settle/move/delete actions, steer-queued, dismiss-question,
and show-thread. Unsupported commands return errors; usage currently returns
an empty list. Bonjour advertisement is implemented for macOS and Linux; Windows
uses pairing-code addresses. CloudKit phone alerts are not implemented.

Validation uses disposable data directories, an in-memory secret store, fixture
Engine, and pinned-certificate loopback TLS clients. Tests cover pairing,
authentication, workspace/transcripts, certificate reset, wrong pins, deadlines,
and socket shutdown. These tests do not establish real iPhone pairing, OS secret
store access, actual LAN/Bonjour/Tailscale reachability, or native settings UI
acceptance. No personal account, microphone, or permission interaction is needed.
