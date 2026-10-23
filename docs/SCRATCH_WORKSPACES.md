# Conversations without a project

The sidebar can create a conversation under **No project**. Each new conversation receives a private dated folder with a unique allocation identity. Authored text can supply its initial name. Coincide does not initialize Git or run setup scripts there. Existing folders are not silently renamed when the draft changes.

The folder is the conversation's actual workspace, including its captured provider configuration. A default Worktree preference does not apply to scratch conversations. Settling, archiving or closing the app retains their files.

The allocator records the original command, thread and physical directory identities in private app storage. Ordinary project/thread creation cannot forge those claims. Replacing a folder at the same path invalidates its ownership; Coincide keeps foreign files and refuses provider input there.

**Saved Scratch Allocations** inspects interrupted creation using the original command receipt. Check Result does not resend input. Discard Empty Allocation removes only a verified, empty, unaccepted allocation after sealing the original command as rejected. Accepted folders and folders containing user files are retained.

Implementing a plan in a new scratch conversation or accepting a reviewed context fork can deliberately reuse the source folder. These paths obtain a new, destination-bound grant from the allocator. Display provenance, copied snapshot fields and provider history receipts do not grant folder ownership.

Scoped MCP `t3_thread_launch` accepts explicit `scratch: true`. Omitting the project retains ordinary caller-project inheritance; a scratch caller receives another independently allocated folder. The launch retains the caller's captured provider permissions and does not consume its composer.

Native and remote provider-history forks carry their actual allocation grant through the original asynchronous operation. A verified native reply creates the child only after a fresh physical ownership check. A reply blocked by changed ownership remains unconfirmed with its acknowledgment retained, and no child or repeated fork is created. Saved Scratch Allocations distinguishes an accepted history operation whose child is still pending.

Remote creation without a project still needs its own adapter. Existing scratch conversations can be projected remotely after host ownership validation. Native UI tests use private folders and offline provider peers; installed-provider and interactive-window acceptance remain separate checks.
