# Scoped secure secret requests

Read [the shared contract](README.md) and [coordination instructions](../CLOUD_TASKS.md) first.

Assigned branch: `parallel/secret-requests-20261024`.

Implement scoped private secret requests with a real native secure-entry UI and corresponding app MCP requests/responses. Own new SecretRequest* Core/service/store/view files and focused wiring. Return opaque scope-bound references; raw secret values must not enter normal chat, WorkspaceJournal, command payload logs, exports, or URLs. Bind to exact caller session/thread/environment, use the appropriate private secret store, support explicit cancellation/expiry and safe restart handling. Read the pinned T3 secret-request contracts rather than conflating ordinary questions with secrets. Add injected secret-store tests for authorization, expiry, cancelled/replaced owners, failures, and redaction. Clearly document actual retention and how the authorized host consumes the reference safely; do not fabricate a successful response without secure delivery.

Secret clarification: the model receives ONLY a one-use secretRef, never the secret value. Implement the real host-only consume bridge for schedule_task.signature.secretRef, matching the pinned request_secret/scheduler contract. Verify duplicate/expired/foreign-scope consumption refusal and successful host-only consumption without plaintext entering logs, chat, receipts or durable command payloads.
