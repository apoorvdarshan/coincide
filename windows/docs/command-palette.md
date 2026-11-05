# Windows command palette

Choose **Command palette** in the sidebar, or press **Ctrl+Shift+P** when that combination is not assigned to another
configured shortcut. Search commands, project names/folders, conversation titles and providers. Arrow keys choose a
result, Enter or **Open selected result** activates it, and Escape closes the palette and returns to the composer.

Selecting a project filters the sidebar by its exact project ID and opens its first available conversation. The project
button clears that filter. Selecting a conversation clears other filters, opens that exact saved conversation, and
preserves each conversation's draft. Deleted conversations are excluded. Matching metadata does not read messages,
drafts, attachments or credentials, and never starts an agent or sends input. The available commands create a new
conversation, open saved-message search, browse bots, or clear the project filter; destructive and sending actions
are not palette commands.

Search folds Unicode case, matches separate words across metadata, ranks title matches first, and preserves stable
IDs for duplicate titles. It runs on a worker after a short typing debounce. Query changes, closing the pane and stale
destinations revoke earlier actions. Matching is bounded to 20,000 entries and 8 MiB of metadata, with at most 100
results and an explicit refinement message. Destination identity and current availability are rechecked on activation.

Portable metadata checks pass locally. Native component and full-app navigation coverage are included, with exact-head
Windows CI and physical acceptance still required; this document does not claim those checks have already passed.
