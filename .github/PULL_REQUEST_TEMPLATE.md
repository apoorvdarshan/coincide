## Summary

<!-- What does this change, and why? One to three short bullets. -->

-

## Area

<!-- Check all that apply. -->

- [ ] App UI (`Coincide/`)
- [ ] CoincideKit: providers, runtime or handoff
- [ ] CoincideKit: git, worktrees or checkpoints
- [ ] CoincideKit: models or storage
- [ ] Tests or fuzzing (`CoincideKitTests/`, `Fuzz/`)
- [ ] Docs, CI or project settings (`project.yml`)

## Agents affected

- [ ] None, or all equally
- [ ] Claude Code
- [ ] Codex
- [ ] Cursor
- [ ] Grok Build
- [ ] OpenCode
- [ ] Pi
- [ ] Antigravity

## Test plan

<!-- How did you verify this? See CONTRIBUTING.md. -->

- [ ] Unit tests pass (`xcodebuild -project Coincide.xcodeproj -scheme Coincide -destination 'platform=macOS' test`)
- [ ] Added or updated tests for the new behavior or the fixed bug
- [ ] Ran the live tests for the agents whose provider code changed (`TEST_RUNNER_COINCIDE_LIVE_TESTS=1`)
- [ ] Ran `Fuzz/fuzz.sh replay` if a fuzzed parser changed
- [ ] Ran `scripts/sync-strings.sh` for new or changed user-facing text
- [ ] Tried it in the app; screenshots below for UI changes

## AI assistance

<!-- Which AI tools helped write this, and for what? Write "None" if none did. -->

## Notes

<!-- Screenshots, limitations, follow-ups. Leave out secrets and private code. -->

Closes #
