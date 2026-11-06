# Named Codex continuation after restart

Ordinary Rust-owned named Codex turns can continue their native session after
restart. Imported history and caller-supplied session IDs grant no authority.
Other providers keep their existing resume policy.

The Engine mints a receipt only after the final successful transcript save and
the exact owned worker's actual joined return. Cancellation, a failed save,
panic, semantic completion without join, and unclassified completion cannot
mint one. A crash before minting conservatively starts a new native session.

Each Store has a separate private sibling `.DATABASE.native-resume-v1`
directory. A versioned SQLite journal holds bounded HMAC-SHA256 authenticated
receipts. A private key file also holds independent one-attempt tickets and an
exclusive process/Engine lease. Ticket consumption is synced before the journal
DELETE commits and before launching a provider. Replaying a copied journal row
cannot restore a consumed ticket. Failure to consume blocks that launch.

Receipts bind the canonical Store path/inode, exact profile/home/auth-file and
executable identity, thread, project directory identity, selected options,
presence-aware modes, effective effort/speed, full saved transcript-prefix
digest, native session ID and provider-resolved model. Across restart the normal
fresh catalog/model admission is still required for explicit model selections;
no serialized proof recreates an Arc or catalog authorization. Fresh account
verification and a matching native resume ID/resolved-model ACK precede the
next turn. Only newly appended transcript items are dispatched on continuation.

Changed context, invalid authentication tags, missing/unsafe key state, a copied
Store, and corruption fail closed to a new session where normal admission is
otherwise valid. Original Store tables, imported bytes, search data and unknown
JSON fields are not migrated or rewritten for this journal. The optional
journal is currently enabled only on Unix with verified private ownership,
permissions, no symlinks/hardlinks and an exclusive flock. Unverified non-Unix
ACL behavior does not grant durable authority. A local user who can read and
replace both the private key state and database is outside this boundary.

Validation targets are `named_profile_resume`, its private journal unit tests,
and `provider_codex_profile_resume`. The latter launches distinct fresh OS
processes and requires actual `thread/resume` with unchanged native identity
and only the new prompt. Compilation, automated execution and native candidate
Quit/reopen acceptance remain pending at the initial draft checkpoint.
