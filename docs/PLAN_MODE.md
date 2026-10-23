# Codex plans and implementation

Supported Codex profiles expose **Plan** and **Default** interaction modes in the provider controls. A mode selection captures the original conversation and model configuration. It does not change sandbox permissions or reinterpret an already active turn. Unknown profiles do not advertise unsupported controls.

Native proposed-plan items render separately from TODO lists. Streaming plans retain the originating native item, turn and Coincide run. Only an eligible completed plan can be implemented; an incomplete or uncertain item cannot authorize an implementation action.

**Implement** uses the exact displayed plan and captured source. **Implement in New Conversation** creates one fresh provider context in the same workspace and preserves the source conversation's draft and attachments. The new context starts in explicit Default mode with the captured model and permission settings. Its source link is display provenance and does not import provider history.

Creation and the first input use the original durable command ID. Retrying or checking an accepted command returns that receipt without submitting another implementation turn. A changed source, configuration, destination or workspace refuses the action. Scratch destinations require an actual allocator grant.

The remote implementation action uses a host-issued source lease and the same original command/receipt rules. Manual remote Plan/Default editing is still pending. Offline protocol, reducer, SQLite and native-store fixtures do not establish compatibility with an installed provider or a live SSH host.
