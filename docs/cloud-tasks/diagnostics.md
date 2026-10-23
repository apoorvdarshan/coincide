# Native runtime diagnostics and redacted export

Read [the shared contract](README.md) and [coordination instructions](../CLOUD_TASKS.md) first.

Assigned branch: `parallel/diagnostics-20261024`.

Implement a reachable native Diagnostics surface and explicit export with bounded actual observations (app/version/environment/provider process states and relevant resource measurements). Own DiagnosticsSnapshot/Collector/Export* plus native settings/store/view files. Show source and observation time; unavailable measurements remain unavailable, not zero or fabricated. Do not collect transcript, prompts, file contents, auth credentials, cookies or secret settings by default. Export only on explicit action with a native save flow; no telemetry upload. Redact paths/identifiers as appropriate while preserving diagnostic utility, with a deterministic redaction test corpus. Use injected observation sources for resource/cancellation/drain/failure tests and verify export bounds and formatting. Do not modify update distribution, live provider auth, usage billing aggregation or browser features.

Observe only app-owned registered processes and app-authorized sources. No global process argv/environment dumps, broad home-directory/filesystem scan, or ambient provider-auth collection.
