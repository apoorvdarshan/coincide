# Native and remote media previews

Read [the shared contract](README.md) and [coordination instructions](../CLOUD_TASKS.md) first.

Assigned branch: `parallel/media-previews-20261024`.

Implement bounded native image/PDF/CSV previews and explicit audio/video playback within existing Files and attachment UI. Own WorkspaceMedia*, RemoteMedia*, MediaPreview* files and focused UI/protocol wiring. Resolve local data through existing captured workspace/attachment descriptors and remote data through bounded verified chunks; never resolve remote paths locally. Preserve editor drafts and exact source revisions. No autoplay, ambient arbitrary URL fetching, executable HTML, or unexpected external apps. Show unknown/unsupported/too-large states truthfully; keep accessibility/native keyboard behavior. Add fixture tests for path replacement, invalid media, CSV quoting/size caps, stale remote content and cancellation/drain. Keep interactive HTML and browser automation out of this task; those have separate owners. Native rendering/playback must be marked unverified if cloud is Linux.

Bound decoded image pixels, PDF pages/render dimensions, CSV rows/fields/individual-field size, and retained decoded cache bytes in addition to compressed input bytes. Malformed or oversized data must fail without blocking the main actor.
