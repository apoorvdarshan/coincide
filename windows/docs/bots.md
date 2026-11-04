# Native Windows bots

The Windows catalog follows the current Mac lineup v2: Brulee is the one starter, with seven selectable characters, eleven tints and ten personality presets. `BotCatalog.h` keeps the personality (tone) separate from the user's job instructions. The source artwork is the repository's existing MIT-licensed `CoincideRemoteKit/BotArtwork.swift`, exported reproducibly by `windows/scripts/export_bot_artwork.py`; the Swift original is unchanged. No artwork service, dependency or external SVG reference is used.

`BotStore(app_data_directory, home_directory)` owns only bounded `bots.json` metadata. The caller opens it, then explicitly calls `ensure_starters(defaults)` once. Removing Brulee does not restore it on the next launch. Unknown personality presets remain saved but inactive. Unsupported or unreadable files are preserved and cannot be overwritten after a failed open. Atomic writes, an exclusive writer lease, stale-snapshot checks and ordinary local-file checks protect existing metadata. Folder creation is limited to the explicit app-owned separate-folder action; removing a bot never removes its folder or files.

Home is the default working folder, as on the Mac. Home, its parent and drive roots are broad folders: `BotOpenPlan.broad_folder` tells the app to disable automatic Git checkpoints there. A missing or invalid custom folder fails instead of falling back to Home. Existing user folders are not created or changed by Save.

## App integration

Persist optional `Thread.bot_id`, normalized as a GUID, and keep these histories in the fixed Bots container `{b0b5b0b5-c01c-4d1e-b075-000000000001}`. The Workspace remains the only transcript/history store. Ordinary chats must not receive bot context. Orphaned bot histories must become ordinary chats without losing messages or drafts.

`BotStore::plan(bot_id, conversations, new_requested)` validates every history's exact bot ownership. Open selects the latest nonarchived history; New reuses an untouched, nonbusy history with no draft, otherwise it returns a creation plan. `existing_thread_id` selects an existing thread; its existing selection and history must be preserved. The plan's `selection` is the default for creation, not a request to overwrite an existing used thread. Creating or opening a thread does not start a provider turn.

Pass `instructions` through `AgentLaunch.instructions` at the native session boundary, separately from saved messages. For adapters lacking that channel, `BotRecord::instructions_block()` provides the existing bounded fallback delimiter and escapes embedded closing tags. Never insert this standing context into the user's stored transcript. Root's existing provider/profile verification and access policy still apply.

`PersonaPanel::create(store, defaults, callbacks, provider_choices)` builds a native editor. The caller keeps it alive, inserts `view()`, then calls `close()` before detaching. The provider/profile choices are injected metadata only; opening/selecting the panel never checks accounts, launches providers, generates greetings or sends messages. SVG previews load bounded in-memory streams through `SvgImageSource::SetSourceAsync`, with weak ownership and generation checks. History controls paginate at fifty rows.

All panel callbacks and folder-picker completions run on the UI thread:

- `conversations(bot_id)` returns owned history snapshots, including draft/busy/archived state.
- `open(BotOpenPlan)` rechecks current Workspace ownership and opens or creates the requested thread.
- `before_change(BotChange)` runs before the metadata write. Reject or defer busy context changes, and invalidate idle native runtimes when folder/effective instructions change. Account scope and tool grants remain governed by the app.
- `changed(BotChange)` runs after Save. Selection/access/plan defaults apply only to new or untouched idle histories; used histories keep their settings.
- `before_remove(BotRecord, disposition)` refuses or stops running bot deliveries before metadata removal. `removed(bot_id, disposition)` performs the explicit keep-as-chats or remove-history Workspace transaction. Keeping conversations clears bot context and native sessions. If the Workspace transaction fails, preserve and rehome orphan histories on recovery.
- `pick_folder(completion)` opens the app's picker only after the explicit button. Late completions cannot alter another selected bot or a closed panel.

Save, Reset Edits, dirty-switch Save/Discard/Keep Editing and removal choices are explicit native controls. An empty folder selects Home. Full Access defaults to approval unless the caller's existing explicit default or the user selects Full Access. None retains Custom text while deactivating it; returning to Custom restores the text. Preset greetings are static catalog text.

## Validation entry points

- `bot_tests(report)`: native owned-directory store/catalog/artwork contracts, with no providers or user folders.
- `persona_panel_tests(report, XamlRoot)`: initialized native UI lifecycle contracts; needs the app's existing UI fixture route and exclusive native UI test slot.

Portable artwork validation also covers all 231 character/color/detail variants. Compilation is not a substitute for executing the initialized UI fixture; account/model calls are intentionally absent from these tests.
