# Coincide product direction

The interface reference is the **ChatGPT macOS app**. T3 Code is the reference
for integrations, workflows, and end-to-end behavior, not the visual design.
The user confirmed this direction on 2026-10-21.

- Build the application and its core in native Swift, with SwiftUI and narrow
  AppKit integrations. Use native text, menus, windows, file panels, accessibility,
  keyboard input, and settings.
- Use a restrained sidebar, a centered readable conversation column, generous
  space, a compact provider/model header, and a rounded composer near the bottom.
- Show user messages in trailing neutral bubbles and assistant responses directly
  in the conversation. Keep tools, reasoning, approvals, and code review readable
  without making the default conversation look like an IDE dashboard.
- Keep files, changes, terminal, and other workspace tools available on demand.
  The inspector starts closed so the conversation remains the main surface.
- Support system light/dark appearance, resizing, keyboard navigation, text
  selection, and accessible labels. Use Coincide branding.
- Preserve the full T3 Code functionality goal. Visual simplification must not
  remove provider integrations, permission flows, Git/worktrees, checkpoints,
  remote support, or the other capabilities in the upstream inventory.

Visual reference: OpenAI's public ChatGPT desktop screenshots, including the
[macOS composer](https://help.openai.com/en/articles/9295245-chatgpt-macos-app-screenshot-tool).
